import Foundation
import OmniXPCContracts

/// A caller-retained start receipt survives connection-map eviction without inferring native drain.
nonisolated final class OmniXPCSortformerStartOwnership: @unchecked Sendable {
    enum Status: Sendable { case notSubmitted, submitted, drained }

    let reference: OmniXPCSortformerStreamReference
    private let lock = NSLock()
    private var currentStatus = Status.notSubmitted
    private var claimed = false

    init(model: OmniXPCSortformerModelReference, streamID: UUID = UUID()) {
        reference = OmniXPCSortformerStreamReference(streamID: streamID, model: model)
    }

    var status: Status { lock.withLock { currentStatus } }

    fileprivate func claim(model: OmniXPCSortformerModelReference) throws {
        try lock.withLock {
            guard !claimed, reference.model == model else {
                throw OmniXPCFailure.error(.invalidRequest, "The Sortformer start ticket is already used or belongs to another model.")
            }
            claimed = true
        }
    }

    fileprivate func submitted() { lock.withLock { currentStatus = .submitted } }
    fileprivate func drained() { lock.withLock { currentStatus = .drained } }
}

@MainActor
final class OmniXPCSortformerStreamState {
    let reference: OmniXPCSortformerStreamReference
    let ownership: OmniXPCSortformerStartOwnership?
    var audioSequence = 0
    var processedFrameCount: UInt64 = 0
    var busy = true
    var closing = false
    var terminal = false
    var drained = false
    var closeTask: Task<Void, Error>?
    var cancelTask: Task<Void, Error>?
    private var pendingFrameCount: Int?

    init(reference: OmniXPCSortformerStreamReference, ownership: OmniXPCSortformerStartOwnership? = nil) {
        self.reference = reference
        self.ownership = ownership
    }

    func requireReady() throws {
        guard !closing, !terminal else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream is terminal or closing.")
        }
        guard !busy else { throw OmniXPCFailure.error(.busy, "The Sortformer stream already has a pending command.") }
    }

    func admit(audio: Data, sequence: Int) throws {
        try requireReady()
        let sampleByteCount = MemoryLayout<UInt32>.size
        guard audioSequence < Int.max, sequence == audioSequence + 1,
              !audio.isEmpty, audio.count % sampleByteCount == 0,
              audio.count <= OmniXPCSortformerLimits.maximumChunkSampleCount * sampleByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer audio sequence or chunk size is invalid.")
        }
        let finite = audio.withUnsafeBytes { bytes in
            stride(from: 0, to: audio.count, by: sampleByteCount).allSatisfy { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))).isFinite
            }
        }
        let featureFrameCount = 1 + audio.count / sampleByteCount / OmniXPCSortformerLimits.featureHopSampleCount
        let subsamplingFactor = OmniXPCSortformerLimits.subsamplingFactor
        let frameCount = (featureFrameCount + subsamplingFactor - 1) / subsamplingFactor
        let (nextFrameCount, overflow) = processedFrameCount.addingReportingOverflow(UInt64(frameCount))
        guard finite, !overflow, nextFrameCount <= OmniXPCSortformerLimits.maximumProcessedFrameCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer audio is nonfinite or its frame counter would overflow.")
        }
        pendingFrameCount = frameCount
        busy = true
    }

    func accept(_ batch: OmniXPCSortformerProbabilityBatch, sequence: Int) throws {
        guard let frameCount = pendingFrameCount, busy,
              audioSequence < Int.max, sequence == audioSequence + 1 else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer reply has no matching admitted audio.")
        }
        let (nextFrameCount, overflow) = processedFrameCount.addingReportingOverflow(UInt64(frameCount))
        guard !overflow, nextFrameCount <= OmniXPCSortformerLimits.maximumProcessedFrameCount,
              batch.serviceInstanceID == reference.model.serviceInstanceID,
              batch.modelID == reference.model.modelID, batch.streamID == reference.streamID,
              batch.audioSequence == sequence, batch.frameCount == frameCount,
              batch.processedFrameCount == nextFrameCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer reply identity, sequence or frame progression is invalid.")
        }
        guard !closing, !terminal else { throw CancellationError() }
        audioSequence = sequence
        processedFrameCount = nextFrameCount
        pendingFrameCount = nil
        busy = false
    }
}

#if os(macOS)
// Note (Omni): only a remote pre-admission reply proves that this start acquired no lease.
private nonisolated struct OmniXPCSortformerStartRejection: Error {
    let failure: NSError
}

extension OmniXPCClient {
    func startSortformerStream(
        model: OmniXPCSortformerModelReference, settings: OmniXPCSortformerSettings,
        streamID: UUID = UUID(), timeout: Duration = .seconds(30),
        ownership: OmniXPCSortformerStartOwnership? = nil
    ) async throws -> OmniXPCSortformerStreamReference {
        let ownership = ownership ?? OmniXPCSortformerStartOwnership(model: model, streamID: streamID)
        try ownership.claim(model: model)
        let streamID = ownership.reference.streamID
        try Task.checkCancellation()
        let modelState = try requireSortformerModel(model)
        guard !modelState.closing, !modelState.unloading else {
            throw OmniXPCFailure.error(.busy, "The Sortformer model is retiring.")
        }
        let encodedSettings = try settings.encoded()
        guard timeout > .zero, sortformerStreams[streamID] == nil,
              closedSortformerStreams[streamID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream identity or timeout is invalid.")
        }
        guard sortformerStreams.count < OmniXPCSortformerLimits.maximumStreamCount else {
            throw OmniXPCFailure.error(.busy, "The client already owns sixteen Sortformer streams.")
        }
        let reference = OmniXPCSortformerStreamReference(streamID: streamID, model: model)
        let state = OmniXPCSortformerStreamState(reference: reference, ownership: ownership)
        sortformerStreams[streamID] = state
        do {
            let _: Void = try await perform(
                timeout: timeout, requiredConnectionID: model.connectionID, nativeRequestID: streamID.uuidString,
                cancellationModelID: model.modelID.uuidString, cancellationTarget: .sortformer
            ) { proxy, resolve in
                ownership.submitted()
                proxy.startSortformerStream(
                    streamID: streamID.uuidString, modelID: model.modelID.uuidString, settings: encodedSettings
                ) { reply, error in
                    if let error {
                        if error.domain == "Voxt.Omni.XPC",
                           error.code == OmniXPCFailure.Code.invalidRequest.rawValue || error.code == OmniXPCFailure.Code.busy.rawValue {
                            ownership.drained()
                            resolve(.failure(OmniXPCSortformerStartRejection(failure: error)))
                        } else {
                            resolve(.failure(error))
                        }
                    } else if let reply, UUID(uuidString: reply) == streamID { resolve(.success(())) }
                    else { resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The Sortformer stream identity is invalid."))) }
                }
            }
            try Task.checkCancellation()
            try requireConnection(model.connectionID)
            guard !state.closing, !state.terminal else { throw CancellationError() }
            state.busy = false
            return reference
        } catch let rejection as OmniXPCSortformerStartRejection {
            if connectionIdentifier == model.connectionID, sortformerStreams[streamID] === state {
                sortformerStreams.removeValue(forKey: streamID)
            }
            throw rejection.failure
        } catch {
            if ownership.status == .submitted {
                try await cleanUpSortformerStream(state)
            } else if sortformerStreams[streamID] === state {
                sortformerStreams.removeValue(forKey: streamID)
            }
            throw error
        }
    }

    func pushSortformerAudio(
        _ audio: Data, to reference: OmniXPCSortformerStreamReference, sequence: Int, timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCSortformerProbabilityBatch {
        try Task.checkCancellation()
        let state = try sortformerStream(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        try state.admit(audio: audio, sequence: sequence)
        do {
            let batch: OmniXPCSortformerProbabilityBatch = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, nativeRequestID: reference.streamID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .sortformer
            ) { proxy, resolve in
                proxy.pushSortformerAudio(
                    streamID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString,
                    sequence: sequence, audio: audio
                ) { reply, error in
                    do {
                        if let error { throw error }
                        guard let reply else {
                            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability reply is missing.")
                        }
                        resolve(.success(try OmniXPCSortformerProbabilityBatch.decode(reply)))
                    } catch { resolve(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            try requireConnection(reference.model.connectionID)
            try state.accept(batch, sequence: sequence)
            return batch
        } catch {
            try await cleanUpSortformerStream(state)
            throw error
        }
    }

    func finishSortformerStream(
        _ reference: OmniXPCSortformerStreamReference, timeout: Duration = .seconds(60)
    ) async throws {
        try Task.checkCancellation()
        try requireConnection(reference.model.connectionID)
        if closedSortformerStreams[reference.streamID] == reference { return }
        let state = try sortformerStream(reference)
        try state.requireReady()
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        state.busy = true
        do {
            let _: Void = try await perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, nativeRequestID: reference.streamID.uuidString,
                cancellationModelID: reference.model.modelID.uuidString, cancellationTarget: .sortformer
            ) { proxy, resolve in
                proxy.finishSortformerStream(streamID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            try requireConnection(reference.model.connectionID)
            retireSortformerStream(state)
            try Task.checkCancellation()
        } catch {
            try await cleanUpSortformerStream(state)
            throw error
        }
    }

    /// Cancellation acknowledgement is not a native resource barrier; close must follow.
    func cancelSortformerStream(
        _ reference: OmniXPCSortformerStreamReference, timeout: Duration = .seconds(30)
    ) async throws {
        let state = try sortformerStream(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        state.terminal = true
        if let cancellation = state.cancelTask { return try await cancellation.value }
        let cancellation = Task { @MainActor in
            defer { state.cancelTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, cancellationTarget: .sortformer
            ) { proxy, resolve in
                proxy.cancelSortformerRequest(requestID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
        }
        state.cancelTask = cancellation
        try await cancellation.value
    }

    /// Returns only after the service acknowledges native drain and destruction.
    func closeSortformerStream(
        _ reference: OmniXPCSortformerStreamReference, timeout: Duration = .seconds(60)
    ) async throws {
        try requireConnection(reference.model.connectionID)
        if closedSortformerStreams[reference.streamID] == reference { return }
        let state = try sortformerStream(reference)
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The timeout must be positive.") }
        if let closing = state.closeTask { return try await closing.value }
        state.closing = true
        state.terminal = true
        let closing = Task { @MainActor in
            defer { state.closeTask = nil }
            let cancellation = Task { @MainActor in try await self.cancelSortformerStream(reference, timeout: timeout) }
            // Note (Omni): a successful close supersedes a failed cancellation ACK, but never a failed drain.
            _ = await cancellation.result
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: reference.model.connectionID, cancellationTarget: .sortformer
            ) { proxy, resolve in
                proxy.closeSortformerStream(streamID: reference.streamID.uuidString, modelID: reference.model.modelID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            try self.requireConnection(reference.model.connectionID)
            self.retireSortformerStream(state)
        }
        state.closeTask = closing
        try await closing.value
    }

    private func sortformerStream(_ reference: OmniXPCSortformerStreamReference) throws -> OmniXPCSortformerStreamState {
        try requireConnection(reference.model.connectionID)
        guard let state = sortformerStreams[reference.streamID], state.reference == reference else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream does not belong to this client connection and model.")
        }
        return state
    }

    func retireSortformerStream(_ state: OmniXPCSortformerStreamState) {
        state.ownership?.drained()
        state.drained = true
        state.terminal = true
        state.busy = false
        guard connectionIdentifier == state.reference.model.connectionID,
              sortformerStreams[state.reference.streamID] === state else { return }
        sortformerStreams.removeValue(forKey: state.reference.streamID)
        if closedSortformerStreams.count == OmniXPCProtocolLimits.maximumRequestsPerModel,
           let retiredID = closedSortformerStreams.keys.first {
            closedSortformerStreams.removeValue(forKey: retiredID)
        }
        closedSortformerStreams[state.reference.streamID] = state.reference
    }

    private func cleanUpSortformerStream(_ state: OmniXPCSortformerStreamState) async throws {
        if state.drained { return }
        state.busy = false
        state.terminal = true
        let cleanup = Task { @MainActor in try await self.closeSortformerStream(state.reference) }
        try await cleanup.value
    }
}
#endif
