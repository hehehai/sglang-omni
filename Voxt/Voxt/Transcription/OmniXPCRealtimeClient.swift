/// Connection-scoped, non-replaying realtime RPCs for the validation client.
import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCRealtimeClientState {
    let reference: OmniXPCRealtimeSessionReference
    var nextAudioSequence = 1
    var admittedSampleCount = 0
    var acknowledgedEventSequence = 0
    var pendingBatch: OmniXPCRealtimeBatch?
    var maximumEventCount = 0
    var isOperationInFlight = false
    var isFinished = false
    var isClosing = false
    var isDrained = false

    init(reference: OmniXPCRealtimeSessionReference) { self.reference = reference }
}

extension OmniXPCClient {
    func startRealtimeSession(
        model: OmniXPCModelReference, language: String?, context: String? = nil,
        maximumTokenCount: Int, settings: OmniXPCRealtimeSettings,
        sessionID: UUID = UUID(), timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCRealtimeSessionReference {
        try requireConnection(model.connectionID)
        try OmniXPCRequestValidation.realtimeOptions(language: language, context: context, maximumTokenCount: maximumTokenCount)
        guard realtimeSession == nil || realtimeSession?.isDrained == true else {
            throw OmniXPCFailure.error(.busy, "A realtime session still owns this connection's lease.")
        }
        let reference = OmniXPCRealtimeSessionReference(
            sessionID: sessionID, model: model, language: language, maximumTokenCount: maximumTokenCount
        )
        let state = OmniXPCRealtimeClientState(reference: reference)
        state.isOperationInFlight = true
        realtimeSession = state
        do {
            let _: Void = try await perform(
                timeout: timeout, requiredConnectionID: model.connectionID,
                nativeRequestID: sessionID.uuidString, cancellationModelID: model.modelID.uuidString
            ) { proxy, resolve in
                proxy.startRealtimeSession(
                    sessionID: sessionID.uuidString, modelID: model.modelID.uuidString,
                    language: language, context: context, maximumTokenCount: maximumTokenCount,
                    decodeIntervalSamples: settings.decodeIntervalSamples, firstDecodeSamples: settings.firstDecodeSamples,
                    maximumSegmentSamples: settings.maximumSegmentSamples
                ) { instanceID, error in
                    if let error { resolve(.failure(error)) }
                    else if let instanceID, UUID(uuidString: instanceID) == model.serviceInstanceID {
                        resolve(.success(()))
                    } else {
                        resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The realtime service identity is invalid.")))
                    }
                }
            }
            try requireRealtimeState(state)
            state.isOperationInFlight = false
            return reference
        } catch {
            let cleanup = Task { @MainActor in
                try await self.closeRealtimeSession(reference)
            }
            _ = await cleanup.result
            if realtimeSession === state { realtimeSession = nil }
            throw error
        }
    }

    func pushRealtimeAudio(
        _ audio: Data, to session: OmniXPCRealtimeSessionReference, sequence: Int,
        timeout: Duration = .seconds(30)
    ) async throws {
        let state = try beginRealtimeOperation(session)
        defer { state.isOperationInFlight = false }
        guard !state.isFinished, state.pendingBatch?.events.last.map({ Self.isRealtimeTerminal($0.kind) }) != true,
              sequence == state.nextAudioSequence, sequence > 0, sequence < Int.max,
              audio.count <= OmniXPCProtocolLimits.maximumChunkAudioByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime audio sequence, phase or chunk size is invalid.")
        }
        let samples = try OmniXPCRequestValidation.samples(
            audio: audio, language: session.language, context: nil, maximumTokenCount: session.maximumTokenCount
        )
        guard samples.count <= OmniXPCProtocolLimits.maximumSampleCount - state.admittedSampleCount else {
            throw OmniXPCFailure.error(.invalidRequest, "Realtime validation accepts at most 30 seconds of input per session.")
        }
        let accepted: Int = try await perform(
            timeout: timeout, requiredConnectionID: session.model.connectionID,
            nativeRequestID: session.sessionID.uuidString, cancellationModelID: session.model.modelID.uuidString
        ) { proxy, resolve in
            proxy.pushRealtimeAudio(
                sessionID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString,
                sequence: sequence, audio: audio
            ) { accepted, error in
                if let error { resolve(.failure(error)) } else { resolve(.success(accepted)) }
            }
        }
        try requireRealtimeState(state)
        guard accepted == sequence else {
            throw OmniXPCFailure.error(.incompatibleService, "The service acknowledged a different realtime audio sequence.")
        }
        state.nextAudioSequence += 1
        state.admittedSampleCount += samples.count
    }

    func finishRealtimeSession(
        _ session: OmniXPCRealtimeSessionReference, timeout: Duration = .seconds(240)
    ) async throws {
        let state = try beginRealtimeOperation(session)
        defer { state.isOperationInFlight = false }
        guard !state.isFinished else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime input was already finished.")
        }
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: session.model.connectionID,
            nativeRequestID: session.sessionID.uuidString, cancellationModelID: session.model.modelID.uuidString
        ) { proxy, resolve in
            proxy.finishRealtimeSession(sessionID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
        try requireRealtimeState(state)
        state.isFinished = true
    }

    func pollRealtimeEvents(
        _ session: OmniXPCRealtimeSessionReference, acknowledgedEventSequence: Int,
        maximumEventCount: Int = OmniXPCProtocolLimits.maximumRealtimeEventsPerBatch,
        timeout: Duration = .seconds(60)
    ) async throws -> OmniXPCRealtimeBatch {
        let state = try beginRealtimeOperation(session)
        defer { state.isOperationInFlight = false }
        let previous = state.pendingBatch
        let deliveredSequence = previous?.events.last?.sequence ?? state.acknowledgedEventSequence
        let isReplay = previous != nil && acknowledgedEventSequence == state.acknowledgedEventSequence
        guard maximumEventCount > 0, maximumEventCount <= OmniXPCProtocolLimits.maximumRealtimeEventsPerBatch,
              acknowledgedEventSequence == deliveredSequence || isReplay,
              !isReplay || maximumEventCount == state.maximumEventCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime event ACK or replay batch size is invalid.")
        }
        let encoded: Data = try await perform(
            timeout: timeout, requiredConnectionID: session.model.connectionID,
            nativeRequestID: session.sessionID.uuidString, cancellationModelID: session.model.modelID.uuidString
        ) { proxy, resolve in
            proxy.pollRealtimeEvents(
                sessionID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString,
                acknowledgedEventSequence: acknowledgedEventSequence, maximumEventCount: maximumEventCount
            ) { encoded, error in
                if let error { resolve(.failure(error)) }
                else if let encoded { resolve(.success(encoded)) }
                else { resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The realtime event batch is missing."))) }
            }
        }
        try requireRealtimeState(state)
        let batch = try OmniXPCRealtimeCodec.decode(encoded)
        guard batch.sessionID == session.sessionID, batch.modelID == session.model.modelID,
              batch.serviceInstanceID == session.model.serviceInstanceID,
              batch.events.count <= maximumEventCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The realtime batch identity or event count is invalid.")
        }
        if isReplay {
            guard batch == previous else {
                throw OmniXPCFailure.error(.incompatibleService, "The service changed an unacknowledged realtime batch.")
            }
        } else {
            let acknowledgedTerminal = previous?.events.last.map { Self.isRealtimeTerminal($0.kind) } == true
            guard batch.isDrained == acknowledgedTerminal,
                  batch.events.first.map({ acknowledgedEventSequence < Int.max && $0.sequence == acknowledgedEventSequence + 1 }) ?? true else {
                throw OmniXPCFailure.error(.incompatibleService, "The realtime event sequence or drain ACK is invalid.")
            }
            state.acknowledgedEventSequence = acknowledgedEventSequence
            state.pendingBatch = batch.events.isEmpty ? nil : batch
            state.maximumEventCount = maximumEventCount
            state.isDrained = batch.isDrained
        }
        return batch
    }

    func closeRealtimeSession(
        _ session: OmniXPCRealtimeSessionReference, timeout: Duration = .seconds(60)
    ) async throws {
        try requireConnection(session.model.connectionID)
        let state = realtimeSession
        if state?.reference == session { state?.isClosing = true }
        let _: Void = try await perform(timeout: timeout, requiredConnectionID: session.model.connectionID) { proxy, resolve in
            proxy.closeRealtimeSession(sessionID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
        try requireConnection(session.model.connectionID)
        if realtimeSession === state, state?.reference == session { realtimeSession = nil }
    }

    private func beginRealtimeOperation(_ session: OmniXPCRealtimeSessionReference) throws -> OmniXPCRealtimeClientState {
        guard let state = realtimeSession, state.reference == session else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime session reference is stale.")
        }
        try requireRealtimeState(state)
        guard !state.isOperationInFlight, !state.isDrained else {
            throw OmniXPCFailure.error(.busy, "The realtime session is draining or has an operation in flight.")
        }
        state.isOperationInFlight = true
        return state
    }

    private func requireRealtimeState(_ state: OmniXPCRealtimeClientState) throws {
        try requireConnection(state.reference.model.connectionID)
        guard realtimeSession === state, !state.isClosing else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime lease has been closed or replaced.")
        }
    }

    private static func isRealtimeTerminal(_ kind: OmniXPCRealtimeEventKind) -> Bool {
        switch kind {
        case .completed, .cancelled, .failed: return true
        case .updated, .segment: return false
        }
    }
}
#endif
