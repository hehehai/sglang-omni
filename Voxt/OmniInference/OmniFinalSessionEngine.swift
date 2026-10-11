/// Buffered final inference on the shared model's serial command queue.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniFinalSessionEngine {
    func start(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        lifetime: OmniConnectionLifetime
    ) throws {
        let requestedSessionID = try identifier(sessionID)
        let requestedModelID = try identifier(modelID)
        try lock.withLock {
            try requireSessionAdmission(requestedSessionID, modelID: requestedModelID, lifetime: lifetime)
            session = try OmniXPCFinalSessionBuffer(
                sessionID: requestedSessionID, modelID: requestedModelID,
                language: language, context: context, maximumTokenCount: maximumTokenCount
            )
            isFinalFinishPending = false
            reservedFinalAudioByteCount = 0
            sessionIDs.insert(requestedSessionID)
        }
    }

    func push(
        sessionID: String, modelID: String, sequence: Int, audio: Data, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (Int, NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard session?.sessionID == requestedSessionID, !isFinalFinishPending,
                      !audio.isEmpty, audio.count <= OmniXPCProtocolLimits.maximumChunkAudioByteCount,
                      audio.count <= OmniXPCProtocolLimits.maximumAudioByteCount - reservedFinalAudioByteCount else {
                    throw OmniXPCFailure.error(.invalidRequest, "The final session is stale or exceeds its audio budget.")
                }
                reservedFinalAudioByteCount += audio.count
                queue.async { [self] in
                    do {
                        let acceptedSequence = try lock.withLock {
                            try requireOwner(lifetime, modelID: requestedModelID)
                            guard session?.sessionID == requestedSessionID else {
                                throw OmniXPCFailure.error(.invalidRequest, "The final session is no longer receiving audio.")
                            }
                            return try session!.append(audio: audio, sequence: sequence)
                        }
                        reply(acceptedSequence, nil)
                    } catch {
                        lock.withLock {
                            if session?.sessionID == requestedSessionID { reservedFinalAudioByteCount -= audio.count }
                        }
                        reply(0, error as NSError)
                    }
                }
            }
        } catch {
            reply(0, error as NSError)
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
                guard session?.sessionID == requestedSessionID, !isFinalFinishPending else {
                    throw OmniXPCFailure.error(.invalidRequest, "The final session is stale or has already finished.")
                }
                isFinalFinishPending = true
                queue.async { [self] in
                    do {
                        let (samples, finishingSession, loaded) = try lock.withLock {
                            precondition(session?.sessionID == requestedSessionID)
                            guard lifetime.isActive, session!.state != .cancelled else {
                                session = nil
                                isFinalFinishPending = false
                                throw OmniXPCFailure.error(.cancelled, "The final session was cancelled.")
                            }
                            do {
                                try requireOwner(lifetime, modelID: requestedModelID)
                                let samples = try session!.beginFinish()
                                return (samples, session!, model!)
                            } catch {
                                isFinalFinishPending = false
                                throw error
                            }
                        }
                        var result: QwenReply?
                        var failure: NSError?
                        do {
                            try loaded.prepareRequest(sessionID: requestedSessionID)
                            let cancelled = lock.withLock { session?.state == .cancelling || !lifetime.isActive }
                            if cancelled { loaded.cancelRequest(sessionID: requestedSessionID) }
                            result = try loaded.transcribe(
                                samples: samples, language: finishingSession.language, context: finishingSession.context,
                                maximumTokenCount: finishingSession.maximumTokenCount
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
                            isFinalFinishPending = false
                            return cancelled
                        }
                        if cancelled {
                            reply(sessionID, OmniServiceIdentity.instanceID.uuidString, nil, nil, 0, false,
                                  OmniXPCFailure.error(.cancelled, "The final session was cancelled."))
                        } else if let result {
                            reply(sessionID, OmniServiceIdentity.instanceID.uuidString, result.text, result.language,
                                  result.generatedTokenCount, result.hitLengthLimit, nil)
                        } else {
                            reply(sessionID, OmniServiceIdentity.instanceID.uuidString, nil, nil, 0, false, failure)
                        }
                    } catch {
                        reply(nil, nil, nil, nil, 0, false, error as NSError)
                    }
                }
            }
        } catch {
            reply(nil, nil, nil, nil, 0, false, error as NSError)
        }
    }
}
#endif
