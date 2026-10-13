import Foundation
import OmniXPCContracts

@MainActor
final class OmniXPCSileroStreamState {
    let reference: OmniXPCSileroStreamReference
    var audioSequence = 0
    var receivedSampleCount: UInt64 = 0
    var processedSampleCount: UInt64 = 0
    var busy = true
    var closing = false
    var terminal = false
    var drained = false
    var closeTask: Task<Void, Error>?
    var cancelTask: Task<Void, Error>?

    init(reference: OmniXPCSileroStreamReference) { self.reference = reference }

    func requireReady() throws {
        guard !closing, !terminal else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream is terminal or closing.")
        }
        guard !busy else { throw OmniXPCFailure.error(.busy, "The Silero stream already has a pending command.") }
    }

    func admit(audio: Data, sequence: Int) throws -> UInt64 {
        try requireReady()
        guard audioSequence < Int.max, sequence == audioSequence + 1,
              !audio.isEmpty, audio.count % 4 == 0,
              audio.count <= OmniXPCSileroLimits.maximumChunkSampleCount * 4 else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero audio sequence or chunk size is invalid.")
        }
        let finite = audio.withUnsafeBytes { bytes in
            stride(from: 0, to: audio.count, by: 4).allSatisfy { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))).isFinite
            }
        }
        let (received, overflow) = receivedSampleCount.addingReportingOverflow(UInt64(audio.count / 4))
        guard finite, !overflow, received <= UInt64.max - UInt64(OmniXPCSileroLimits.frameSampleCount - 1) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero audio is nonfinite or its sample counter would overflow.")
        }
        busy = true
        return received
    }

    func accept(
        _ batch: OmniXPCSileroProbabilityBatch, sequence: Int, receivedSampleCount: UInt64, isFinal: Bool
    ) throws {
        let frameSampleCount = UInt64(OmniXPCSileroLimits.frameSampleCount)
        let (paddedSampleCount, overflow) = receivedSampleCount.addingReportingOverflow(isFinal ? frameSampleCount - 1 : 0)
        guard !overflow else { throw OmniXPCFailure.error(.incompatibleService, "The Silero frame counter overflowed.") }
        let expectedProcessedSampleCount = paddedSampleCount / frameSampleCount * frameSampleCount
        guard batch.serviceInstanceID == reference.model.serviceInstanceID,
              batch.modelID == reference.model.modelID, batch.streamID == reference.streamID,
              batch.audioSequence == sequence, batch.isFinal == isFinal,
              batch.processedSampleCount == expectedProcessedSampleCount,
              expectedProcessedSampleCount >= processedSampleCount,
              UInt64(batch.probabilities.count) == (expectedProcessedSampleCount - processedSampleCount) / frameSampleCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero reply identity, sequence or probability delta is invalid.")
        }
        guard !closing, !terminal else { throw CancellationError() }
        self.audioSequence = sequence
        self.receivedSampleCount = receivedSampleCount
        processedSampleCount = expectedProcessedSampleCount
        busy = false
        terminal = isFinal
    }
}

#if os(macOS)
// Note (Omni): only a remote pre-admission reply proves that this start acquired no lease.
private nonisolated struct OmniXPCSileroStartRejection: Error {
    let failure: NSError
}

extension OmniXPCClient {
    func startSileroStream(
        model: OmniXPCSileroModelReference, streamID: UUID = UUID(), timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCSileroStreamReference {
        try Task.checkCancellation()
        let modelState = try requireSileroModel(model)
        guard !modelState.closing, !modelState.unloading else {
            throw OmniXPCFailure.error(.busy, "The Silero model is retiring.")
        }
        guard timeout > .zero, sileroStreams[streamID] == nil,
              closedSileroStreams[streamID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream identity or timeout is invalid.")
        }
        guard sileroStreams.count < OmniXPCSileroLimits.maximumStreamCount else {
            throw OmniXPCFailure.error(.busy, "The client already owns sixteen Silero streams.")
        }
        let reference = OmniXPCSileroStreamReference(streamID: streamID, model: model)
        let state = OmniXPCSileroStreamState(reference: reference)
        sileroStreams[streamID] = state
        do {
            let _: Void = try await perform(
                timeout: timeout, requiredConnectionID: model.connectionID, nativeRequestID: streamID.uuidString,
                cancellationModelID: model.modelID.uuidString, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.startSileroStream(streamID: streamID.uuidString, modelID: model.modelID.uuidString) { reply, error in
                    if let error {
                        if error.domain == "Voxt.Omni.XPC",
                           error.code == OmniXPCFailure.Code.invalidRequest.rawValue || error.code == OmniXPCFailure.Code.busy.rawValue {
                            resolve(.failure(OmniXPCSileroStartRejection(failure: error)))
                        } else {
                            resolve(.failure(error))
                        }
                    } else if let reply, UUID(uuidString: reply) == streamID { resolve(.success(())) }
                    else { resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The Silero stream identity is invalid."))) }
                }
            }
            try Task.checkCancellation()
            guard !state.closing, !state.terminal else { throw CancellationError() }
            state.busy = false
            return reference
        } catch let rejection as OmniXPCSileroStartRejection {
            if connectionIdentifier == model.connectionID, sileroStreams[streamID] === state {
                sileroStreams.removeValue(forKey: streamID)
            }
            throw rejection.failure
        } catch {
            try await cleanUpSileroStream(state)
            throw error
        }
    }

    func pushSileroAudio(
        _ audio: Data, to reference: OmniXPCSileroStreamReference, sequence: Int, timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCSileroProbabilityBatch {
        try Task.checkCancellation()
        let state = try sileroStream(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        let receivedSampleCount = try state.admit(audio: audio, sequence: sequence)
        do {
            let batch: OmniXPCSileroProbabilityBatch = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, nativeRequestID: reference.streamID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.pushSileroAudio(
                    streamID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString,
                    sequence: sequence, audio: audio
                ) { reply, error in
                    resolve(Self.sileroProbabilityReply(reply, error: error))
                }
            }
            try Task.checkCancellation()
            try state.accept(batch, sequence: sequence, receivedSampleCount: receivedSampleCount, isFinal: false)
            return batch
        } catch {
            try await cleanUpSileroStream(state)
            throw error
        }
    }

    func finishSileroStream(
        _ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(60)
    ) async throws -> OmniXPCSileroProbabilityBatch {
        try Task.checkCancellation()
        let state = try sileroStream(reference)
        try state.requireReady()
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        state.busy = true
        do {
            let batch: OmniXPCSileroProbabilityBatch = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, nativeRequestID: reference.streamID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.finishSileroStream(streamID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString) { reply, error in
                    resolve(Self.sileroProbabilityReply(reply, error: error))
                }
            }
            try Task.checkCancellation()
            try state.accept(batch, sequence: state.audioSequence, receivedSampleCount: state.receivedSampleCount, isFinal: true)
            retireSileroStream(state)
            return batch
        } catch {
            try await cleanUpSileroStream(state)
            throw error
        }
    }

    /// Cancellation acknowledgement is not a native resource barrier; close must follow.
    func cancelSileroStream(
        _ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(30)
    ) async throws {
        let state = try sileroStream(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        state.terminal = true
        if let cancellation = state.cancelTask { return try await cancellation.value }
        let cancellation = Task { @MainActor in
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.cancelSileroRequest(requestID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
        }
        state.cancelTask = cancellation
        defer { state.cancelTask = nil }
        try await cancellation.value
    }

    /// Returns only after the service acknowledges native drain and destruction.
    func closeSileroStream(
        _ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(60)
    ) async throws {
        try requireConnection(reference.model.connectionID)
        if closedSileroStreams[reference.streamID] == reference { return }
        let state = try sileroStream(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        if let closing = state.closeTask { return try await closing.value }
        state.closing = true
        state.terminal = true
        let closing = Task { @MainActor in
            let cancellation = Task { @MainActor in try await self.cancelSileroStream(reference, timeout: timeout) }
            // Note (Omni): a successful close supersedes a failed cancellation ACK, but never a failed drain.
            _ = await cancellation.result
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.closeSileroStream(streamID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            self.retireSileroStream(state)
        }
        state.closeTask = closing
        defer { state.closeTask = nil }
        try await closing.value
    }

    private func sileroStream(_ reference: OmniXPCSileroStreamReference) throws -> OmniXPCSileroStreamState {
        try requireConnection(reference.model.connectionID)
        guard let state = sileroStreams[reference.streamID], state.reference == reference else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream does not belong to this client connection and model.")
        }
        return state
    }

    func retireSileroStream(_ state: OmniXPCSileroStreamState) {
        state.drained = true
        guard connectionIdentifier == state.reference.model.connectionID,
              sileroStreams[state.reference.streamID] === state else { return }
        sileroStreams.removeValue(forKey: state.reference.streamID)
        if closedSileroStreams.count == OmniXPCProtocolLimits.maximumRequestsPerModel,
           let retiredID = closedSileroStreams.keys.first {
            closedSileroStreams.removeValue(forKey: retiredID)
        }
        closedSileroStreams[state.reference.streamID] = state.reference
    }

    private func cleanUpSileroStream(_ state: OmniXPCSileroStreamState) async throws {
        if state.drained { return }
        state.busy = false
        state.terminal = true
        let cleanup = Task { @MainActor in try await self.closeSileroStream(state.reference) }
        try await cleanup.value
    }

    nonisolated private static func sileroProbabilityReply(
        _ reply: Data?, error: NSError?
    ) -> Result<OmniXPCSileroProbabilityBatch, Error> {
        do {
            if let error { throw error }
            guard let reply else { throw OmniXPCFailure.error(.incompatibleService, "The Silero probability reply is missing.") }
            return .success(try OmniXPCSileroProbabilityBatch.decode(reply))
        } catch {
            return .failure(error)
        }
    }
}
#endif
