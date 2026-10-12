/// Connection-owned Sortformer model admission and retryable drain-before-release lifecycle.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniSortformerInferenceEngine: @unchecked Sendable {
    nonisolated final class ConnectionLifetime: @unchecked Sendable {
        enum OperationState { case active, cancelled, completed }
        enum LoadState { case active, closed }

        let id = UUID()
        // note (assistant): Only the Sortformer engine lock protects this lifetime and its ledger.
        var isActive = true
        var operations: [UUID: OperationState] = [:]
        var loads: [UUID: LoadState] = [:]
        var isLoadDrainPending = false
        private var operationOrder: [UUID] = []

        func recordOperation(_ operationID: UUID) throws {
            guard operations[operationID] == nil, loads[operationID] == nil else {
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
    enum StreamHistory { case registered, finished, closed }

    private let configuration: OmniXPCConfiguration
    let queue = DispatchQueue(label: "Voxt.Omni.XPC.sortformer")
    let lock = NSLock()
    var modelState: ModelState = .unloaded
    var owner: ConnectionLifetime?
    var modelID: UUID?
    var loadOperationID: UUID?
    var model: SortformerCoreModel?
    var requestIDs: [UUID: StreamHistory] = [:]
    var streams: [UUID: OmniSortformerStream] = [:]
    var isCleanupPending = false
    var isModelUnloadPending = false

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
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model path exceeds validation limits.")
        }
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded else {
                throw OmniXPCFailure.error(.busy, "Unload the current Sortformer model before loading another model.")
            }
            guard lifetime.loads.count < OmniXPCSortformerLimits.maximumLoadsPerConnection else {
                throw OmniXPCFailure.error(.busy, "The Sortformer load ledger is full for this connection.")
            }
            try lifetime.recordOperation(operation)
            lifetime.loads[operation] = .active
            owner = lifetime
            loadOperationID = operation
            modelState = .loading
            // note (assistant): Enqueue under admission so disconnect cleanup cannot overtake accepted work.
            queue.async { [self] in
                do {
                    let directoryLease = try OmniServiceIdentity.modelDirectoryLease(
                        relativePath: modelDirectory, configuration: configuration
                    )
                    guard lock.withLock({ lifetime.isActive && lifetime.operations[operation] != .cancelled }) else {
                        throw OmniXPCFailure.error(.cancelled, "The Sortformer load was cancelled.")
                    }
                    let loaded = try SortformerCoreModel(directoryLease: directoryLease)
                    let publishedModelID = lock.withLock { () -> UUID? in
                        guard lifetime.isActive, lifetime.operations[operation] != .cancelled else { return nil }
                        var newModelID = UUID()
                        while lifetime.loads[newModelID] != nil || lifetime.operations[newModelID] != nil {
                            newModelID = UUID()
                        }
                        model = loaded
                        modelID = newModelID
                        modelState = .ready
                        lifetime.operations[operation] = .completed
                        return newModelID
                    }
                    if let publishedModelID {
                        reply(publishedModelID.uuidString, OmniServiceIdentity.instanceID.uuidString, nil)
                    } else {
                        lock.withLock {
                            model = loaded
                            modelState = .unloading
                        }
                        try loaded.close()
                        lock.withLock { model = nil }
                        throw OmniXPCFailure.error(.cancelled, "The Sortformer load was cancelled.")
                    }
                } catch {
                    let cancelled = lock.withLock {
                        let cancelled = !lifetime.isActive || lifetime.operations[operation] == .cancelled
                        lifetime.operations[operation] = cancelled ? .cancelled : .completed
                        if owner?.id == lifetime.id, loadOperationID == operation, model == nil { clearModel() }
                        return cancelled
                    }
                    reply(nil, nil, cancelled
                          ? OmniXPCFailure.error(.cancelled, "The Sortformer load was cancelled.") : error as NSError)
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
                guard lifetime.isActive, owner?.id == lifetime.id, self.modelID == requestedModelID else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model belongs to another connection.")
                }
                guard modelState == .ready || modelState == .unloading,
                      model != nil, !isModelUnloadPending, !isCleanupPending, !lifetime.isLoadDrainPending else {
                    throw OmniXPCFailure.error(.busy, "The Sortformer model has pending cleanup.")
                }
                guard streams.isEmpty else {
                    throw OmniXPCFailure.error(.busy, "Close Sortformer streams before unloading the model.")
                }
                guard operation != requestedModelID, requestIDs[operation] == nil else {
                    throw OmniXPCFailure.error(.invalidRequest, "The operation ID aliases a model or stream ID.")
                }
                try lifetime.recordOperation(operation)
                let loaded = model!
                modelState = .unloading
                isModelUnloadPending = true
                queue.async { [self] in
                    do {
                        try loaded.close()
                        let cancelled = lock.withLock {
                            isModelUnloadPending = false
                            let cancelled = !lifetime.isActive || lifetime.operations[operation] == .cancelled
                            lifetime.operations[operation] = cancelled ? .cancelled : .completed
                            if owner?.id == lifetime.id, self.modelID == requestedModelID { clearModel() }
                            return cancelled
                        }
                        reply(cancelled ? OmniXPCFailure.error(.cancelled, "The Sortformer unload was cancelled.") : nil)
                    } catch {
                        lock.withLock {
                            isModelUnloadPending = false
                            lifetime.operations[operation] = .completed
                        }
                        reply(error as NSError)
                    }
                }
            }
        } catch {
            reply(error as NSError)
        }
    }

    func cancel(requestID: String, modelID: String?, lifetime: ConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        let requestedModelID = try modelID.map(identifier)
        var cancellingLeases: [SortformerCoreStreamLease] = []
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            if let requestedModelID {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard requestIDs[requestedID] != nil else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream ID has not been registered.")
                }
                if let stream = streams[requestedID] {
                    stream.state = .cancelled
                    stream.lastAudio = nil
                    stream.lastReply = nil
                    cancellingLeases = [stream.lease]
                }
            } else if lifetime.loads[requestedID] == .closed {
                return
            } else if owner?.id == lifetime.id, loadOperationID == requestedID {
                lifetime.operations[requestedID] = .cancelled
                modelState = .unloading
                cancellingLeases = cancelOwnedStreams()
                enqueueCleanup(lifetime: lifetime, loadOperationID: requestedID)
            } else if let operation = lifetime.operations[requestedID] {
                if operation == .active { lifetime.operations[requestedID] = .cancelled }
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The Sortformer operation is stale or belongs to another connection.")
            }
        }
        for lease in cancellingLeases { lease.cancel() }
    }

    func disconnect(lifetime: ConnectionLifetime) {
        let cancellingLeases = lock.withLock { () -> [SortformerCoreStreamLease] in
            lifetime.isActive = false
            guard owner?.id == lifetime.id else { return [] }
            modelState = .unloading
            let leases = cancelOwnedStreams()
            enqueueCleanup(lifetime: lifetime, loadOperationID: loadOperationID!)
            return leases
        }
        // note (assistant): Cancellation bypasses the queue even while it waits on a Native worker command.
        for lease in cancellingLeases { lease.cancel() }
    }

    func requireValidationIdle(lifetime: ConnectionLifetime) throws {
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded, owner == nil, streams.isEmpty else {
                throw OmniXPCFailure.error(.busy, "Unload the Sortformer model before using the diagnostic endpoint.")
            }
        }
    }

    func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value) else {
            throw OmniXPCFailure.error(.invalidRequest, "Model, stream and operation IDs must be UUIDs.")
        }
        return identifier
    }

    func requireOwner(_ lifetime: ConnectionLifetime, modelID requestedModelID: UUID) throws {
        guard lifetime.isActive, owner?.id == lifetime.id, modelID == requestedModelID else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model ID is stale or belongs to another connection.")
        }
        guard modelState == .ready else {
            throw OmniXPCFailure.error(.busy, "The Native Sortformer model is not ready.")
        }
    }

    func requireUnusedRequestID(_ requestedID: UUID, lifetime: ConnectionLifetime) throws {
        guard requestedID != modelID, requestIDs[requestedID] == nil,
              lifetime.operations[requestedID] == nil, lifetime.loads[requestedID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream ID aliases a model or used operation ID.")
        }
        guard requestIDs.count < OmniXPCProtocolLimits.maximumRequestsPerModel else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream ledger is full; unload the model.")
        }
    }
}
#endif
