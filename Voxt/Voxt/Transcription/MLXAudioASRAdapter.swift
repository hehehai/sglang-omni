/// Compatibility conversions kept outside the Native ASR contract.
import Foundation
import MLXAudioSTT

nonisolated extension ASRTranscriptSegment {
    init(mlxSegment: STTTranscriptSegment) {
        self.init(
            text: mlxSegment.text,
            startSeconds: mlxSegment.startTime,
            endSeconds: mlxSegment.endTime,
            speakerID: mlxSegment.speakerID,
            language: mlxSegment.language,
            confidence: mlxSegment.confidence,
            emotion: mlxSegment.emotion,
            event: mlxSegment.event
        )
    }
}

nonisolated extension ASRTranscriptionResult {
    init(mlxOutput: STTOutput) {
        let provenance: ASRLanguageProvenance
        switch mlxOutput.languageProvenance {
        case .detected: provenance = .detected
        case .requested: provenance = .requested
        case .outputTarget: provenance = .outputTarget
        case .modelDefault: provenance = .modelDefault
        case .unknown: provenance = .unknown
        @unknown default: provenance = .unknown
        }
        self.init(
            text: mlxOutput.text,
            segments: (mlxOutput.segments ?? []).map { ASRTranscriptSegment(mlxSegment: $0) },
            language: mlxOutput.language,
            languageProvenance: provenance,
            generationMetadata: mlxOutput.generationTokens > 0
                ? ASRGenerationMetadata(generatedTokenCount: mlxOutput.generationTokens, hitLengthLimit: nil)
                : nil
        )
    }
}

nonisolated extension ASRGenerationOptions {
    var mlxParameters: STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: maximumTokenCount,
            temperature: temperature,
            topP: topProbabilityThreshold,
            topK: topTokenCount,
            verbose: verbose,
            language: language,
            usePunctuation: usePunctuation,
            chunkDuration: chunkDurationSeconds,
            minChunkDuration: minimumChunkDurationSeconds,
            kvBits: kvCacheBitWidth,
            kvGroupSize: kvCacheGroupSize,
            quantizedKVStart: kvCacheQuantizedStartTokenCount
        )
    }
}

nonisolated extension ASRStreamingEvent {
    init?(mlxEvent: TranscriptionEvent) {
        switch mlxEvent {
        case .displayUpdate(let confirmedText, let provisionalText):
            self = .displayUpdate(confirmedText: confirmedText, provisionalText: provisionalText)
        case .ended(let output):
            self = .ended(ASRTranscriptionResult(mlxOutput: output))
        case .failed(let failure):
            self = .failed(ASRStreamingFailure(message: failure.message))
        case .confirmed, .provisional, .stats:
            return nil
        @unknown default:
            return nil
        }
    }
}

nonisolated final class MLXAudioStreamingSessionAdapter: ASRStreamingSession, @unchecked Sendable {
    let events: AsyncStream<ASRStreamingEvent>
    private let forwarding: Task<Void, Never>
    private let feed: @Sendable ([Float]) -> Void
    private let stopSession: @Sendable () -> Void
    private let cancelSession: @Sendable () -> Void

    convenience init(session: StreamingInferenceSession) {
        self.init(
            source: session.events,
            feed: { session.feedAudio(samples: $0) },
            stop: { session.stop() },
            cancel: { session.cancel() }
        )
    }

    convenience init(session: NemotronASRStreamingSession) {
        self.init(
            source: session.events,
            feed: { session.feedAudio(samples: $0) },
            stop: { session.stop() },
            cancel: { session.cancel() }
        )
    }

    private init(
        source: AsyncStream<TranscriptionEvent>,
        feed: @escaping @Sendable ([Float]) -> Void,
        stop: @escaping @Sendable () -> Void,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.feed = feed
        stopSession = stop
        cancelSession = cancel
        let (events, continuation) = AsyncStream.makeStream(of: ASRStreamingEvent.self)
        self.events = events
        forwarding = Task.detached {
            for await event in source {
                guard !Task.isCancelled else { break }
                if let mapped = ASRStreamingEvent(mlxEvent: event) {
                    continuation.yield(mapped)
                }
            }
            continuation.finish()
        }
    }

    func feedAudio(samples: [Float]) { feed(samples) }
    func stop() { stopSession() }
    func cancel() {
        cancelSession()
        forwarding.cancel()
    }

    deinit {
        cancelSession()
        forwarding.cancel()
    }
}
