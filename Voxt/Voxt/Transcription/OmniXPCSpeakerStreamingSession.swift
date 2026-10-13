import Foundation
import OmniXPCContracts

#if os(macOS)
/// An opt-in bounded ASR consumer that permanently closes its entrusted model owner.
@MainActor
final class OmniXPCSpeakerStreamingSession: ASRRetiringStreamingSession {
    nonisolated let events: AsyncStream<ASRStreamingEvent>
    private nonisolated let buffer: OmniXPCStreamingBuffer
    private let owner: OmniXPCSpeakerModelOwner
    private let requestTimeout: Duration
    private let cleanupTimeout: Duration
    private let pollInterval: Duration
    private var worker: Task<Void, Error>?
    private var closing: (id: UUID, task: Task<Void, Error>)?
    private var retainedUntilClosed: OmniXPCSpeakerStreamingSession?
    private var permanentCloseObserver: (@MainActor () -> Void)?
    private var didPermanentlyClose = false

    static func open(
        owner: OmniXPCSpeakerModelOwner, settings: OmniXPCSpeakerSettings,
        requestTimeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> OmniXPCSpeakerStreamingSession {
        guard requestTimeout > .zero, cleanupTimeout > .zero, pollInterval > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker streaming deadlines and poll interval must be positive.")
        }
        try await owner.startSession(settings: settings, timeout: requestTimeout, cleanupTimeout: cleanupTimeout)
        let session = OmniXPCSpeakerStreamingSession(
            owner: owner, requestTimeout: requestTimeout, cleanupTimeout: cleanupTimeout, pollInterval: pollInterval
        )
        session.retainedUntilClosed = session
        owner.notifyWhenPermanentlyClosed { [weak session] in session?.modelDidPermanentlyClose() }
        let worker = Task { @MainActor [session] in try await session.run() }
        session.worker = worker
        session.buffer.install(worker: worker)
        if Task.isCancelled {
            try await session.closeAndWait()
            throw CancellationError()
        }
        return session
    }

    private init(owner: OmniXPCSpeakerModelOwner, requestTimeout: Duration, cleanupTimeout: Duration, pollInterval: Duration) {
        (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        self.owner = owner
        self.requestTimeout = requestTimeout
        self.cleanupTimeout = cleanupTimeout
        self.pollInterval = pollInterval
    }

    nonisolated func feedAudio(samples: [Float]) { buffer.feedAudio(samples: samples) }
    nonisolated func stop() { buffer.stop() }
    nonisolated func cancel() { buffer.cancel() }

    func notifyWhenPermanentlyClosed(_ observer: @escaping @MainActor () -> Void) {
        if didPermanentlyClose {
            observer()
        } else {
            precondition(permanentCloseObserver == nil, "A speaker session can be entrusted to only one retiring runtime.")
            permanentCloseObserver = observer
        }
    }

    private func modelDidPermanentlyClose() {
        didPermanentlyClose = true
        retainedUntilClosed = nil
        let observer = permanentCloseObserver
        permanentCloseObserver = nil
        observer?()
    }

    func waitUntilClosed() async throws { try await worker?.value }

    func closeAndWait() async throws {
        cancel()
        _ = await worker?.result
        try await retireModel()
    }

    @discardableResult
    func consumeEvents(until consume: @MainActor (ASRStreamingEvent) async throws -> Bool) async throws -> ASRStreamingEvent? {
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

    private func run() async throws {
        defer { buffer.releaseWorker() }
        var presentation = OmniXPCStreamingPresentation(joining: owner.kind == .moss ? .lines : .scriptAware)
        var terminalEvent: ASRStreamingEvent?
        var didFinish = false
        var terminalDeadline: ContinuousClock.Instant?
        var failure: Error?
        do {
            while terminalEvent == nil {
                try Task.checkCancellation()
                if let terminalDeadline, ContinuousClock.now >= terminalDeadline {
                    throw OmniXPCFailure.error(.timedOut, "The speaker stream did not publish its terminal event in time.")
                }
                var sentInput = false
                switch buffer.nextInput() {
                case .audio(let audio):
                    _ = try await owner.push(audio: audio, timeout: requestTimeout, cleanupTimeout: cleanupTimeout)
                    sentInput = true
                case .finish:
                    try await owner.commit(timeout: requestTimeout, cleanupTimeout: cleanupTimeout)
                    try await owner.finish(timeout: requestTimeout, cleanupTimeout: cleanupTimeout)
                    didFinish = true
                    terminalDeadline = ContinuousClock.now.advanced(by: requestTimeout)
                    sentInput = true
                case .idle:
                    break
                case .closed:
                    throw CancellationError()
                }
                let batch = try await owner.poll(timeout: requestTimeout, cleanupTimeout: cleanupTimeout)
                for event in batch.events {
                    switch event.kind {
                    case .updated:
                        break
                    case .segment:
                        if let display = try presentation.apply(event) { buffer.display(display) }
                    case .completed:
                        guard didFinish, let text = event.text, let segments = event.segments else {
                            throw OmniXPCFailure.error(.incompatibleService, "The speaker stream completed before local input was finished.")
                        }
                        terminalEvent = .ended(ASRTranscriptionResult(text: text, segments: segments.map {
                            ASRTranscriptSegment(text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                                speakerID: $0.speaker, language: $0.language, emotion: $0.emotion, event: $0.event)
                        }))
                    case .cancelled:
                        throw CancellationError()
                    case .failed:
                        throw OmniXPCFailure.error(.nativeFailure, "Speaker Native inference failed with status \(event.failureStatus.rawValue).")
                    }
                }
                if terminalEvent == nil, !sentInput, batch.events.isEmpty {
                    try await Task.sleep(for: pollInterval)
                }
            }
        } catch {
            failure = error
        }
        do {
            // note (Codex): Only checked original-load retirement may break the fail-closed self retention.
            try await retireModel()
        } catch {
            buffer.complete(.failed(ASRStreamingFailure(message: "Speaker XPC cleanup failed: \(error.localizedDescription)")))
            throw error
        }
        if let failure {
            buffer.complete(failure is CancellationError ? nil : .failed(ASRStreamingFailure(message: failure.localizedDescription)))
            throw failure
        } else {
            buffer.complete(terminalEvent)
        }
    }

    private func retireModel() async throws {
        if let closing { return try await closing.task.value }
        let identity = UUID()
        let task = Task { @MainActor in
            defer {
                if self.closing?.id == identity { self.closing = nil }
            }
            try await self.owner.close(timeout: self.cleanupTimeout)
        }
        closing = (identity, task)
        try await task.value
    }
}
#endif
