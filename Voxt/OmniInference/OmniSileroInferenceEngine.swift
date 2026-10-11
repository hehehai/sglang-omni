/// Connection-owned Silero model admission and cancellation with drain-before-release cleanup.
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

    enum ModelState { case unloaded, loading, ready, unloading }
    enum RequestKind { case offline, stream }
    struct Request {
        let id: UUID
        var isCancelled = false
    }

    private let configuration: OmniXPCConfiguration
    let queue = DispatchQueue(label: "Voxt.Omni.XPC.silero")
    let lock = NSLock()
    var modelState: ModelState = .unloaded
    var owner: ConnectionLifetime?
    var modelID: UUID?
    var loadOperationID: UUID?
    var model: SileroCoreModel?
    var activeRequest: Request?
    var requestIDs: [UUID: RequestKind] = [:]
    var streams: [UUID: OmniSileroStream] = [:]
    var lastCompletedStream: OmniSileroStream.CompletedReply?

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
                        // note (assistant): Disconnect owns its queued cleanup barrier and releases admission last.
                        if lifetime.isActive, owner?.id == lifetime.id, loadOperationID == operation { clearModel() }
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
                guard activeRequest == nil, streams.isEmpty else {
                    throw OmniXPCFailure.error(.busy, "Close Silero streams and finish the offline request before unloading.")
                }
                guard requestIDs[operation] == nil else {
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
                        if owner?.id == lifetime.id, self.modelID == requestedModelID { clearModel() }
                        return cancelled
                    }
                    reply(cancelled ? OmniXPCFailure.error(.cancelled, "The Silero unload was cancelled.") : nil)
                }
            }
        } catch {
            reply(error as NSError)
        }
    }

    func cancel(requestID: String, modelID: String?, lifetime: ConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        let requestedModelID = try modelID.map(identifier)
        var cancellingModel: SileroCoreModel?
        var cancellingRequestID: UUID?
        var cancellingLeases: [SileroCoreStreamLease] = []
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            if let requestedModelID {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard requestIDs[requestedID] != nil else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero request ID has not been registered.")
                }
                if let stream = streams[requestedID] {
                    stream.state = .cancelled
                    cancellingLeases = [stream.lease]
                } else if activeRequest?.id == requestedID {
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
                    cancellingLeases = cancelOwnedStreams()
                    enqueueCleanup(lifetime: lifetime, loadOperationID: requestedID)
                }
            } else if let operation = lifetime.operations[requestedID] {
                if operation == .active { lifetime.operations[requestedID] = .cancelled }
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The Silero operation is stale or belongs to another connection.")
            }
        }
        if let cancellingRequestID { cancellingModel?.cancelRequest(requestID: cancellingRequestID) }
        for lease in cancellingLeases { lease.cancel() }
    }

    func disconnect(lifetime: ConnectionLifetime) {
        var cancellingModel: SileroCoreModel?
        var cancellingRequestID: UUID?
        var cancellingLeases: [SileroCoreStreamLease] = []
        lock.withLock {
            guard lifetime.isActive else { return }
            lifetime.isActive = false
            guard owner?.id == lifetime.id else { return }
            modelState = .unloading
            activeRequest?.isCancelled = true
            cancellingModel = model
            cancellingRequestID = activeRequest?.id
            cancellingLeases = cancelOwnedStreams()
            enqueueCleanup(lifetime: lifetime, loadOperationID: loadOperationID!)
        }
        // note (assistant): Token cancellation must bypass the queue that may be waiting for Native GPU work.
        if let cancellingRequestID { cancellingModel?.cancelRequest(requestID: cancellingRequestID) }
        for lease in cancellingLeases { lease.cancel() }
    }

    func requireValidationIdle(lifetime: ConnectionLifetime) throws {
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded, owner == nil, activeRequest == nil, streams.isEmpty else {
                throw OmniXPCFailure.error(.busy, "Unload the Silero model before using the diagnostic endpoint.")
            }
        }
    }

    private func cancelOwnedStreams() -> [SileroCoreStreamLease] {
        streams.values.map { stream in
            stream.state = .cancelled
            return stream.lease
        }
    }

    private func enqueueCleanup(lifetime: ConnectionLifetime, loadOperationID: UUID) {
        queue.async { [self] in
            let owned = lock.withLock { () -> (SileroCoreModel?, [OmniSileroStream]) in
                guard owner?.id == lifetime.id, self.loadOperationID == loadOperationID else { return (nil, []) }
                precondition(activeRequest == nil)
                return (model, Array(streams.values))
            }
            for stream in owned.1 {
                do {
                    stream.lease.cancel()
                    try stream.lease.drainAndDestroy()
                    lock.withLock { _ = streams.removeValue(forKey: stream.id) }
                } catch {
                    // note (assistant): Failed barriers retain the lease and model instead of claiming safe release.
                    NSLog("Native Silero cleanup barrier failed; model retained.")
                }
            }
            guard lock.withLock({ streams.isEmpty }) else { return }
            owned.0?.close()
            lock.withLock {
                guard owner?.id == lifetime.id, self.loadOperationID == loadOperationID else { return }
                clearModel()
            }
        }
    }

    func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value) else {
            throw OmniXPCFailure.error(.invalidRequest, "Model, request and operation IDs must be UUIDs.")
        }
        return identifier
    }

    func requireOwner(_ lifetime: ConnectionLifetime, modelID requestedModelID: UUID) throws {
        guard lifetime.isActive, owner?.id == lifetime.id, modelID == requestedModelID else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero model ID is stale or belongs to another connection.")
        }
        guard modelState == .ready else {
            throw OmniXPCFailure.error(.busy, "The Native Silero model is not ready.")
        }
    }

    func requireUnusedRequestID(_ requestedID: UUID, lifetime: ConnectionLifetime) throws {
        guard requestIDs[requestedID] == nil, lifetime.operations[requestedID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero request ID has already been used.")
        }
        guard requestIDs.count < OmniXPCProtocolLimits.maximumRequestsPerModel else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero request ledger is full; unload the model.")
        }
    }

    private func clearModel() {
        precondition(activeRequest == nil && streams.isEmpty)
        model = nil
        modelID = nil
        owner = nil
        loadOperationID = nil
        requestIDs.removeAll(keepingCapacity: false)
        lastCompletedStream = nil
        modelState = .unloaded
    }
}
#endif
