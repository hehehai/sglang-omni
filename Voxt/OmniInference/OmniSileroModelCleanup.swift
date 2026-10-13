/// Original-load tombstones survive unpublished loads and lost retirement replies.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSileroInferenceEngine {
    func drainLoad(
        operationID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let operation = try identifier(operationID)
            var cancellingModel: SileroCoreModel?
            var cancellingRequestID: UUID?
            var cancellingLeases: [SileroCoreStreamLease] = []
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
                    guard lifetime.loads.count < OmniXPCSileroLimits.maximumLoadsPerConnection else {
                        throw OmniXPCFailure.error(.busy, "The Silero load ledger is full for this connection.")
                    }
                    // note (assistant): This tombstone rejects a delayed load with the same original operation ID.
                    lifetime.loads[operation] = .closed
                    return true
                }
                guard owner?.id == lifetime.id, loadOperationID == operation else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero load belongs to another connection.")
                }
                guard !lifetime.isLoadDrainPending else {
                    throw OmniXPCFailure.error(.busy, "The connection already has a pending Silero load drain.")
                }
                lifetime.isLoadDrainPending = true
                lifetime.operations[operation] = .cancelled
                modelState = .unloading
                activeRequest?.isCancelled = true
                cancellingModel = model
                cancellingRequestID = activeRequest?.id
                cancellingLeases = cancelOwnedStreams()
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
            if let cancellingRequestID { cancellingModel?.cancelRequest(requestID: cancellingRequestID) }
            for lease in cancellingLeases { lease.cancel() }
            if isClosed { reply(nil) }
        } catch {
            reply(error as NSError)
        }
    }

    func cancelOwnedStreams() -> [SileroCoreStreamLease] {
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
                NSLog("Native Silero cleanup barrier failed; model retained for retry: %@", error.localizedDescription)
            }
        }
    }

    private func drainOwnedModel(lifetime: ConnectionLifetime, loadOperationID: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let owned = try lock.withLock { () throws -> (SileroCoreModel, [OmniSileroStream])? in
            if lifetime.loads[loadOperationID] == .closed { return nil }
            guard owner?.id == lifetime.id, self.loadOperationID == loadOperationID else {
                throw OmniXPCFailure.error(.invalidRequest, "The Silero load is not owned by this connection.")
            }
            precondition(modelState == .unloading && model != nil && activeRequest == nil)
            return (model!, Array(streams.values))
        }
        guard let owned else { return }
        var drainFailure: Error?
        for stream in owned.1 {
            do {
                stream.lease.cancel()
                try stream.lease.drainAndDestroy()
                lock.withLock { _ = streams.removeValue(forKey: stream.id) }
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
        precondition(activeRequest == nil && streams.isEmpty)
        if let owner, let loadOperationID { owner.loads[loadOperationID] = .closed }
        model = nil
        modelID = nil
        owner = nil
        loadOperationID = nil
        requestIDs.removeAll(keepingCapacity: false)
        lastCompletedStream = nil
        isCleanupPending = false
        isModelUnloadPending = false
        modelState = .unloaded
    }
}
#endif
