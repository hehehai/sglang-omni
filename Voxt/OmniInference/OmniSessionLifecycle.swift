/// Connection-owned model lifecycle and shared final/realtime admission.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniFinalSessionEngine: @unchecked Sendable {
    enum ModelState { case unloaded, loading, ready, unloading }

    let configuration: OmniXPCConfiguration
    let queue = DispatchQueue(label: "Voxt.Omni.XPC.inference")
    let lock = NSLock()
    var modelState: ModelState = .unloaded
    var owner: OmniConnectionLifetime?
    var modelID: UUID?
    var model: QwenCoreModel?
    var session: OmniXPCFinalSessionBuffer?
    var isFinalFinishPending = false
    var reservedFinalAudioByteCount = 0
    var realtimeSession: OmniRealtimeSession?
    var lastDrainedRealtime: OmniRealtimeSession.DrainedIdentity?
    var sessionIDs: Set<UUID> = []
    var validationTerminationPending = false

    init(configuration: OmniXPCConfiguration) { self.configuration = configuration }

    func groupContainer() throws -> URL {
        try OmniServiceIdentity.groupContainer(configuration: configuration)
    }

    func load(
        operationID: String, modelDirectory: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) {
        do {
            try admitLoad(operationID: operationID, modelDirectory: modelDirectory, lifetime: lifetime, reply: reply)
        } catch {
            reply(nil, nil, error as NSError)
        }
    }

    func admitLoad(
        operationID: String, modelDirectory: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) throws {
        let operation = try identifier(operationID)
        try lock.withLock {
            guard lifetime.isActive, !validationTerminationPending else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded else {
                throw OmniXPCFailure.error(.busy, "Unload the current model before loading another model.")
            }
            try lifetime.recordOperation(operation)
            owner = lifetime
            modelState = .loading
            // note (assistant): Enqueue under the lock so disconnect cannot overtake admitted work.
            queue.async { [self] in
                do {
                    let directory = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: modelDirectory, container: groupContainer()
                    )
                    guard lock.withLock({ lifetime.isActive && lifetime.operations[operation] != .cancelled }) else {
                        throw OmniXPCFailure.error(.cancelled, "The model load was cancelled.")
                    }
                    let loaded = try QwenCoreModel(directory: directory)
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
                        throw OmniXPCFailure.error(.cancelled, "The model load was cancelled.")
                    }
                } catch {
                    let cancelled = lock.withLock {
                        let cancelled = !lifetime.isActive || lifetime.operations[operation] == .cancelled
                        lifetime.operations[operation] = cancelled ? .cancelled : .completed
                        clearModel()
                        return cancelled
                    }
                    reply(nil, nil, cancelled
                          ? OmniXPCFailure.error(.cancelled, "The model load was cancelled.") : error as NSError)
                }
            }
        }
    }

    func unload(
        operationID: String, modelID: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let operation = try identifier(operationID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard session == nil, realtimeSession == nil else {
                    throw OmniXPCFailure.error(.busy, "Drain or close the active session before unloading.")
                }
                guard !sessionIDs.contains(operation) else {
                    throw OmniXPCFailure.error(.invalidRequest, "The operation ID has already been used for a session.")
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
                    reply(cancelled ? OmniXPCFailure.error(.cancelled, "The unload operation was cancelled.") : nil)
                }
            }
        } catch {
            reply(error as NSError)
        }
    }

    func cancel(requestID: String, modelID: String?, lifetime: OmniConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        let requestedModelID = try modelID.map(identifier)
        var finalModel: QwenCoreModel?
        var realtimeLease: QwenCoreRealtimeLease?
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            if let requestedModelID {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard sessionIDs.contains(requestedID) else {
                    throw OmniXPCFailure.error(.invalidRequest, "The session ID has not been registered on this model.")
                }
                if realtimeSession?.sessionID == requestedID {
                    realtimeLease = realtimeSession!.lease
                } else if session?.sessionID == requestedID {
                    finalModel = cancelFinalSession()
                } else {
                    // note (assistant): Registered terminated identities are idempotent, not model-wide cancellation.
                }
            } else if let operation = lifetime.operations[requestedID] {
                if operation == .active { lifetime.operations[requestedID] = .cancelled }
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The request ID is stale or belongs to another connection.")
            }
        }
        realtimeLease?.cancel()
        finalModel?.cancelRequest(sessionID: requestedID)
    }

    func disconnect(lifetime: OmniConnectionLifetime) {
        var finalModel: QwenCoreModel?
        var finalSessionID: UUID?
        var realtimeLease: QwenCoreRealtimeLease?
        lock.withLock {
            guard lifetime.isActive else { return }
            lifetime.isActive = false
            guard owner?.id == lifetime.id else { return }
            finalSessionID = session?.sessionID
            finalModel = cancelFinalSession()
            realtimeLease = realtimeSession?.lease
            queue.async { [self] in
                let resources = lock.withLock { () -> (OmniRealtimeSession?, QwenCoreModel?) in
                    guard owner?.id == lifetime.id else { return (nil, nil) }
                    return (realtimeSession, model)
                }
                do {
                    resources.0?.lease.cancel()
                    try resources.0?.lease.drainAndDestroy()
                    resources.1?.close()
                    lock.withLock {
                        guard owner?.id == lifetime.id else { return }
                        clearModel()
                    }
                } catch {
                    // note (assistant): A failed barrier must retain the model and lease rather than free live work.
                    NSLog("Omni realtime disconnect drain failed; model retained.")
                }
            }
        }
        realtimeLease?.cancel()
        if let finalSessionID { finalModel?.cancelRequest(sessionID: finalSessionID) }
    }

    func reserveValidationTermination(lifetime: OmniConnectionLifetime) throws {
        try lock.withLock {
            guard lifetime.isActive, !validationTerminationPending else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded, owner == nil, session == nil, realtimeSession == nil else {
                throw OmniXPCFailure.error(.busy, "Unload the model before using the diagnostic endpoint.")
            }
            validationTerminationPending = true
        }
    }

    func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value) else {
            throw OmniXPCFailure.error(.invalidRequest, "Model, session and operation IDs must be UUIDs.")
        }
        return identifier
    }

    func requireOwner(_ lifetime: OmniConnectionLifetime, modelID requestedModelID: UUID) throws {
        guard lifetime.isActive, owner?.id == lifetime.id, requestedModelID == modelID else {
            throw OmniXPCFailure.error(.invalidRequest, "The model ID is stale or belongs to another connection.")
        }
        guard modelState == .ready else {
            throw OmniXPCFailure.error(.busy, "The Native Qwen model is not ready.")
        }
    }

    func requireSessionAdmission(_ sessionID: UUID, modelID: UUID, lifetime: OmniConnectionLifetime) throws {
        try requireOwner(lifetime, modelID: modelID)
        guard !sessionIDs.contains(sessionID), lifetime.operations[sessionID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The session ID has already been used.")
        }
        guard sessionIDs.count < OmniXPCProtocolLimits.maximumRequestsPerModel else {
            throw OmniXPCFailure.error(.invalidRequest, "The session ledger is full; unload the model before continuing.")
        }
        guard session == nil, realtimeSession == nil else {
            throw OmniXPCFailure.error(.busy, "The model already has an active session.")
        }
    }

    private func cancelFinalSession() -> QwenCoreModel? {
        guard session?.cancel() == true else { return nil }
        if session?.isTerminal == true {
            if !isFinalFinishPending { session = nil }
            return nil
        } else {
            return model
        }
    }

    private func clearModel() {
        model = nil
        modelID = nil
        owner = nil
        session = nil
        isFinalFinishPending = false
        reservedFinalAudioByteCount = 0
        realtimeSession = nil
        lastDrainedRealtime = nil
        sessionIDs.removeAll(keepingCapacity: false)
        modelState = .unloaded
    }
}
#endif
