/// Lock-protected final sessions with serialized Native model creation, inference and destruction.
import Foundation

#if os(macOS)
nonisolated final class OmniFinalSessionEngine: @unchecked Sendable {
    private enum ModelState { case unloaded, loading, ready, unloading }

    static let serviceInstanceID = UUID()
    let configuration: OmniXPCConfiguration
    private let queue = DispatchQueue(label: "Voxt.Omni.XPC.inference")
    private let lock = NSLock()
    private var modelState: ModelState = .unloaded
    private var owner: OmniConnectionLifetime?
    private var modelID: UUID?
    private var model: QwenCoreModel?
    private var session: OmniXPCFinalSessionBuffer?
    private var sessionIDs: Set<UUID> = []
    private var validationTerminationPending = false

    init(configuration: OmniXPCConfiguration) { self.configuration = configuration }

    func groupContainer() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            throw OmniXPCFailure.error(.configuration, "The XPC service cannot access its configured App Group.")
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    func load(
        operationID: String, modelDirectory: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) {
        do {
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
                // note (assistant): Enqueue under the lock so disconnect's destruction barrier cannot overtake creation.
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
                            reply(newModelID.uuidString, Self.serviceInstanceID.uuidString, nil)
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
        } catch {
            reply(nil, nil, error as NSError)
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
                guard session == nil else {
                    throw OmniXPCFailure.error(.busy, "Cancel or finish the active final session before unloading.")
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

    func start(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        lifetime: OmniConnectionLifetime
    ) throws {
        let requestedSessionID = try identifier(sessionID)
        let requestedModelID = try identifier(modelID)
        try lock.withLock {
            try requireOwner(lifetime, modelID: requestedModelID)
            guard !sessionIDs.contains(requestedSessionID), lifetime.operations[requestedSessionID] == nil else {
                throw OmniXPCFailure.error(.invalidRequest, "The session ID has already been used.")
            }
            guard sessionIDs.count < OmniXPCProtocolLimits.maximumRequestsPerModel else {
                throw OmniXPCFailure.error(.invalidRequest, "The session ledger is full; unload the model before continuing.")
            }
            guard session == nil else {
                throw OmniXPCFailure.error(.busy, "The model already has an active final session.")
            }
            session = try OmniXPCFinalSessionBuffer(
                sessionID: requestedSessionID, modelID: requestedModelID,
                language: language, context: context, maximumTokenCount: maximumTokenCount
            )
            sessionIDs.insert(requestedSessionID)
        }
    }

    func push(sessionID: String, modelID: String, sequence: Int, audio: Data, lifetime: OmniConnectionLifetime) throws -> Int {
        let requestedSessionID = try identifier(sessionID)
        let requestedModelID = try identifier(modelID)
        return try lock.withLock {
            try requireOwner(lifetime, modelID: requestedModelID)
            guard session?.sessionID == requestedSessionID else {
                throw OmniXPCFailure.error(.invalidRequest, "The final session is stale or no longer receiving audio.")
            }
            return try session!.append(audio: audio, sequence: sequence)
        }
    }

    func finish(
        sessionID: String, modelID: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard session?.sessionID == requestedSessionID else {
                    throw OmniXPCFailure.error(.invalidRequest, "The final session is stale or has already terminated.")
                }
                let samples = try session!.beginFinish()
                let language = session!.language
                let context = session!.context
                let maximumTokenCount = session!.maximumTokenCount
                let loaded = model!
                do {
                    try loaded.prepareRequest()
                } catch {
                    session!.complete(succeeded: false)
                    session = nil
                    throw error
                }
                queue.async { [self] in
                    var result: QwenReply?
                    var failure: NSError?
                    do {
                        result = try loaded.transcribe(
                            samples: samples, language: language, context: context, maximumTokenCount: maximumTokenCount
                        )
                    } catch {
                        failure = error as NSError
                    }
                    let cancelled = lock.withLock {
                        precondition(session?.sessionID == requestedSessionID)
                        let cancelled = session!.state == .cancelling || !lifetime.isActive
                        let completed = session!.complete(succeeded: failure == nil)
                        precondition(completed)
                        session = nil
                        return cancelled
                    }
                    if cancelled {
                        reply(sessionID, Self.serviceInstanceID.uuidString, nil, nil, 0, false,
                              OmniXPCFailure.error(.cancelled, "The final session was cancelled."))
                    } else if let result {
                        reply(sessionID, Self.serviceInstanceID.uuidString, result.text, result.language,
                              result.generatedTokenCount, result.hitLengthLimit, nil)
                    } else {
                        reply(sessionID, Self.serviceInstanceID.uuidString, nil, nil, 0, false, failure)
                    }
                }
            }
        } catch {
            reply(nil, nil, nil, nil, 0, false, error as NSError)
        }
    }

    func cancel(requestID: String, modelID: String?, lifetime: OmniConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        let requestedModelID = try modelID.map(identifier)
        try lock.withLock {
            guard lifetime.isActive else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            if let requestedModelID {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard sessionIDs.contains(requestedID) else {
                    throw OmniXPCFailure.error(.invalidRequest, "The final session ID has not been registered on this model.")
                }
                guard session?.sessionID == requestedID else { return }
                cancelSession()
            } else if let operation = lifetime.operations[requestedID] {
                guard operation == .active else { return }
                lifetime.operations[requestedID] = .cancelled
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The request ID is stale or belongs to another connection.")
            }
        }
    }

    func disconnect(lifetime: OmniConnectionLifetime) {
        lock.withLock {
            guard lifetime.isActive else { return }
            lifetime.isActive = false
            guard owner?.id == lifetime.id else { return }
            cancelSession()
            queue.async { [self] in
                let loaded = lock.withLock { owner?.id == lifetime.id ? model : nil }
                loaded?.close()
                lock.withLock {
                    guard owner?.id == lifetime.id else { return }
                    clearModel()
                }
            }
        }
    }

    func reserveValidationTermination(lifetime: OmniConnectionLifetime) throws {
        try lock.withLock {
            guard lifetime.isActive, !validationTerminationPending else {
                throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.")
            }
            guard modelState == .unloaded, owner == nil, session == nil else {
                throw OmniXPCFailure.error(.busy, "Unload the model before using the diagnostic endpoint.")
            }
            validationTerminationPending = true
        }
    }

    private func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value) else {
            throw OmniXPCFailure.error(.invalidRequest, "Model, session and operation IDs must be UUIDs.")
        }
        return identifier
    }

    private func requireOwner(_ lifetime: OmniConnectionLifetime, modelID requestedModelID: UUID? = nil) throws {
        guard lifetime.isActive, owner?.id == lifetime.id,
              requestedModelID == nil || requestedModelID == modelID else {
            throw OmniXPCFailure.error(.invalidRequest, "The model ID is stale or belongs to another connection.")
        }
        guard modelState == .ready else {
            throw OmniXPCFailure.error(.busy, "The Native Qwen model is not ready.")
        }
    }

    private func cancelSession() {
        guard session?.cancel() == true else { return }
        model?.cancelRequest()
        guard session?.isTerminal == true else { return }
        session = nil
    }

    private func clearModel() {
        model = nil
        modelID = nil
        owner = nil
        session = nil
        sessionIDs.removeAll(keepingCapacity: false)
        modelState = .unloaded
    }
}
#endif
