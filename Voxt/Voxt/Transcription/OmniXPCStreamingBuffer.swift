/// Portable bounds for microphone admission and realtime transcript presentation.
import Foundation
import OmniXPCContracts

nonisolated final class OmniXPCStreamingBuffer: @unchecked Sendable {
    static let maximumPendingSampleCount = OmniXPCProtocolLimits.sampleRate * 4
    static let maximumBufferedPresentationEvents = 1

    enum Input: Equatable {
        case audio(Data)
        case finish
        case idle
        case closed
    }

    private let lock = NSLock()
    private let presentationLock = NSRecursiveLock()
    private let continuation: AsyncStream<ASRStreamingEvent>.Continuation
    private var pendingAudio: [Data] = []
    private var pendingSampleCount = 0
    private var totalSampleCount = 0
    private var isStopping = false
    private var isFinishSent = false
    private var isTerminal = false
    private var isShutdownRequested = false
    private var localFailure: ASRStreamingFailure?
    private var worker: Task<Void, Error>?

    private init(continuation: AsyncStream<ASRStreamingEvent>.Continuation) {
        self.continuation = continuation
    }

    static func makeStream() -> (AsyncStream<ASRStreamingEvent>, OmniXPCStreamingBuffer) {
        let (events, continuation) = AsyncStream.makeStream(
            of: ASRStreamingEvent.self, bufferingPolicy: .bufferingNewest(maximumBufferedPresentationEvents)
        )
        let buffer = OmniXPCStreamingBuffer(continuation: continuation)
        continuation.onTermination = { @Sendable _ in buffer.cancel() }
        return (events, buffer)
    }

    func install(worker: Task<Void, Error>) {
        let shouldCancel = lock.withLock {
            if isShutdownRequested || isTerminal { return true }
            self.worker = worker
            return false
        }
        if shouldCancel { worker.cancel() }
    }

    func releaseWorker() { lock.withLock { worker = nil } }

    func feedAudio(samples: [Float]) {
        presentationLock.lock()
        defer { presentationLock.unlock() }
        let failure: String? = lock.withLock {
            guard !isStopping, !isShutdownRequested, !isTerminal, !samples.isEmpty else { return nil }
            guard samples.count <= OmniXPCProtocolLimits.maximumSampleCount - totalSampleCount else {
                return "Realtime XPC validation accepts at most 30 seconds of input; it is not a long-meeting backend."
            }
            guard samples.count <= Self.maximumPendingSampleCount - pendingSampleCount else {
                return "Realtime XPC pending audio exceeded its four-second budget."
            }
            guard samples.allSatisfy(\.isFinite) else {
                return "Realtime XPC audio must contain finite Float32 samples."
            }
            var encoded = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
            for sample in samples {
                var bits = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { encoded.append(contentsOf: $0) }
            }
            var offset = 0
            while offset < encoded.count {
                if pendingAudio.isEmpty || pendingAudio[pendingAudio.count - 1].count == OmniXPCProtocolLimits.maximumChunkAudioByteCount {
                    pendingAudio.append(Data())
                }
                let last = pendingAudio.count - 1
                let byteCount = min(OmniXPCProtocolLimits.maximumChunkAudioByteCount - pendingAudio[last].count, encoded.count - offset)
                pendingAudio[last].append(encoded.subdata(in: offset..<(offset + byteCount)))
                offset += byteCount
            }
            pendingSampleCount += samples.count
            totalSampleCount += samples.count
            return nil
        }
        if let failure { requestShutdown(failure: ASRStreamingFailure(message: failure)) }
    }

    func stop() { lock.withLock { isStopping = true } }

    func nextInput() -> Input {
        lock.withLock {
            if isShutdownRequested || isTerminal { return .closed }
            if !pendingAudio.isEmpty {
                let audio = pendingAudio.removeFirst()
                pendingSampleCount -= audio.count / MemoryLayout<UInt32>.size
                return .audio(audio)
            }
            if isStopping, !isFinishSent {
                isFinishSent = true
                return .finish
            }
            return .idle
        }
    }

    func display(_ event: ASRStreamingEvent) {
        guard case .displayUpdate = event else { return }
        presentationLock.withLock {
            let canPublish = lock.withLock { !isShutdownRequested && !isTerminal }
            if canPublish { continuation.yield(event) }
        }
    }

    func cancel() { requestShutdown(failure: nil) }

    private func requestShutdown(failure: ASRStreamingFailure?) {
        presentationLock.withLock {
            let shutdown: (finishStream: Bool, worker: Task<Void, Error>?) = lock.withLock {
                guard !isTerminal else { return (false, nil) }
                isShutdownRequested = true
                pendingAudio.removeAll()
                pendingSampleCount = 0
                if localFailure == nil { localFailure = failure }
                isTerminal = localFailure == nil
                return (isTerminal, worker)
            }
            if shutdown.finishStream { continuation.finish() }
            shutdown.worker?.cancel()
        }
    }

    /// Only the lease owner may complete presentation, after its cleanup attempt has returned.
    func complete(_ event: ASRStreamingEvent?) {
        presentationLock.withLock {
            let terminal: (publish: Bool, event: ASRStreamingEvent?) = lock.withLock {
                guard !isTerminal else { return (false, nil) }
                isTerminal = true
                isShutdownRequested = true
                pendingAudio.removeAll()
                pendingSampleCount = 0
                return (true, localFailure.map { .failed($0) } ?? event)
            }
            guard terminal.publish else { return }
            if let event = terminal.event { continuation.yield(event) }
            continuation.finish()
        }
    }
}

nonisolated struct OmniXPCStreamingPresentation {
    static let maximumSegmentCount = 512
    static let maximumTranscriptByteCount = 256 * 1024

    private var assembler: OmniLiveTranscriptAssembler
    private var segmentByteCounts: [Int: Int] = [:]
    private var transcriptByteCount = 0

    init(joining: OmniLiveTranscriptAssembler.Joining = .scriptAware) {
        assembler = OmniLiveTranscriptAssembler(joining: joining)
    }

    mutating func apply(_ event: OmniXPCSpeakerEvent) throws -> ASRStreamingEvent? {
        guard event.kind == .segment else { return nil }
        guard let sequence = Int(exactly: event.eventSequence), let segmentID = event.segmentID,
              let text = event.text, let isFinal = event.isFinal else {
            throw OmniXPCFailure.error(.incompatibleService, "The speaker segment cannot be represented locally.")
        }
        return try apply(sequence: sequence, segmentID: Int(segmentID), text: text, isFinal: isFinal)
    }

    mutating func apply(_ event: OmniXPCRealtimeEvent) throws -> ASRStreamingEvent? {
        guard event.kind == .segment else { return nil }
        guard let segmentID = event.segmentID, let text = event.text, let isFinal = event.isFinal else {
            throw OmniXPCFailure.error(.incompatibleService, "The realtime segment is incomplete.")
        }
        return try apply(sequence: event.sequence, segmentID: segmentID, text: text, isFinal: isFinal)
    }

    private mutating func apply(sequence: Int, segmentID: Int, text: String, isFinal: Bool) throws -> ASRStreamingEvent? {
        var updatedAssembler = assembler
        guard case .display(let confirmed, let provisional) = updatedAssembler.apply(
            eventIndex: sequence, segmentID: segmentID, text: text, isFinal: isFinal
        ) else {
            assembler = updatedAssembler
            return nil
        }
        let previousByteCount = segmentByteCounts[segmentID]
        let nextByteCount = transcriptByteCount - (previousByteCount ?? 0) + text.utf8.count
        guard nextByteCount <= Self.maximumTranscriptByteCount,
              previousByteCount != nil || segmentByteCounts.count < Self.maximumSegmentCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime transcript exceeds its local presentation budget.")
        }
        segmentByteCounts[segmentID] = text.utf8.count
        transcriptByteCount = nextByteCount
        assembler = updatedAssembler
        return .displayUpdate(confirmedText: confirmed, provisionalText: provisional)
    }
}
