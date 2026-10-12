import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSpeakerInferenceEngine {
    func drainLoad(operationID: String, lifetime: ConnectionLifetime, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            let operation = try identifier(operationID)
            let alreadyClosed = try lock.withLock { () throws -> Bool in
                guard lifetime.isActive else { throw SpeakerCoreModel.error(.cancelled) }
                if lifetime.loads[operation] == .closed { return true }
                if lifetime.loads[operation] == nil {
                    guard lifetime.businessIDs[operation] == nil, operation != loadOperationID,
                          operation != modelReference?.modelID, operation != session?.reference.sessionID,
                          owner?.businessIDs[operation] == nil, owner?.loads[operation] == nil else {
                        throw SpeakerCoreModel.error(.invalid)
                    }
                    guard lifetime.loads.count < Self.maximumLedgerCount else { throw SpeakerCoreModel.error(.limit) }
                    lifetime.loads[operation] = .closed
                    return true
                }
                guard owner === lifetime, loadOperationID == operation else { throw SpeakerCoreModel.error(.invalid) }
                modelState = .closing
                session?.isClosing = true
                return false
            }
            if alreadyClosed { reply(nil) }
            else { scheduleCleanup(lifetime: lifetime, operation: operation, reply: reply) }
        } catch { reply(error as NSError) }
    }

    func unload(operationID: String, modelReference: Data, lifetime: ConnectionLifetime,
                reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            let operation = try identifier(operationID)
            let reference = try OmniXPCSpeakerModelReference.decode(modelReference)
            let alreadyClosed = try lock.withLock { () throws -> Bool in
                guard lifetime.isActive, lifetime.models[reference.modelID] == reference else {
                    throw SpeakerCoreModel.error(.invalid)
                }
                guard lifetime.loads[reference.loadOperationID] == .closed || session == nil || owner !== lifetime else {
                    throw SpeakerCoreModel.error(.busy)
                }
                if let previous = lifetime.unloads[operation] {
                    guard previous == reference else { throw SpeakerCoreModel.error(.invalid) }
                } else {
                    try lifetime.recordBusiness(operation, kind: .unload)
                    lifetime.unloads[operation] = reference
                }
                if lifetime.loads[reference.loadOperationID] == .closed { return true }
                try requireOwner(lifetime, reference: reference)
                modelState = .closing
                return false
            }
            if alreadyClosed { reply(nil) }
            else { scheduleCleanup(lifetime: lifetime, operation: reference.loadOperationID, reply: reply) }
        } catch { reply(error as NSError) }
    }

    func scheduleCleanup(lifetime: ConnectionLifetime, operation: UUID,
                         reply: (@Sendable (NSError?) -> Void)? = nil) {
        do {
            let stream = try lock.withLock { () throws -> SpeakerCoreStream? in
                guard owner === lifetime, loadOperationID == operation else { throw SpeakerCoreModel.error(.invalid) }
                guard !cleanupPending else { throw SpeakerCoreModel.error(.busy) }
                cleanupPending = true
                modelState = .closing
                session?.isClosing = true
                return session?.stream
            }
            // note (assistant): Wake Finish outside the command queue before enqueuing its joining barrier.
            stream?.cancel()
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
                    reply(active ? failure : SpeakerCoreModel.error(.cancelled))
                } else if failure != nil {
                    NSLog("Native speaker cleanup failed; original scope, handles and reader retained.")
                }
            }
        } catch {
            if let reply { reply(error as NSError) }
            else { NSLog("Native speaker cleanup already pending or scope retired.") }
        }
    }

    private func drainOwnedModel(lifetime: ConnectionLifetime, operation: UUID) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let resources = try lock.withLock { () throws -> (SpeakerCoreModel?, SessionRecord?) in
            guard owner === lifetime, loadOperationID == operation, modelState == .closing else {
                throw SpeakerCoreModel.error(.invalid)
            }
            return (model, session)
        }
        if let record = resources.1 { try retireSession(record) }
        try resources.0?.close()
        lock.withLock {
            precondition(owner === lifetime && loadOperationID == operation && session == nil)
            lifetime.loads[operation] = .closed
            model = nil
            modelReference = nil
            owner = nil
            loadOperationID = nil
            cleanupPending = false
            modelState = .unloaded
        }
    }
}
#endif
