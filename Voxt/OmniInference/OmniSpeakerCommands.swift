import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSpeakerInferenceEngine {
    enum Command: Sendable {
        case push(sequence: UInt64, samples: [Float])
        case commit, finish
    }

    func push(sessionReference: Data, audioSequence: UInt64, audio: Data, lifetime: ConnectionLifetime,
              reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        do {
            guard audioSequence > 0 else { throw SpeakerCoreModel.error(.invalid) }
            let samples = try OmniXPCRequestValidation.audioSamples(
                audio: audio, maximumSampleCount: OmniXPCSpeakerLimits.maximumChunkSampleCount
            )
            submitCommand(.push(sequence: audioSequence, samples: samples), sessionReference: sessionReference,
                          lifetime: lifetime, reply: reply)
        } catch { reply(nil, error as NSError) }
    }

    func commit(sessionReference: Data, lifetime: ConnectionLifetime, reply: @escaping @Sendable (NSError?) -> Void) {
        submitCommand(.commit, sessionReference: sessionReference, lifetime: lifetime) { _, failure in reply(failure) }
    }

    func finish(sessionReference: Data, lifetime: ConnectionLifetime, reply: @escaping @Sendable (NSError?) -> Void) {
        submitCommand(.finish, sessionReference: sessionReference, lifetime: lifetime) { _, failure in reply(failure) }
    }

    private func submitCommand(_ command: Command, sessionReference: Data, lifetime: ConnectionLifetime,
                               reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        do {
            let reference = try OmniXPCSpeakerSessionReference.decode(sessionReference)
            try lock.withLock {
                let record = try requireLiveSession(lifetime, reference: reference)
                guard record.isStarted, !record.commandPending, let stream = record.stream else {
                    throw SpeakerCoreModel.error(.busy)
                }
                record.commandPending = true
                queue.async { [self] in
                    do {
                        _ = try lock.withLock { try requireLiveSession(lifetime, reference: reference) }
                        let encoded: Data?
                        switch command {
                        case let .push(sequence, samples):
                            let acceptedSequence = try stream.push(audioSequence: sequence, samples: samples)
                            encoded = try OmniXPCSpeakerAudioAcknowledgement(
                                session: reference, audioSequence: acceptedSequence
                            ).encoded()
                        case .commit:
                            try stream.commit()
                            encoded = nil
                        case .finish:
                            try stream.finish()
                            encoded = nil
                        }
                        try lock.withLock {
                            record.commandPending = false
                            _ = try requireLiveSession(lifetime, reference: reference)
                        }
                        reply(encoded, nil)
                    } catch {
                        lock.withLock { record.commandPending = false }
                        reply(nil, error as NSError)
                    }
                }
            }
        } catch { reply(nil, error as NSError) }
    }

    func cancel(requestID: String, modelID: String?, lifetime: ConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        if let modelID {
            let requestedModelID = try identifier(modelID)
            let stream = try lock.withLock { () throws -> SpeakerCoreStream? in
                guard lifetime.isActive, let record = lifetime.sessions[requestedID],
                      record.reference.model.modelID == requestedModelID else { throw SpeakerCoreModel.error(.invalid) }
                if record.isClosed { return nil }
                try requireOwner(lifetime, reference: record.reference.model)
                record.isCancelled = true
                return record.stream
            }
            stream?.cancel()
        } else {
            let shouldCleanup = try lock.withLock { () throws -> Bool in
                guard lifetime.isActive else { throw SpeakerCoreModel.error(.cancelled) }
                if lifetime.loads[requestedID] == .closed { return false }
                guard owner === lifetime, loadOperationID == requestedID else { throw SpeakerCoreModel.error(.invalid) }
                modelState = .closing
                session?.isClosing = true
                return true
            }
            if shouldCleanup { scheduleCleanup(lifetime: lifetime, operation: requestedID) }
        }
    }

    func disconnect(lifetime: ConnectionLifetime) {
        let operation = lock.withLock { () -> UUID? in
            lifetime.isActive = false
            guard owner === lifetime else { return nil }
            modelState = .closing
            session?.isClosing = true
            return loadOperationID
        }
        if let operation { scheduleCleanup(lifetime: lifetime, operation: operation) }
    }
}
#endif
