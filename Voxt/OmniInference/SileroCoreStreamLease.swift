/// Retains the stream handle and model lease until checked Native destruction succeeds.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class SileroCoreStreamLease: @unchecked Sendable {
    let model: SileroCoreModel
    private let modelHandle: OpaquePointer
    private let handleLock = NSLock()
    private var handle: OpaquePointer?
    private var cancellationRequested = false
    // note (assistant): Only the serial Silero queue creates, commands, and destroys a lease.
    private var isDestroyed = false

    init(model: SileroCoreModel) {
        self.model = model
        modelHandle = model.registerStreamLease()
    }

    func create() throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        // note (assistant): Native creation may wait for Feed; never hold the model token lock here.
        let created = omni_silero_stream_create(modelHandle, &errorMessage)
        handleLock.withLock {
            precondition(handle == nil && !isDestroyed)
            handle = created
            if cancellationRequested, let created { omni_silero_stream_cancel(created) }
        }
        guard created != nil, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Silero stream could not be created.")
        }
    }

    func cancel() {
        handleLock.withLock {
            cancellationRequested = true
            if let handle { omni_silero_stream_cancel(handle) }
        }
    }

    func push(
        samples: [Float], sequence: Int, previousProcessedSampleCount: UInt64, expectedProcessedSampleCount: UInt64
    ) throws -> [Float] {
        precondition(sequence > 0 && samples.count <= OmniXPCSileroLimits.maximumChunkSampleCount)
        var result = OmniSileroStreamResult()
        var acceptedSequence: UInt64 = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            omni_silero_stream_result_free(&result)
            omni_string_free(errorMessage)
        }
        let nativeHandle = try commandHandle()
        let status = samples.withUnsafeBufferPointer { buffer in
            omni_silero_stream_push(
                nativeHandle, UInt64(sequence), buffer.baseAddress, buffer.count,
                &acceptedSequence, &result, &errorMessage
            )
        }
        guard status == 1, errorMessage == nil, acceptedSequence == UInt64(sequence) else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Silero stream processing failed.")
        }
        return try copyProbabilities(
            result, previousProcessedSampleCount: previousProcessedSampleCount,
            expectedProcessedSampleCount: expectedProcessedSampleCount,
            maximumProbabilityCount: OmniXPCSileroLimits.maximumProbabilityCount
        )
    }

    func finish(previousProcessedSampleCount: UInt64, expectedProcessedSampleCount: UInt64) throws -> [Float] {
        var result = OmniSileroStreamResult()
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            omni_silero_stream_result_free(&result)
            omni_string_free(errorMessage)
        }
        let status = omni_silero_stream_finish(try commandHandle(), &result, &errorMessage)
        guard status == 1, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Silero stream finalization failed.")
        }
        return try copyProbabilities(
            result, previousProcessedSampleCount: previousProcessedSampleCount,
            expectedProcessedSampleCount: expectedProcessedSampleCount, maximumProbabilityCount: 1
        )
    }

    func drainAndDestroy() throws {
        guard !isDestroyed else { return }
        try handleLock.withLock {
            guard let handle else { return }
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer { omni_string_free(errorMessage) }
            guard omni_silero_stream_destroy_checked(handle, &errorMessage) == 1 else {
                throw OmniXPCFailure.error(.nativeFailure, "The Native Silero stream destruction did not complete.")
            }
            self.handle = nil
        }
        isDestroyed = true
        model.releaseStreamLease()
    }

    private func commandHandle() throws -> OpaquePointer {
        try handleLock.withLock {
            guard let handle else {
                throw OmniXPCFailure.error(.invalidRequest, "The Native Silero stream is not active.")
            }
            return handle
        }
    }

    private func copyProbabilities(
        _ result: OmniSileroStreamResult, previousProcessedSampleCount: UInt64,
        expectedProcessedSampleCount: UInt64, maximumProbabilityCount: Int
    ) throws -> [Float] {
        let frameSampleCount = UInt64(OmniXPCSileroLimits.frameSampleCount)
        guard result.probability_count >= 0, result.probability_count <= maximumProbabilityCount,
              result.processed_sample_count == expectedProcessedSampleCount,
              result.processed_sample_count % frameSampleCount == 0,
              result.processed_sample_count >= previousProcessedSampleCount,
              (result.processed_sample_count - previousProcessedSampleCount) / frameSampleCount
                == UInt64(result.probability_count),
              result.probability_count == 0 || result.probabilities != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Silero returned invalid probability counters.")
        }
        guard result.probability_count > 0 else { return [] }
        let probabilities = result.probabilities!
        for index in 0..<result.probability_count {
            guard probabilities[index].isFinite, (0...1).contains(probabilities[index]) else {
                throw OmniXPCFailure.error(.nativeFailure, "Native Silero returned an invalid probability.")
            }
        }
        return Array(UnsafeBufferPointer(start: probabilities, count: result.probability_count))
    }

    deinit { precondition(isDestroyed && handle == nil) }
}
#endif
