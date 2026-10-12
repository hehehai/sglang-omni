import Foundation
import OmniXPCContracts

#if os(macOS)
extension OmniXPCClient {
    func pushSpeakerAudio(_ reference: OmniXPCSpeakerSessionReference, audio: Data,
                          timeout: Duration = .seconds(300)) async throws -> OmniXPCSpeakerAudioAcknowledgement {
        try Task.checkCancellation()
        let session = try requireSpeakerSession(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker timeout must be positive.") }
        guard session.phase == .accepting, !session.requesting else {
            throw OmniXPCFailure.error(.busy, "The speaker session cannot accept audio.")
        }
        let sampleCount = try OmniXPCRequestValidation.audioSamples(
            audio: audio, maximumSampleCount: OmniXPCSpeakerLimits.maximumChunkSampleCount
        ).count
        guard sampleCount <= OmniXPCSpeakerLimits.maximumSessionSampleCount - session.acceptedSampleCount,
              session.nextAudioSequence < UInt64.max else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker session exceeds its audio limit.")
        }
        let referenceBytes = try reference.encoded()
        let audioSequence = session.nextAudioSequence
        session.requesting = true
        defer { session.requesting = false }
        do {
            let acknowledgement: OmniXPCSpeakerAudioAcknowledgement = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID,
                nativeRequestID: reference.sessionID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .speaker
            ) { proxy, resolve in
                guard session.phase == .accepting, self.speakerModel?.closing == false else {
                    resolve(.failure(OmniXPCFailure.error(.cancelled, "The speaker session is closing.")))
                    return
                }
                proxy.pushSpeakerAudio(sessionReference: referenceBytes, audioSequence: audioSequence, audio: audio) { bytes, error in
                    do {
                        if let error { throw error } else { }
                        guard let bytes else {
                            throw OmniXPCFailure.error(.incompatibleService, "The service returned no speaker audio acknowledgement.")
                        }
                        let acknowledgement = try OmniXPCSpeakerAudioAcknowledgement.decode(bytes)
                        guard acknowledgement.session == reference, acknowledgement.audioSequence == audioSequence else {
                            throw OmniXPCFailure.error(.incompatibleService, "The speaker audio acknowledgement has the wrong scope or sequence.")
                        }
                        resolve(.success(acknowledgement))
                    } catch { resolve(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            _ = try requireSpeakerSession(reference)
            guard session.phase == .accepting else {
                throw OmniXPCFailure.error(.cancelled, "The speaker audio operation is closing.")
            }
            session.acceptedSampleCount += sampleCount
            session.nextAudioSequence += 1
            return acknowledgement
        } catch {
            if session.phase != .closed { session.phase = .cleanupRequired } else { }
            throw error
        }
    }

    func commitSpeakerSession(_ reference: OmniXPCSpeakerSessionReference, timeout: Duration = .seconds(300)) async throws {
        try await submitSpeakerBoundary(reference, finishing: false, timeout: timeout)
    }

    func finishSpeakerSession(_ reference: OmniXPCSpeakerSessionReference, timeout: Duration = .seconds(300)) async throws {
        try await submitSpeakerBoundary(reference, finishing: true, timeout: timeout)
    }

    private func submitSpeakerBoundary(_ reference: OmniXPCSpeakerSessionReference, finishing: Bool, timeout: Duration) async throws {
        try Task.checkCancellation()
        let session = try requireSpeakerSession(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker timeout must be positive.") }
        guard (session.phase == .accepting || (finishing && session.phase == .committed)), !session.requesting else {
            throw OmniXPCFailure.error(.busy, "The speaker session cannot accept a boundary command.")
        }
        let referenceBytes = try reference.encoded()
        session.requesting = true
        defer { session.requesting = false }
        do {
            let _: Void = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID,
                nativeRequestID: reference.sessionID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .speaker
            ) { proxy, resolve in
                guard (session.phase == .accepting || (finishing && session.phase == .committed)),
                      self.speakerModel?.closing == false else {
                    resolve(.failure(OmniXPCFailure.error(.cancelled, "The speaker session is closing.")))
                    return
                }
                let reply: @Sendable (NSError?) -> Void = { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
                if finishing {
                    proxy.finishSpeakerSession(sessionReference: referenceBytes, withReply: reply)
                } else {
                    proxy.commitSpeakerSession(sessionReference: referenceBytes, withReply: reply)
                }
            }
            try Task.checkCancellation()
            _ = try requireSpeakerSession(reference)
            guard session.phase == .accepting || (finishing && session.phase == .committed) else {
                throw OmniXPCFailure.error(.cancelled, "The speaker boundary operation is closing.")
            }
            if finishing { session.phase = .finishing }
            else if reference.model.kind == .nemotron { session.phase = .committed }
            else { }
        } catch {
            if session.phase != .closed { session.phase = .cleanupRequired } else { }
            throw error
        }
    }

    func cancelSpeakerSession(_ reference: OmniXPCSpeakerSessionReference, timeout: Duration = .seconds(60)) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker timeout must be positive.") }
        if closedSpeakerSessions[reference.sessionID] == reference { return } else { }
        let session = try requireSpeakerSession(reference)
        session.phase = .cleanupRequired
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: reference.model.connectionID, cancellationTarget: .speaker
        ) { proxy, resolve in
            proxy.cancelSpeakerRequest(requestID: reference.sessionID.uuidString, modelID: reference.model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
    }

    func pollSpeakerEvents(_ reference: OmniXPCSpeakerSessionReference,
                           maximumEventCount: Int = OmniXPCClient.maximumSpeakerPollEventCount,
                           timeout: Duration = .seconds(300)) async throws -> OmniXPCSpeakerBatch {
        try Task.checkCancellation()
        guard timeout > .zero, (1...Self.maximumSpeakerPollEventCount).contains(maximumEventCount) else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker polls require a positive timeout and one to sixteen events.")
        }
        if closedSpeakerSessions[reference.sessionID] == reference {
            return try OmniXPCSpeakerBatch(session: reference, events: [], isDrained: true)
        } else { }
        let session = try requireSpeakerSession(reference)
        guard session.phase != .starting, !session.requesting else {
            throw OmniXPCFailure.error(.busy, "The speaker session has an active command.")
        }
        let referenceBytes = try reference.encoded()
        let acknowledgedSequence = session.acknowledgedEventSequence
        let hasTerminalEvent = session.hasTerminalEvent
        let maximumBatchCount = Self.maximumSpeakerPollEventCount
        session.requesting = true
        defer { session.requesting = false }
        do {
            let batch: OmniXPCSpeakerBatch = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID,
                nativeRequestID: reference.sessionID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .speaker
            ) { proxy, resolve in
                guard session.phase != .closed, session.closeTask == nil, self.speakerModel?.closing == false else {
                    resolve(.failure(OmniXPCFailure.error(.cancelled, "The speaker session is closing.")))
                    return
                }
                proxy.pollSpeakerEvents(sessionReference: referenceBytes, acknowledgedEventSequence: acknowledgedSequence,
                                        maximumEventCount: maximumEventCount) { bytes, error in
                    do {
                        if let error { throw error } else { }
                        guard let bytes else {
                            throw OmniXPCFailure.error(.incompatibleService, "The service returned no speaker event batch.")
                        }
                        let batch = try OmniXPCSpeakerBatch.decode(bytes)
                        guard batch.session == reference, batch.events.count <= maximumBatchCount,
                              !hasTerminalEvent || batch.events.isEmpty else {
                            throw OmniXPCFailure.error(.incompatibleService, "The speaker event batch has an invalid scope or terminal history.")
                        }
                        var previousSequence = acknowledgedSequence
                        for event in batch.events {
                            guard previousSequence < UInt64.max, event.eventSequence == previousSequence + 1 else {
                                throw OmniXPCFailure.error(.incompatibleService, "The speaker event batch has a missing or replayed sequence.")
                            }
                            previousSequence = event.eventSequence
                        }
                        resolve(.success(batch))
                    } catch { resolve(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            _ = try requireSpeakerSession(reference)
            // note (assistant): Validate the entire delivery before acknowledging any event; ACK never releases native ownership.
            if let last = batch.events.last {
                session.acknowledgedEventSequence = last.eventSequence
                switch last.kind {
                case .completed, .cancelled, .failed:
                    session.hasTerminalEvent = true
                    if session.phase != .cleanupRequired { session.phase = .terminal } else { }
                case .updated, .segment:
                    break
                }
            } else { }
            return batch
        } catch {
            if session.phase != .closed { session.phase = .cleanupRequired } else { }
            throw error
        }
    }
}
#endif
