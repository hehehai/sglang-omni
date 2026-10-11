/// Opt-in ASR adapter for Native's bounded 30-second realtime validation lease.
import Foundation
import OmniXPCContracts

nonisolated final class OmniXPCStreamingSession: ASRStreamingSession, Sendable {
    static let idlePollInterval: Duration = .milliseconds(50)

    /// Raw consumers that break early must call closeAndWait; a retained stream does not observe break.
    let events: AsyncStream<ASRStreamingEvent>
    private let buffer: OmniXPCStreamingBuffer
    private let worker: Task<Void, Error>

#if os(macOS)
    static func qwen(
        client: OmniXPCClient, model: OmniXPCModelReference, language: String?, context: String? = nil,
        maximumTokenCount: Int, settings: OmniXPCRealtimeSettings, requestTimeout: Duration = .seconds(240)
    ) async throws -> OmniXPCStreamingSession {
        guard requestTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime request deadline must be positive.")
        }
        let reference = try await client.startRealtimeSession(
            model: model, language: language, context: context,
            maximumTokenCount: maximumTokenCount, settings: settings
        )
        let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        let worker = Task.detached {
            defer { buffer.releaseWorker() }
            try await Self.run(client: client, reference: reference, buffer: buffer, requestTimeout: requestTimeout)
        }
        let session = OmniXPCStreamingSession(events: events, buffer: buffer, worker: worker)
        if Task.isCancelled {
            try await session.closeAndWait()
            throw CancellationError()
        }
        return session
    }
#endif

    init(events: AsyncStream<ASRStreamingEvent>, buffer: OmniXPCStreamingBuffer, worker: Task<Void, Error>) {
        self.events = events
        self.buffer = buffer
        self.worker = worker
        buffer.install(worker: worker)
    }

    func feedAudio(samples: [Float]) { buffer.feedAudio(samples: samples) }
    func stop() { buffer.stop() }
    func cancel() { buffer.cancel() }

    /// A cancellation ACK or stream finish alone is not a Native drain barrier; cleanup errors throw.
    func waitUntilClosed() async throws { try await worker.value }

    func closeAndWait() async throws {
        cancel()
        try await waitUntilClosed()
    }

    /// Returns the last event, draining on false, stream end, thrown error, or consumer cancellation.
    @discardableResult
    func consumeEvents(until consume: @Sendable (ASRStreamingEvent) async throws -> Bool) async throws -> ASRStreamingEvent? {
        try await withTaskCancellationHandler {
            var lastEvent: ASRStreamingEvent?
            do {
                for await event in events {
                    try Task.checkCancellation()
                    lastEvent = event
                    if try await !consume(event) { break }
                }
                try Task.checkCancellation()
            } catch {
                try await closeAndWait()
                throw error
            }
            try await closeAndWait()
            return lastEvent
        } onCancel: {
            buffer.cancel()
        }
    }

#if os(macOS)
    private static func run(
        client: OmniXPCClient, reference: OmniXPCRealtimeSessionReference,
        buffer: OmniXPCStreamingBuffer, requestTimeout: Duration
    ) async throws {
        var sequence = 1
        var acknowledgedEventSequence = 0
        var presentation = OmniXPCStreamingPresentation()
        var terminalEvent: ASRStreamingEvent?
        var hasNativeTerminal = false
        var isDrained = false
        var didFinish = false
        var drainDeadline: ContinuousClock.Instant?
        var failure: Error?
        do {
            while !isDrained {
                try Task.checkCancellation()
                if let drainDeadline, ContinuousClock.now >= drainDeadline {
                    throw OmniXPCFailure.error(.timedOut, "The realtime terminal drain deadline expired.")
                }
                var sentInput = false
                if !hasNativeTerminal {
                    switch buffer.nextInput() {
                    case .audio(let audio):
                        try await client.pushRealtimeAudio(audio, to: reference, sequence: sequence)
                        sequence += 1
                        sentInput = true
                    case .finish:
                        try await client.finishRealtimeSession(reference, timeout: requestTimeout)
                        didFinish = true
                        drainDeadline = ContinuousClock.now.advanced(by: requestTimeout)
                        sentInput = true
                    case .idle:
                        break
                    case .closed:
                        throw CancellationError()
                    }
                }
                let batch = try await client.pollRealtimeEvents(reference, acknowledgedEventSequence: acknowledgedEventSequence)
                for event in batch.events {
                    switch event.kind {
                    case .updated:
                        break
                    case .segment:
                        if let display = try presentation.apply(event) { buffer.display(display) }
                    case .completed:
                        guard didFinish, let text = event.text else {
                            throw OmniXPCFailure.error(.incompatibleService, "Realtime completed before all local input was finished.")
                        }
                        terminalEvent = .ended(ASRTranscriptionResult(text: text))
                        hasNativeTerminal = true
                    case .cancelled:
                        hasNativeTerminal = true
                    case .failed:
                        terminalEvent = .failed(ASRStreamingFailure(message: event.failureMessage ?? "Realtime Native inference failed."))
                        hasNativeTerminal = true
                    }
                    acknowledgedEventSequence = event.sequence
                }
                isDrained = batch.isDrained
                if !isDrained, !hasNativeTerminal, !sentInput, batch.events.isEmpty {
                    try await Task.sleep(for: idlePollInterval)
                }
            }
        } catch {
            failure = error
        }

        if !isDrained {
            // note (Codex): Cleanup must survive cancellation of the task that owns the lease.
            let cleanup = Task { @MainActor in try await client.closeRealtimeSession(reference) }
            do { try await cleanup.value }
            catch {
                buffer.complete(.failed(ASRStreamingFailure(message: "Realtime XPC cleanup failed: \(error.localizedDescription)")))
                throw error
            }
        }
        if let failure {
            if failure is CancellationError {
                buffer.complete(nil)
            } else {
                buffer.complete(.failed(ASRStreamingFailure(message: failure.localizedDescription)))
                throw failure
            }
        } else {
            buffer.complete(terminalEvent)
        }
    }
#endif

    deinit { buffer.cancel() }
}
