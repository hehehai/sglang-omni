/// Connection-owned offline Silero admission, request reuse, and drain-before-release lifecycle.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniSileroInferenceEngine: @unchecked Sendable {
    nonisolated final class ConnectionLifetime: @unchecked Sendable {
        enum OperationState { case active, cancelled, completed }

        let id = UUID()
        // note (assistant): Only the Silero engine lock protects this lifetime, never the Qwen lock.
        var isActive = true
        var operations: [UUID: OperationState] = [:]
        private var operationOrder: [UUID] = []

        func recordOperation(_ operationID: UUID) throws {
            guard operations[operationID] == nil else {
                throw OmniXPCFailure.error(.invalidRequest, "The operation ID has already been used.")
            }
            operationOrder.append(operationID)
            operations[operationID] = .active
            guard operationOrder.count > OmniXPCProtocolLimits.maximumRequestsPerModel else { return }
            let oldest = operationOrder.removeFirst()
            precondition(operations[oldest] != .active)
            operations.removeValue(forKey: oldest)
        }
    }

    private enum ModelState { case unloaded, loading, ready, unloading }
    private struct Request {
        let id: UUID
        var isCancelled = false
    }

    private let configuration: OmniXPCConfiguration
    private let queue = DispatchQueue(label: "Voxt.Omni.XPC.silero")
    private let lock = NSLock()
    private var modelState: ModelState = .unloaded
    private var owner: ConnectionLifetime?
    private var modelID: UUID?
    private var loadOperationID: UUID?
    private var model: SileroCoreModel?
    private var activeRequest: Request?
    private var requestIDs: Set<UUID> = []

    init(configuration: OmniXPCConfiguration) { self.configuration = configuration }

    func load(
        operationID: String, modelDirectory: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) {
        do {
            try admitLoad(operationID: operationID, modelDirectory: modelDirectory, lifetime: lifetime, reply: reply)
        } catch {
            reply(nil, nil, error as NSError)
        }
    }

    func admitLoad(
        operationID: String, modelDirectory: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) throws {
        let operation = try identifier(operationID)
        guard !modelDirectory.isEmpty,
              modelDirectory.utf8.count <= OmniXPCProtocolLimits.maximumModelPathByteCount,
              !modelDirectory.contains("\0") else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero model path exceeds validation limits.")
        }
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded else {
                throw OmniXPCFailure.error(.busy, "Unload the current Silero model before loading another model.")
            }
            try lifetime.recordOperation(operation)
            owner = lifetime
            loadOperationID = operation
            modelState = .loading
            // note (assistant): Enqueue while locked so disconnect cleanup cannot overtake admitted work.
            queue.async { [self] in
                do {
                    let directory = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: modelDirectory,
                        container: OmniServiceIdentity.groupContainer(configuration: configuration)
                    )
                    guard lock.withLock({ lifetime.isActive && lifetime.operations[operation] != .cancelled }) else {
                        throw OmniXPCFailure.error(.cancelled, "The Silero load was cancelled.")
                    }
                    let loaded = try SileroCoreModel(directory: directory)
                    let newModelID = UUID()
                    let published = lock.withLock {
                        guard lifetime.isActive, lifetime.operations[operation] != .cancelled else { return false }
                        model = loaded
                        modelID = newModelID
                        modelState = .ready
                        lifetime.operations[operation] = .completed
                        return true
                    }
                    if published {
                        reply(newModelID.uuidString, OmniServiceIdentity.instanceID.uuidString, nil)
                    } else {
                        loaded.close()
                        throw OmniXPCFailure.error(.cancelled, "The Silero load was cancelled.")
                    }
                } catch {
                    let cancelled = lock.withLock {
                        let cancelled = !lifetime.isActive || lifetime.operations[operation] == .cancelled
                        lifetime.operations[operation] = cancelled ? .cancelled : .completed
                        // note (assistant): Disconnect owns the queued cleanup barrier and releases admission last.
                        if lifetime.isActive { clearModel() }
                        return cancelled
                    }
                    reply(nil, nil, cancelled
                          ? OmniXPCFailure.error(.cancelled, "The Silero load was cancelled.") : error as NSError)
                }
            }
        }
    }

    func unload(
        operationID: String, modelID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let operation = try identifier(operationID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard activeRequest == nil else {
                    throw OmniXPCFailure.error(.busy, "Wait for the Silero request to finish before unloading.")
                }
                guard !requestIDs.contains(operation) else {
                    throw OmniXPCFailure.error(.invalidRequest, "The operation ID has already been used for a request.")
                }
                try lifetime.recordOperation(operation)
                let loaded = model!
                modelState = .unloading
                queue.async { [self] in
                    loaded.close()
                    let cancelled = lock.withLock {
                        let cancelled = !lifetime.isActive || lifetime.operations[operation] == .cancelled
                        lifetime.operations[operation] = cancelled ? .cancelled : .completed
                        clearModel()
                        return cancelled
                    }
                    reply(cancelled ? OmniXPCFailure.error(.cancelled, "The Silero unload was cancelled.") : nil)
                }
            }
        } catch {
            reply(error as NSError)
        }
    }

    func speechTimestamps(
        requestID: String, modelID: String, audio: Data, settings: Data, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(requestID)
            let requestedModelID = try identifier(modelID)
            let options = try OmniXPCSileroSettings.decode(settings)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard !requestIDs.contains(requestedID), lifetime.operations[requestedID] == nil else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero request ID has already been used.")
                }
                guard requestIDs.count < OmniXPCProtocolLimits.maximumRequestsPerModel else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero request ledger is full; unload the model.")
                }
                guard activeRequest == nil else {
                    throw OmniXPCFailure.error(.busy, "The Silero model already has an active request.")
                }
                let samples = try OmniXPCRequestValidation.audioSamples(
                    audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount
                )
                let loaded = model!
                try loaded.prepareRequest(requestID: requestedID)
                // note (assistant): Only successful admission consumes history, including cancellation before execution.
                requestIDs.insert(requestedID)
                activeRequest = Request(id: requestedID)
                queue.async { [self] in
                    var response: Data?
                    var failure: NSError?
                    do {
                        let timestamps = try loaded.speechTimestamps(
                            requestID: requestedID, samples: samples, settings: options
                        )
                        response = try OmniXPCSileroTimestampBatch(
                            serviceInstanceID: OmniServiceIdentity.instanceID, modelID: requestedModelID,
                            requestID: requestedID, sampleCount: samples.count, timestamps: timestamps
                        ).encoded()
                    } catch {
                        failure = error as NSError
                    }
                    let cancelled = lock.withLock {
                        precondition(activeRequest?.id == requestedID)
                        let cancelled = !lifetime.isActive || activeRequest!.isCancelled
                        activeRequest = nil
                        return cancelled
                    }
                    if cancelled {
                        reply(nil, OmniXPCFailure.error(.cancelled, "The Silero request was cancelled."))
                    } else {
                        reply(response, failure)
                    }
                }
            }
        } catch {
            reply(nil, error as NSError)
        }
    }

    func cancel(requestID: String, modelID: String?, lifetime: ConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        let requestedModelID = try modelID.map(identifier)
        var cancellingModel: SileroCoreModel?
        var cancellingRequestID: UUID?
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            if let requestedModelID {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard requestIDs.contains(requestedID) else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero request ID has not been registered.")
                }
                if activeRequest?.id == requestedID {
                    activeRequest!.isCancelled = true
                    cancellingModel = model
                    cancellingRequestID = requestedID
                }
            } else if owner?.id == lifetime.id, loadOperationID == requestedID {
                lifetime.operations[requestedID] = .cancelled
                if modelState == .ready {
                    modelState = .unloading
                    activeRequest?.isCancelled = true
                    cancellingModel = model
                    cancellingRequestID = activeRequest?.id
                    enqueueCleanup(lifetime: lifetime, loadOperationID: requestedID)
                }
            } else if let operation = lifetime.operations[requestedID] {
                if operation == .active { lifetime.operations[requestedID] = .cancelled }
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The Silero operation is stale or belongs to another connection.")
            }
        }
        if let cancellingRequestID { cancellingModel?.cancelRequest(requestID: cancellingRequestID) }
    }

    func disconnect(lifetime: ConnectionLifetime) {
        var cancellingModel: SileroCoreModel?
        var cancellingRequestID: UUID?
        lock.withLock {
            guard lifetime.isActive else { return }
            lifetime.isActive = false
            guard owner?.id == lifetime.id else { return }
            modelState = .unloading
            activeRequest?.isCancelled = true
            cancellingModel = model
            cancellingRequestID = activeRequest?.id
            enqueueCleanup(lifetime: lifetime, loadOperationID: loadOperationID!)
        }
        // note (assistant): Token cancellation must bypass the queue that may be blocked waiting for Native GPU work.
        if let cancellingRequestID { cancellingModel?.cancelRequest(requestID: cancellingRequestID) }
    }

    func requireValidationIdle(lifetime: ConnectionLifetime) throws {
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded, owner == nil, activeRequest == nil else {
                throw OmniXPCFailure.error(.busy, "Unload the Silero model before using the diagnostic endpoint.")
            }
        }
    }

    private func enqueueCleanup(lifetime: ConnectionLifetime, loadOperationID: UUID) {
        queue.async { [self] in
            let loaded = lock.withLock { () -> SileroCoreModel? in
                guard owner?.id == lifetime.id, self.loadOperationID == loadOperationID else { return nil }
                precondition(activeRequest == nil)
                return model
            }
            loaded?.close()
            lock.withLock {
                guard owner?.id == lifetime.id, self.loadOperationID == loadOperationID else { return }
                clearModel()
            }
        }
    }

    private func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value) else {
            throw OmniXPCFailure.error(.invalidRequest, "Model, request and operation IDs must be UUIDs.")
        }
        return identifier
    }

    private func requireOwner(_ lifetime: ConnectionLifetime, modelID requestedModelID: UUID) throws {
        guard lifetime.isActive, owner?.id == lifetime.id, modelID == requestedModelID else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero model ID is stale or belongs to another connection.")
        }
        guard modelState == .ready else {
            throw OmniXPCFailure.error(.busy, "The Native Silero model is not ready.")
        }
    }

    private func clearModel() {
        model = nil
        modelID = nil
        owner = nil
        loadOperationID = nil
        activeRequest = nil
        requestIDs.removeAll(keepingCapacity: false)
        modelState = .unloaded
    }
}
#endif
