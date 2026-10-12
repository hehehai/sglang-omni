import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniBatchInferenceEngine {
    func drainLoad(operationID: String, lifetime: ConnectionLifetime, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            let operation = try identifier(operationID)
            var alreadyClosed = false
            let cancelling = try lock.withLock { () throws -> BatchCoreRequest? in
                guard lifetime.isActive else { throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.") }
                if lifetime.loads[operation] == .closed {
                    alreadyClosed = true
                    return nil
                }
                if lifetime.loads[operation] == nil {
                    guard operation != loadOperationID, operation != modelID, !requestIDs.contains(operation),
                          lifetime.businessIDs[operation] == nil else { throw OmniXPCBatchFailure.error(.invalid) }
                    guard lifetime.loads.count < OmniXPCBatchLimits.maximumLoadsPerConnection else {
                        throw OmniXPCBatchFailure.error(.limit)
                    }
                    lifetime.loads[operation] = .closed
                    alreadyClosed = true
                    return nil
                }
                guard owner === lifetime, loadOperationID == operation else { throw OmniXPCBatchFailure.error(.invalid) }
                guard !cleanupPending else { throw OmniXPCBatchFailure.error(.busy) }
                modelState = .closing
                enqueueCleanup(lifetime: lifetime, operation: operation, reply: reply)
                return request
            }
            cancelling?.cancel()
            if alreadyClosed { reply(nil) }
        } catch { reply(error as NSError) }
    }

    func unload(operationID: String, modelID: String, lifetime: ConnectionLifetime,
                reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            let operation = try identifier(operationID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard request == nil, !cleanupPending, let loadOperationID else { throw OmniXPCBatchFailure.error(.busy) }
                try lifetime.recordBusiness(operation, kind: .unload)
                modelState = .closing
                enqueueCleanup(lifetime: lifetime, operation: loadOperationID, reply: reply)
            }
        } catch { reply(error as NSError) }
    }

    func enqueueCleanup(lifetime: ConnectionLifetime, operation: UUID,
                        reply: (@Sendable (NSError?) -> Void)? = nil) {
        guard !cleanupPending else { return }
        cleanupPending = true
        queue.async { [self] in
            let failure: NSError?
            do {
                try drainOwnedModel(lifetime: lifetime, operation: operation)
                failure = nil
            } catch { failure = error as NSError }
            let active = lock.withLock {
                if owner === lifetime, loadOperationID == operation { cleanupPending = false }
                return lifetime.isActive
            }
            if let reply {
                reply(active ? failure : OmniXPCFailure.error(.disconnected, "The XPC connection is closing."))
            } else if failure != nil {
                NSLog("Native batch cleanup failed; original load and reader retained.")
            }
        }
    }

    private func drainOwnedModel(lifetime: ConnectionLifetime, operation: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let resources = try lock.withLock { () throws -> (BatchCoreModel?, BatchCoreRequest?) in
            if lifetime.loads[operation] == .closed { return (nil, nil) }
            guard owner === lifetime, loadOperationID == operation, modelState == .closing else {
                throw OmniXPCBatchFailure.error(.invalid)
            }
            return (model, request)
        }
        resources.1?.cancel()
        try resources.1?.drainAndDestroy()
        lock.withLock {
            if owner === lifetime, loadOperationID == operation {
                request = nil
                requestID = nil
            }
        }
        try resources.0?.close()
        lock.withLock {
            if owner === lifetime, loadOperationID == operation { clearModel() }
        }
    }

    func clearModel() {
        precondition(request == nil)
        if let owner, let loadOperationID { owner.loads[loadOperationID] = .closed }
        model = nil
        modelID = nil
        owner = nil
        loadOperationID = nil
        requestID = nil
        requestIDs.removeAll()
        cleanupPending = false
        modelState = .unloaded
    }
}
#endif
