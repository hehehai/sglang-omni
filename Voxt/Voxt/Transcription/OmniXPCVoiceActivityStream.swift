import Foundation
import OmniXPCContracts

#if os(macOS)
/// Raw streams require explicit awaited close; use the structured client helper for scoped ownership.
actor OmniXPCVoiceActivityStream {
    private let client: OmniXPCClient
    private let reference: OmniXPCSileroStreamReference
    private let timeout: Duration
    private var audioSequence = 0
    private var terminal = false
    private var finished = false
    private var inFlight: Task<Float?, Error>?
    private var closing: Task<Void, Error>?

    private init(client: OmniXPCClient, reference: OmniXPCSileroStreamReference, timeout: Duration) {
        self.client = client
        self.reference = reference
        self.timeout = timeout
    }

    static func open(
        client: OmniXPCClient, model: OmniXPCSileroModelReference, timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCVoiceActivityStream {
        let reference = try await client.startSileroStream(model: model, timeout: timeout)
        if Task.isCancelled {
            let cleanup = Task { try await client.closeSileroStream(reference) }
            try await cleanup.value
            throw CancellationError()
        }
        return OmniXPCVoiceActivityStream(client: client, reference: reference, timeout: timeout)
    }

    /// Returns the latest whole-frame probability, or nil when no 512-sample frame completed.
    func probability(samples16k: [Float]) async throws -> Float? {
        try requireReady()
        guard !samples16k.isEmpty, samples16k.count <= OmniXPCSileroLimits.maximumChunkSampleCount,
              samples16k.allSatisfy(\.isFinite), audioSequence < Int.max else {
            throw OmniXPCFailure.error(.invalidRequest, "Silero requires 1...32000 finite mono 16 kHz samples and an available sequence.")
        }
        let sequence = audioSequence + 1
        let exchange = Task { [client, reference, timeout] in
            try Task.checkCancellation()
            let audio = OmniVoiceActivityStream.float32LittleEndian(samples16k)
            let batch = try await client.pushSileroAudio(audio, to: reference, sequence: sequence, timeout: timeout)
            return batch.probabilities.last
        }
        inFlight = exchange
        defer { inFlight = nil }
        do {
            let probability = try await withTaskCancellationHandler {
                try await exchange.value
            } onCancel: {
                exchange.cancel()
            }
            try Task.checkCancellation()
            guard !terminal else { throw CancellationError() }
            audioSequence = sequence
            return probability
        } catch {
            try await close()
            throw error
        }
    }

    /// Explicitly pads a partial final frame; successful finish has already drained native ownership.
    func finish() async throws -> Float? {
        try requireReady()
        let exchange = Task { [client, reference, timeout] in
            let batch = try await client.finishSileroStream(reference, timeout: timeout)
            return batch.probabilities.last
        }
        inFlight = exchange
        defer { inFlight = nil }
        do {
            let probability = try await withTaskCancellationHandler {
                try await exchange.value
            } onCancel: {
                exchange.cancel()
            }
            finished = true
            try Task.checkCancellation()
            guard !terminal else { throw CancellationError() }
            terminal = true
            return probability
        } catch {
            try await close()
            throw error
        }
    }

    func close() async throws {
        requestClose()
        try await closing?.value
    }

    /// The cancellation handler can initiate cleanup even while its operation is suspended elsewhere.
    func requestClose() {
        guard closing == nil else { return }
        terminal = true
        let exchange = inFlight
        exchange?.cancel()
        let needsClose = !finished
        closing = Task { [client, reference] in
            let barrier = Task {
                if needsClose { try await client.closeSileroStream(reference) }
            }
            let result = await barrier.result
            _ = await exchange?.result
            do {
                try result.get()
            } catch {
                // Note (Omni): old waiters must not clear a newer retry; reset inside the failed attempt.
                closing = nil
                throw error
            }
        }
    }

    private func requireReady() throws {
        try Task.checkCancellation()
        guard !terminal else { throw OmniXPCFailure.error(.invalidRequest, "The Silero stream is terminal or closing.") }
        guard inFlight == nil else { throw OmniXPCFailure.error(.busy, "The Silero stream already has a pending command.") }
    }
}

extension OmniXPCClient {
    /// Closes on return, throw or cancellation, including when the operation retains its raw stream.
    func withSileroVoiceActivityStream<Value: Sendable>(
        model: OmniXPCSileroModelReference, timeout: Duration = .seconds(30),
        operation: @MainActor (OmniXPCVoiceActivityStream) async throws -> Value
    ) async throws -> Value {
        let stream = try await OmniXPCVoiceActivityStream.open(client: self, model: model, timeout: timeout)
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
