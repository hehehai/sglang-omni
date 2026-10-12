import Foundation
import OmniXPCContracts

#if os(macOS)
/// The caller owns the preloaded model and client; this engine owns only its streams.
actor OmniXPCMeetingSpeakerDiarizationEngine: MeetingSpeakerDiarizationEngine {
    private let client: OmniXPCClient
    private let model: OmniXPCSortformerModelReference
    private let configuration: MeetingSortformerConfiguration
    private let coordinator: MeetingLocalInferenceCoordinator
    private let timeSource: @Sendable () -> ContinuousClock.Instant
    private var operationID: UUID?
    private var stream: OmniXPCDiarizationStream?

    init(
        client: OmniXPCClient,
        model: OmniXPCSortformerModelReference,
        configuration: MeetingSortformerConfiguration,
        coordinator: MeetingLocalInferenceCoordinator = .shared,
        timeSource: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.client = client
        self.model = model
        self.configuration = configuration
        self.coordinator = coordinator
        self.timeSource = timeSource
    }

    func diarize(
        asset: MeetingAudioAsset,
        options _: MeetingSpeakerDiarizationOptions
    ) async throws -> [MeetingSpeakerTurn] {
        guard operationID == nil else {
            throw OmniXPCFailure.error(.busy, "Speaker analysis already has a pending operation.")
        }
        guard let startSample = Int(exactly: (asset.sessionStartOffset * asset.sampleRate).rounded()) else {
            throw MeetingSpeakerFeedError.audioUnavailable
        }
        let descriptor = MeetingAudioAssetDescriptor(
            source: asset.source, sampleRate: asset.sampleRate,
            startSample: startSample, sampleCount: asset.samples.count
        )
        return try await runSession(descriptors: [descriptor], loadAsset: { _ in asset },
                                    fileAnalysis: false, progress: nil)
    }

    func diarizeSession(
        descriptors: [MeetingAudioAssetDescriptor],
        loadAsset: @escaping @Sendable (MeetingAudioAssetDescriptor) async -> MeetingAudioAsset?,
        continuousAudioURL _: URL?,
        options _: MeetingSpeakerDiarizationOptions,
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [MeetingSpeakerTurn] {
        try await runSession(descriptors: descriptors, loadAsset: loadAsset,
                             fileAnalysis: false, progress: progress)
    }

    func diarizeFile(
        descriptors: [MeetingAudioAssetDescriptor],
        loadAsset: @escaping @Sendable (MeetingAudioAssetDescriptor) async -> MeetingAudioAsset?,
        options _: MeetingSpeakerDiarizationOptions,
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [MeetingSpeakerTurn] {
        try await runSession(descriptors: descriptors, loadAsset: loadAsset,
                             fileAnalysis: true, progress: progress)
    }

    private func runSession(
        descriptors: [MeetingAudioAssetDescriptor],
        loadAsset: @escaping @Sendable (MeetingAudioAssetDescriptor) async -> MeetingAudioAsset?,
        fileAnalysis: Bool,
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [MeetingSpeakerTurn] {
        guard operationID == nil else {
            throw OmniXPCFailure.error(.busy, "Speaker analysis already has a pending operation.")
        }
        let operationID = UUID()
        self.operationID = operationID
        defer { self.operationID = nil }
        return try await withTaskCancellationHandler {
            do {
                // Note (Omni): a failed drain remains owned and must succeed before reuse.
                try await closeStream()
                try Task.checkCancellation()
                guard configuration.sampleRate == OmniXPCSortformerLimits.sampleRate,
                      configuration.featureHopSampleCount == OmniXPCSortformerLimits.featureHopSampleCount,
                      configuration.subsamplingFactor == OmniXPCSortformerLimits.subsamplingFactor,
                      configuration.usesAOSC else {
                    throw MeetingSpeakerFeedError.invalidConfiguration
                }
                let policy = try configuration.feedPolicy()
                try configuration.validateEncoderCapacity(
                    cacheMaximumFrameCount: policy.cacheMaximumFrames,
                    fifoMaximumFrameCount: MeetingSpeakerFeedPolicy.fifoMaximumFrames
                )
                let settings = try OmniXPCSortformerSettings(
                    threshold: 0.5, minimumDurationSeconds: 0, mergeGapSeconds: 0.18,
                    speakerCacheMaximumFrameCount: policy.cacheMaximumFrames,
                    fifoMaximumFrameCount: MeetingSpeakerFeedPolicy.fifoMaximumFrames
                )
                var previousDescriptor: MeetingAudioAssetDescriptor?
                var processedFrameCount: UInt64 = 0
                var turns: [MeetingSpeakerTurn] = []
                let descriptorCount = max(descriptors.count, 1)
                await progress?(0)
                for (index, descriptor) in descriptors.enumerated() {
                    try Task.checkCancellation()
                    if let previousDescriptor {
                        let expectedStart = previousDescriptor.sessionStartOffset + previousDescriptor.durationSeconds
                        let isContinuous = descriptor.source == previousDescriptor.source
                            && abs(descriptor.sessionStartOffset - expectedStart) < 0.05
                        if !isContinuous {
                            try await closeStream()
                            processedFrameCount = 0
                        }
                    }
                    previousDescriptor = descriptor
                    guard let asset = await loadAsset(descriptor) else {
                        throw MeetingSpeakerFeedError.audioUnavailable
                    }
                    try Task.checkCancellation()
                    let prepared = fileAnalysis && asset.sampleRate == 16_000
                        ? asset.samples
                        : ASRVoiceActivitySampleRateConverter.resample(
                            samples: asset.samples, from: asset.sampleRate, to: 16_000
                        )
                    guard !prepared.isEmpty else { throw MeetingSpeakerFeedError.audioUnavailable }
                    if stream == nil {
                        stream = try await OmniXPCDiarizationStream.open(client: client, model: model, settings: settings)
                    }
                    guard let currentStream = stream else { preconditionFailure("Missing owned diarization stream") }
                    var sampleOffset = 0
                    while sampleOffset < prepared.count {
                        try Task.checkCancellation()
                        // Note (Omni): Native's two-second cap differs from HTTP feeds; numerical parity is pending.
                        let sampleCount = min(policy.samplesPerFeed, OmniXPCSortformerLimits.maximumChunkSampleCount,
                                              prepared.count - sampleOffset)
                        let samples = Array(prepared[sampleOffset..<(sampleOffset + sampleCount)])
                        let inputFrameCount = processedFrameCount
                        let batch: OmniXPCSortformerProbabilityBatch
                        if fileAnalysis {
                            batch = try await coordinator.withPermit(.fileSpeakerAnalysis) { [timeSource] in
                                let startedAt = timeSource()
                                do {
                                    let batch = try await currentStream.feed(samples16k: samples)
                                    try Task.checkCancellation()
                                    try policy.validateFeedDuration(startedAt.duration(to: timeSource()))
                                    return batch
                                } catch {
                                    // Note (Omni): cancel acknowledgement alone cannot release the inference lane.
                                    try await currentStream.close()
                                    throw error
                                }
                            }
                        } else {
                            batch = try await currentStream.feed(samples16k: samples)
                        }
                        try Task.checkCancellation()
                        processedFrameCount = batch.processedFrameCount
                        let audioOffset = asset.sessionStartOffset + Double(sampleOffset) / Double(policy.sampleRate)
                        turns.append(contentsOf: batch.segments.compactMap { segment in
                            guard let range = policy.mappedRange(
                                start: segment.startSeconds, end: segment.endSeconds,
                                stateFrames: Int(inputFrameCount), audioOffset: audioOffset, sampleCount: sampleCount
                            ) else { return nil }
                            return MeetingSpeakerTurn(
                                source: asset.source, speakerID: "sortformer-\(segment.speakerIndex)",
                                displayName: MeetingSpeakerDisplayNameFormatter.displayName(ordinal: segment.speakerIndex + 1),
                                startSeconds: range.lowerBound, endSeconds: range.upperBound, confidence: nil
                            )
                        })
                        sampleOffset += sampleCount
                        await progress?((Double(index) + Double(sampleOffset) / Double(prepared.count)) / Double(descriptorCount))
                    }
                }
                if descriptors.isEmpty { await progress?(1) }
                try Task.checkCancellation()
                try await closeStream()
                try Task.checkCancellation()
                return turns
            } catch {
                try await closeStream()
                throw error
            }
        } onCancel: {
            Task { await self.requestClose(operationID: operationID) }
        }
    }

    private func closeStream() async throws {
        try await stream?.close()
        stream = nil
    }

    private func requestClose(operationID: UUID) async {
        guard self.operationID == operationID else { return }
        await stream?.requestClose()
    }
}
#endif
