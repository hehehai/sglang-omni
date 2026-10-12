import Foundation
import OmniXPCContracts

#if os(macOS)
/// Raw streams require explicit awaited close; use the structured client helper for scoped ownership.
actor OmniXPCDiarizationStream {
    private let client: OmniXPCClient
    private let reference: OmniXPCSortformerStreamReference
    private let ownership: OmniXPCSortformerStartOwnership
    private let timeout: Duration
    private var audioSequence = 0
    private var terminal = false
    private var feeding: Task<OmniXPCSortformerProbabilityBatch, Error>?
    private var finishing: Task<Void, Error>?
    private var closing: Task<Void, Error>?

    private init(client: OmniXPCClient, ownership: OmniXPCSortformerStartOwnership, timeout: Duration) {
        self.client = client
        self.reference = ownership.reference
        self.ownership = ownership
        self.timeout = timeout
    }

    static func open(
        client: OmniXPCClient, model: OmniXPCSortformerModelReference, settings: OmniXPCSortformerSettings,
        timeout: Duration = .seconds(30), ownership: OmniXPCSortformerStartOwnership? = nil
    ) async throws -> OmniXPCDiarizationStream {
        let ownership = ownership ?? OmniXPCSortformerStartOwnership(model: model)
        let reference = try await client.startSortformerStream(
            model: model, settings: settings, timeout: timeout, ownership: ownership
        )
        if Task.isCancelled {
            let cleanup = Task { try await client.closeSortformerStream(reference) }
            try await cleanup.value
            throw CancellationError()
        }
        return OmniXPCDiarizationStream(client: client, ownership: ownership, timeout: timeout)
    }

    func feed(samples16k: [Float]) async throws -> OmniXPCSortformerProbabilityBatch {
        try requireReady()
        guard !samples16k.isEmpty, samples16k.count <= OmniXPCSortformerLimits.maximumChunkSampleCount,
              samples16k.allSatisfy(\.isFinite), audioSequence < Int.max else {
            throw OmniXPCFailure.error(.invalidRequest, "Sortformer requires 1...32000 finite mono 16 kHz samples and an available sequence.")
        }
        let sequence = audioSequence + 1
        let exchange = Task { [client, reference, timeout] in
            try Task.checkCancellation()
            let audio = OmniVoiceActivityStream.float32LittleEndian(samples16k)
            return try await client.pushSortformerAudio(audio, to: reference, sequence: sequence, timeout: timeout)
        }
        feeding = exchange
        defer { feeding = nil }
        do {
            let batch = try await withTaskCancellationHandler {
                try await exchange.value
            } onCancel: {
                exchange.cancel()
            }
            try Task.checkCancellation()
            guard !terminal else { throw CancellationError() }
            audioSequence = sequence
            return batch
        } catch {
            try await close()
            throw error
        }
    }

    /// Native finish drains ownership without padding audio or producing a final batch.
    func finish() async throws {
        try requireReady()
        let exchange = Task { [client, reference, timeout] in
            try await client.finishSortformerStream(reference, timeout: timeout)
        }
        finishing = exchange
        defer { finishing = nil }
        do {
            try await withTaskCancellationHandler {
                try await exchange.value
            } onCancel: {
                exchange.cancel()
            }
            try Task.checkCancellation()
            guard !terminal else { throw CancellationError() }
            terminal = true
        } catch {
            try await close()
            throw error
        }
    }

    func close() async throws {
        requestClose()
        try await closing?.value
    }

    /// Cancellation initiates durable cleanup even while the operation is suspended elsewhere.
    func requestClose() {
        guard closing == nil else { return }
        terminal = true
        let feed = feeding
        let finish = finishing
        feed?.cancel()
        finish?.cancel()
        closing = Task { [client, reference, ownership] in
            _ = await feed?.result
            _ = await finish?.result
            do {
                if ownership.status != .drained { try await client.closeSortformerStream(reference) }
            } catch {
                // Note (Omni): old waiters must not clear a newer retry; reset inside the failed attempt.
                closing = nil
                throw error
            }
        }
    }

    private func requireReady() throws {
        try Task.checkCancellation()
        guard !terminal else { throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream is terminal or closing.") }
        guard feeding == nil, finishing == nil else {
            throw OmniXPCFailure.error(.busy, "The Sortformer stream already has a pending command.")
        }
    }
}

extension OmniXPCClient {
    /// Awaits close on return, throw or cancellation, including when the operation retains its raw stream.
    func withSortformerDiarizationStream<Value: Sendable>(
        model: OmniXPCSortformerModelReference, settings: OmniXPCSortformerSettings,
        timeout: Duration = .seconds(30),
        operation: @MainActor (OmniXPCDiarizationStream) async throws -> Value
    ) async throws -> Value {
        let stream = try await OmniXPCDiarizationStream.open(client: self, model: model, settings: settings, timeout: timeout)
        return try await withTaskCancellationHandler {
            let outcome: Result<Value, Error>
            do {
                try Task.checkCancellation()
                outcome = .success(try await operation(stream))
            } catch {
                outcome = .failure(error)
            }
            try await stream.close()
            try Task.checkCancellation()
            return try outcome.get()
        } onCancel: {
            Task { await stream.requestClose() }
        }
    }
}
#endif
