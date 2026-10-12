/// Load-scoped tombstones and serial Native barriers for Sortformer model release.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSortformerInferenceEngine {
    func drainLoad(
        operationID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let operation = try identifier(operationID)
            var cancellingLeases: [SortformerCoreStreamLease] = []
            let isClosed = try lock.withLock {
                guard lifetime.isActive else {
                    throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
                }
                if lifetime.loads[operation] == .closed { return true }
                if lifetime.loads[operation] == nil {
                    guard operation != modelID, operation != loadOperationID,
                          requestIDs[operation] == nil, lifetime.operations[operation] == nil else {
                        throw OmniXPCFailure.error(.invalidRequest, "The drain ID is not a load owned by this connection.")
                    }
                    guard lifetime.loads.count < OmniXPCSortformerLimits.maximumLoadsPerConnection else {
                        throw OmniXPCFailure.error(.busy, "The Sortformer load ledger is full for this connection.")
                    }
                    lifetime.loads[operation] = .closed
                    return true
                }
                guard owner?.id == lifetime.id, loadOperationID == operation else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer load belongs to another connection.")
                }
                guard !lifetime.isLoadDrainPending else {
                    throw OmniXPCFailure.error(.busy, "The connection already has a pending Sortformer load drain.")
                }
                lifetime.isLoadDrainPending = true
                lifetime.operations[operation] = .cancelled
                modelState = .unloading
                cancellingLeases = cancelOwnedStreams()
                // note (assistant): Admission ordering keeps this barrier behind accepted Native creation and commands.
                queue.async { [self] in
                    let failure: NSError?
                    do {
                        try drainOwnedModel(lifetime: lifetime, loadOperationID: operation)
                        failure = nil
                    } catch {
                        failure = error as NSError
                    }
                    let isActive = lock.withLock {
                        lifetime.isLoadDrainPending = false
                        return lifetime.isActive
                    }
                    reply(isActive ? failure : OmniXPCFailure.error(.disconnected, "The XPC connection is closing."))
                }
                return false
            }
            for lease in cancellingLeases { lease.cancel() }
            if isClosed { reply(nil) }
        } catch {
            reply(error as NSError)
        }
    }

    func cancelOwnedStreams() -> [SortformerCoreStreamLease] {
        streams.values.map { stream in
            stream.state = .cancelled
            stream.lastAudio = nil
            stream.lastReply = nil
            return stream.lease
        }
    }

    func enqueueCleanup(lifetime: ConnectionLifetime, loadOperationID: UUID) {
        guard !isCleanupPending else { return }
        isCleanupPending = true
        queue.async { [self] in
            do {
                try drainOwnedModel(lifetime: lifetime, loadOperationID: loadOperationID)
            } catch {
                lock.withLock {
                    if owner?.id == lifetime.id, self.loadOperationID == loadOperationID { isCleanupPending = false }
                }
                NSLog("Native Sortformer cleanup barrier failed; model retained for retry: %@", error.localizedDescription)
            }
        }
    }

    private func drainOwnedModel(lifetime: ConnectionLifetime, loadOperationID: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let owned = try lock.withLock { () throws -> (SortformerCoreModel, [OmniSortformerStream])? in
            if lifetime.loads[loadOperationID] == .closed { return nil }
            guard owner?.id == lifetime.id, self.loadOperationID == loadOperationID else {
                throw OmniXPCFailure.error(.invalidRequest, "The Sortformer load is not owned by this connection.")
            }
            precondition(modelState == .unloading && model != nil)
            return (model!, Array(streams.values))
        }
        guard let owned else { return }
        var drainFailure: Error?
        for stream in owned.1 {
            do {
                // note (assistant): The queue can reach cleanup before the admitting caller signals cancellation.
                stream.lease.cancel()
                try stream.lease.drainAndDestroy()
                lock.withLock {
                    streams.removeValue(forKey: stream.id)
                    requestIDs[stream.id] = .closed
                }
            } catch {
                lock.withLock { stream.isClosePending = false }
                drainFailure = drainFailure ?? error
            }
        }
        if let drainFailure { throw drainFailure }
        try owned.0.close()
        lock.withLock { clearModel() }
    }

    func clearModel() {
        precondition(streams.isEmpty)
        if let owner, let loadOperationID { owner.loads[loadOperationID] = .closed }
        model = nil
        modelID = nil
        owner = nil
        loadOperationID = nil
        requestIDs.removeAll(keepingCapacity: false)
        isCleanupPending = false
        isModelUnloadPending = false
        modelState = .unloaded
    }
}
#endif
