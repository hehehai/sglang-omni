import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCSpeakerSessionState {
    enum Phase { case starting, accepting, committed, finishing, terminal, cleanupRequired, closed }

    let reference: OmniXPCSpeakerSessionReference
    var phase: Phase = .starting
    var requesting = false
    var nextAudioSequence: UInt64 = 1
    var acceptedSampleCount = 0
    var acknowledgedEventSequence: UInt64 = 0
    var hasTerminalEvent = false
    var closeTask: Task<Void, Error>?

    init(reference: OmniXPCSpeakerSessionReference) {
        self.reference = reference
    }
}

extension OmniXPCClient {
    func startSpeakerSession(_ model: OmniXPCSpeakerModelReference, settings: OmniXPCSpeakerSettings,
                             sessionID: UUID = UUID(), timeout: Duration = .seconds(300),
                             cleanupTimeout: Duration = .seconds(60)) async throws -> OmniXPCSpeakerSessionReference {
        try Task.checkCancellation()
        let state = try requireSpeakerModel(model)
        guard !state.closing, !state.isLoading, state.session == nil else {
            throw OmniXPCFailure.error(.busy, "Retire the previous speaker session before starting another.")
        }
        guard timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker timeouts must be positive.")
        }
        try requireUnusedSpeakerIdentity(sessionID)
        guard speakerSessionIDs.count < Self.maximumSpeakerScopeCount else {
            throw OmniXPCFailure.error(.busy, "The speaker session history is full.")
        }
        try settings.validate(for: model)
        let settingsBytes = try settings.encoded()
        let modelBytes = try model.encoded()
        let expected = try OmniXPCSpeakerSessionReference(sessionID: sessionID, model: model)
        let session = OmniXPCSpeakerSessionState(reference: expected)
        speakerSessionIDs.insert(sessionID)
        state.session = session
        session.requesting = true
        defer { session.requesting = false }
        do {
            let reference: OmniXPCSpeakerSessionReference = try await perform(
                timeout: timeout, requiredConnectionID: model.connectionID,
                nativeRequestID: sessionID.uuidString, cancellationModelID: model.modelID.uuidString, cancellationTarget: .speaker
            ) { proxy, resolve in
                guard !state.closing, state.session === session, session.phase == .starting else {
                    resolve(.failure(OmniXPCFailure.error(.cancelled, "The speaker session was closed before submission.")))
                    return
                }
                proxy.startSpeakerSession(sessionID: sessionID.uuidString, modelReference: modelBytes, settings: settingsBytes) { bytes, error in
                    do {
                        if let error { throw error } else { }
                        guard let bytes else {
                            throw OmniXPCFailure.error(.incompatibleService, "The service returned no speaker session reference.")
                        }
                        let reference = try OmniXPCSpeakerSessionReference.decode(bytes)
                        guard reference == expected else {
                            throw OmniXPCFailure.error(.incompatibleService, "The speaker session reference does not match its start.")
                        }
                        resolve(.success(reference))
                    } catch { resolve(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            guard !state.closing, state.session === session, session.phase == .starting else {
                throw OmniXPCFailure.error(.cancelled, "The speaker session is closing.")
            }
            session.phase = .accepting
            return reference
        } catch {
            try await closeSpeakerSessionScope(session, model: state, timeout: cleanupTimeout)
            throw error
        }
    }

    func requireSpeakerSession(_ reference: OmniXPCSpeakerSessionReference) throws -> OmniXPCSpeakerSessionState {
        let model = try requireSpeakerModel(reference.model)
        guard !model.closing, let session = model.session, session.reference == reference,
              session.phase != .closed, session.closeTask == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker session is not live on its original model.")
        }
        return session
    }

    func closeSpeakerSession(_ reference: OmniXPCSpeakerSessionReference, timeout: Duration = .seconds(60)) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if closedSpeakerSessions[reference.sessionID] == reference { return } else { }
        guard let model = speakerModel, model.reference == reference.model,
              let session = model.session, session.reference == reference else {
            throw OmniXPCFailure.error(.invalidRequest, "There is no matching speaker session claim to close.")
        }
        try await closeSpeakerSessionScope(session, model: model, timeout: timeout)
    }

    func closeSpeakerSessionScope(_ session: OmniXPCSpeakerSessionState, model: OmniXPCSpeakerLoadState,
                                  timeout: Duration) async throws {
        if session.phase == .closed { return } else if let closing = session.closeTask {
            return try await closing.value
        } else if let closing = model.closeTask {
            return try await closing.value
        } else { }
        session.phase = .cleanupRequired
        let reference = session.reference
        guard connectionIdentifier == model.connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The original speaker transport is unavailable; cleanup is not confirmed.")
        }
        let referenceBytes = try reference.encoded()
        let closing = Task { @MainActor in
            defer { session.closeTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, cancellationTarget: .speaker
            ) { proxy, resolve in
                proxy.closeSpeakerSession(sessionReference: referenceBytes) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            self.retireSpeakerSession(session, model: model)
        }
        session.closeTask = closing
        try await closing.value
    }

    func retireSpeakerSession(_ session: OmniXPCSpeakerSessionState, model: OmniXPCSpeakerLoadState) {
        session.phase = .closed
        closedSpeakerSessions[session.reference.sessionID] = session.reference
        if model.session === session { model.session = nil } else { }
    }
}
#endif
