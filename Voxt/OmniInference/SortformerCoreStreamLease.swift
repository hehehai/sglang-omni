/// Owns an ABI6 stream through cancellation and checked Native drain/destruction.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class SortformerCoreStreamLease: @unchecked Sendable {
    let model: SortformerCoreModel
    private let modelHandle: OpaquePointer
    private let handleCondition = NSCondition()
    private var handle: OpaquePointer?
    private var cancellationRequested = false
    private var cancellationCallCount = 0
    // note (assistant): Only the dedicated serial queue creates, commands, and destroys this lease.
    private var isDestroyed = false

    init(model: SortformerCoreModel) {
        self.model = model
        modelHandle = model.registerStreamLease()
    }

    func create(settings: OmniXPCSortformerSettings) throws {
        var nativeSettings = OmniSortformerSettings(
            threshold: settings.threshold,
            minimum_duration_seconds: settings.minimumDurationSeconds,
            merge_gap_seconds: settings.mergeGapSeconds,
            speaker_cache_max_frames: Int32(settings.speakerCacheMaximumFrameCount),
            fifo_max_frames: Int32(settings.fifoMaximumFrameCount)
        )
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        let created = omni_sortformer_stream_create(modelHandle, &nativeSettings, &errorMessage)
        let shouldCancel = handleCondition.withLock {
            precondition(handle == nil && !isDestroyed)
            handle = created
            return cancellationRequested
        }
        if shouldCancel { cancel() }
        guard created != nil, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Sortformer stream could not be created.")
        }
    }

    func cancel() {
        let cancellingHandle = handleCondition.withLock { () -> OpaquePointer? in
            cancellationRequested = true
            guard let handle else { return nil }
            cancellationCallCount += 1
            return handle
        }
        guard let cancellingHandle else { return }
        // note (assistant): Pin raw calls rather than hold a lock across Native cancellation or reentrancy.
        omni_sortformer_stream_cancel(cancellingHandle)
        handleCondition.withLock {
            cancellationCallCount -= 1
            handleCondition.broadcast()
        }
    }

    func push(
        samples: [Float], sequence: Int, previousProcessedFrameCount: UInt64, expectedProcessedFrameCount: UInt64,
        serviceInstanceID: UUID, modelID: UUID, streamID: UUID
    ) throws -> OmniXPCSortformerProbabilityBatch {
        precondition(sequence > 0 && !samples.isEmpty && samples.count <= OmniXPCSortformerLimits.maximumChunkSampleCount)
        var result = OmniSortformerResult()
        var acceptedSequence: UInt64 = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            omni_sortformer_result_free(&result)
            omni_string_free(errorMessage)
        }
        let nativeHandle = try commandHandle()
        let status = samples.withUnsafeBufferPointer { buffer in
            omni_sortformer_stream_push(
                nativeHandle, UInt64(sequence), buffer.baseAddress, buffer.count,
                &acceptedSequence, &result, &errorMessage
            )
        }
        guard status == 1, errorMessage == nil, acceptedSequence == UInt64(sequence) else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Sortformer stream processing failed.")
        }
        let frameCount = Int(result.frame_count)
        let speakerCount = Int(result.speaker_count)
        guard (1...OmniXPCSortformerLimits.maximumChunkFrameCount).contains(frameCount),
              speakerCount == OmniXPCSortformerLimits.speakerCount,
              result.probability_count == frameCount * speakerCount,
              result.processed_frame_count == expectedProcessedFrameCount,
              expectedProcessedFrameCount <= OmniXPCSortformerLimits.maximumProcessedFrameCount,
              expectedProcessedFrameCount >= previousProcessedFrameCount,
              expectedProcessedFrameCount - previousProcessedFrameCount == UInt64(frameCount),
              result.frame_duration_seconds == OmniXPCSortformerLimits.frameDurationSeconds,
              result.segment_count >= 0, result.segment_count <= OmniXPCSortformerLimits.maximumSegmentCount,
              let nativeProbabilities = result.probabilities,
              result.segment_count == 0 || result.segments != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Sortformer returned invalid output counters.")
        }
        for index in 0..<result.probability_count {
            let probability = nativeProbabilities[index]
            guard probability.isFinite, (0...1).contains(probability) else {
                throw OmniXPCFailure.error(.nativeFailure, "Native Sortformer returned an invalid probability.")
            }
        }
        // note (assistant): ABI5 segment bounds retain Native Float rounding before widening to seconds.
        let startSeconds = Float(previousProcessedFrameCount) * Float(result.frame_duration_seconds)
        let endSeconds = Float(frameCount) * Float(result.frame_duration_seconds) + startSeconds
        var previousStartSeconds = Double(startSeconds)
        for index in 0..<result.segment_count {
            let segment = result.segments![index]
            guard segment.start_seconds.isFinite, segment.end_seconds.isFinite,
                  segment.start_seconds >= previousStartSeconds,
                  segment.end_seconds >= segment.start_seconds, segment.end_seconds <= Double(endSeconds),
                  (0..<speakerCount).contains(Int(segment.speaker_index)) else {
                throw OmniXPCFailure.error(.nativeFailure, "Native Sortformer returned invalid segment ranges.")
            }
            previousStartSeconds = segment.start_seconds
        }
        let probabilities = Array(UnsafeBufferPointer(start: nativeProbabilities, count: result.probability_count))
        let segments = try (0..<result.segment_count).map { index in
            let segment = result.segments![index]
            return try OmniXPCSortformerSegment(
                startSeconds: segment.start_seconds, endSeconds: segment.end_seconds,
                speakerIndex: Int(segment.speaker_index)
            )
        }
        return try OmniXPCSortformerProbabilityBatch(
            serviceInstanceID: serviceInstanceID, modelID: modelID, streamID: streamID,
            audioSequence: sequence, processedFrameCount: expectedProcessedFrameCount,
            frameCount: frameCount, speakerCount: speakerCount, frameDurationSeconds: result.frame_duration_seconds,
            probabilities: probabilities, segments: segments
        )
    }

    func finish() throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        guard omni_sortformer_stream_finish(try commandHandle(), &errorMessage) == 1, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Sortformer stream finalization failed.")
        }
    }

    func drainAndDestroy() throws {
        guard !isDestroyed else { return }
        if let nativeHandle = handleCondition.withLock({ handle }) {
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer { omni_string_free(errorMessage) }
            guard omni_sortformer_stream_drain(nativeHandle, &errorMessage) == 1, errorMessage == nil else {
                throw OmniXPCFailure.error(.nativeFailure, "The Native Sortformer stream barrier did not drain.")
            }
            handleCondition.lock()
            handle = nil
            while cancellationCallCount > 0 { handleCondition.wait() }
            handleCondition.unlock()
            guard omni_sortformer_stream_destroy_checked(nativeHandle, &errorMessage) == 1, errorMessage == nil else {
                handleCondition.withLock { handle = nativeHandle }
                throw OmniXPCFailure.error(.nativeFailure, "The Native Sortformer stream destruction did not complete.")
            }
        }
        isDestroyed = true
        model.releaseStreamLease()
    }

    private func commandHandle() throws -> OpaquePointer {
        try handleCondition.withLock {
            guard let handle else {
                throw OmniXPCFailure.error(.invalidRequest, "The Native Sortformer stream is not active.")
            }
            return handle
        }
    }

    deinit { precondition(isDestroyed && handle == nil && cancellationCallCount == 0) }
}
#endif
