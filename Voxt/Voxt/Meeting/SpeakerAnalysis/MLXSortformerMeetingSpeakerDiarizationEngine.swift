import Foundation
import MLX
import MLXAudioVAD

actor MLXSortformerMeetingSpeakerDiarizationEngine: MeetingSpeakerDiarizationEngine {
    private var loadedModel: MeetingSortformerModelLease?

    func diarize(
        asset: MeetingAudioAsset, options _: MeetingSpeakerDiarizationOptions
    ) async throws -> [MeetingSpeakerTurn] {
        let descriptor = MeetingAudioAssetDescriptor(
            source: asset.source, sampleRate: asset.sampleRate,
            startSample: Int((asset.sessionStartOffset * asset.sampleRate).rounded()),
            sampleCount: asset.samples.count
        )
        return try await runSession(descriptors: [descriptor], loadAsset: { _ in asset }, fileAnalysis: false, progress: nil)
    }

    func diarizeSession(
        descriptors: [MeetingAudioAssetDescriptor],
        loadAsset: @escaping @Sendable (MeetingAudioAssetDescriptor) async -> MeetingAudioAsset?,
        continuousAudioURL _: URL?, options _: MeetingSpeakerDiarizationOptions,
        progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [MeetingSpeakerTurn] {
        try await runSession(descriptors: descriptors, loadAsset: loadAsset, fileAnalysis: false, progress: progress)
    }

    func diarizeFile(
        descriptors: [MeetingAudioAssetDescriptor],
        loadAsset: @escaping @Sendable (MeetingAudioAssetDescriptor) async -> MeetingAudioAsset?,
        options _: MeetingSpeakerDiarizationOptions, progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [MeetingSpeakerTurn] {
        defer { loadedModel = nil }
        return try await runSession(descriptors: descriptors, loadAsset: loadAsset, fileAnalysis: true, progress: progress)
    }

    private func runSession(
        descriptors: [MeetingAudioAssetDescriptor],
        loadAsset: @escaping @Sendable (MeetingAudioAssetDescriptor) async -> MeetingAudioAsset?,
        fileAnalysis: Bool, progress: (@Sendable (Double) async -> Void)?
    ) async throws -> [MeetingSpeakerTurn] {
        let loadedModel: MeetingSortformerModelLease
        if fileAnalysis {
            loadedModel = try await MeetingLocalInferenceCoordinator.shared.withPermit(.fileSpeakerAnalysis) {
                try await self.loadModelIfAvailable()
            }
        } else {
            loadedModel = try await loadModelIfAvailable()
        }
        defer { withExtendedLifetime(loadedModel) {} }
        let model = loadedModel.model
        let config = model.config
        let policy = try MeetingSpeakerFeedPolicy(
            sampleRate: config.processorConfig.samplingRate,
            hopLength: config.processorConfig.hopLength,
            subsamplingFactor: config.fcEncoderConfig.subsamplingFactor,
            chunkFrames: config.modulesConfig.chunkLen,
            cacheFrames: config.modulesConfig.spkcacheLen,
            updateFrames: config.modulesConfig.spkcacheUpdatePeriod,
            usesAOSC: config.modulesConfig.useAosc
        )
        var state = model.initStreamingState()
        var previousDescriptor: MeetingAudioAssetDescriptor?
        var turns: [MeetingSpeakerTurn] = []
        let descriptorCount = max(descriptors.count, 1)
        await progress?(0)

        for (index, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()
            if let previousDescriptor {
                let expectedStart = previousDescriptor.sessionStartOffset + previousDescriptor.durationSeconds
                let isContinuous = descriptor.source == previousDescriptor.source
                    && abs(descriptor.sessionStartOffset - expectedStart) < 0.05
                if !isContinuous { state = model.initStreamingState() }
            }
            previousDescriptor = descriptor
            guard let asset = await loadAsset(descriptor) else { throw MeetingSpeakerFeedError.audioUnavailable }
            let prepared = fileAnalysis && asset.sampleRate == 16_000
                ? asset.samples
                : ASRVoiceActivitySampleRateConverter.resample(samples: asset.samples, from: asset.sampleRate, to: 16_000)
            guard !prepared.isEmpty else { throw MeetingSpeakerFeedError.audioUnavailable }

            var offset = 0
            while offset < prepared.count {
                try Task.checkCancellation()
                try policy.validate(fifoFrames: state.fifoLen, cacheFrames: state.spkcacheLen)
                let end = min(offset + policy.samplesPerFeed, prepared.count)
                let samples = Array(prepared[offset..<end])
                let inputState = state
                let audioOffset = asset.sessionStartOffset + Double(offset) / Double(policy.sampleRate)
                let result: (DiarizationOutput, StreamingState)
                if fileAnalysis {
                    result = try await MeetingLocalInferenceCoordinator.shared.withPermit(.fileSpeakerAnalysis) {
                        try await self.feed(model: model, samples: samples, state: inputState, policy: policy, enforceTimeLimit: true)
                    }
                } else {
                    result = try await feed(model: model, samples: samples, state: inputState, policy: policy)
                }
                try Task.checkCancellation()
                let (output, newState) = result
                try policy.validate(fifoFrames: newState.fifoLen, cacheFrames: newState.spkcacheLen)
                state = newState
                // Note (Omni): anchor each feed to real PCM so feature padding cannot accumulate timeline drift.
                turns.append(contentsOf: output.segments.compactMap { item in
                    guard let range = policy.mappedRange(
                        start: Double(item.start), end: Double(item.end),
                        stateFrames: inputState.framesProcessed, audioOffset: audioOffset, sampleCount: samples.count
                    ) else { return nil }
                    return MeetingSpeakerTurn(
                        source: asset.source, speakerID: "sortformer-\(item.speaker)",
                        displayName: MeetingSpeakerDisplayNameFormatter.displayName(ordinal: item.speaker + 1),
                        startSeconds: range.lowerBound, endSeconds: range.upperBound, confidence: nil
                    )
                })
                offset = end
                await progress?((Double(index) + Double(offset) / Double(prepared.count)) / Double(descriptorCount))
            }
        }
        return turns
    }

    private func feed(
        model: SortformerModel, samples: [Float], state: StreamingState,
        policy: MeetingSpeakerFeedPolicy, enforceTimeLimit: Bool = false
    ) async throws -> (DiarizationOutput, StreamingState) {
        var padded = samples
        if padded.count < policy.frameSamples {
            padded.append(contentsOf: repeatElement(0, count: policy.frameSamples - padded.count))
        }
        let startedAt = ContinuousClock.now
        let result = try await model.feed(
            chunk: MLXArray(padded), state: state, sampleRate: policy.sampleRate,
            threshold: 0.5, minDuration: 0, mergeGap: 0.18,
            spkcacheMax: policy.cacheMaximumFrames, fifoMax: MeetingSpeakerFeedPolicy.fifoMaximumFrames
        )
        try Task.checkCancellation()
        if enforceTimeLimit { try policy.validateFeedDuration(startedAt.duration(to: .now)) }
        return result
    }

    private func loadModelIfAvailable() async throws -> MeetingSortformerModelLease {
        if let loadedModel { return loadedModel }
        guard let directoryLease = try await MeetingSortformerModelStorage.validatedModelDirectoryLease() else {
            throw MeetingVADModelError.modelNotDownloaded
        }
        try Task.checkCancellation()
        if let loadedModel { return loadedModel }
        let loaded = try MeetingSortformerModelLease(directoryLease: directoryLease)
        loadedModel = loaded
        return loaded
    }
}
