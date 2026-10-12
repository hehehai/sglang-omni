import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class BatchCoreRequest: @unchecked Sendable {
    let model: BatchCoreModel
    private let condition = NSCondition()
    private var handle: OpaquePointer?
    private var cancellationRequested = false
    private var cancellationCallCount = 0
    private var isDestroyed = false

    init(model: BatchCoreModel) { self.model = model }

    func create() throws {
        let created = try model.createRequest()
        let shouldCancel = condition.withLock {
            precondition(handle == nil && !isDestroyed)
            handle = created
            return cancellationRequested
        }
        if shouldCancel { cancel() }
    }

    func cancel() {
        let cancellingHandle = condition.withLock { () -> OpaquePointer? in
            cancellationRequested = true
            guard let handle else { return nil }
            cancellationCallCount += 1
            return handle
        }
        guard let cancellingHandle else { return }
        // note (assistant): Pin cancellation outside the command queue so nonpreemptible inference cannot delay the signal.
        omni_batch_request_cancel(cancellingHandle)
        condition.withLock {
            cancellationCallCount -= 1
            condition.broadcast()
        }
    }

    func commandHandle() throws -> OpaquePointer {
        try condition.withLock {
            guard let handle else { throw OmniXPCBatchFailure.error(.invalid) }
            return handle
        }
    }

    func drainAndDestroy() throws {
        guard !isDestroyed else { return }
        if let nativeHandle = condition.withLock({ handle }) {
            try BatchCoreModel.check(omni_batch_request_drain(nativeHandle))
            condition.lock()
            handle = nil
            while cancellationCallCount > 0 { condition.wait() }
            condition.unlock()
            let status = omni_batch_request_destroy_checked(nativeHandle)
            guard status == OMNI_BATCH_OK else {
                condition.withLock { handle = nativeHandle }
                try BatchCoreModel.check(status)
                return
            }
            model.releaseRequest()
        }
        isDestroyed = true
    }

    func transcribe(samples: [Float], settings: OmniXPCBatchSettings,
                    serviceInstanceID: UUID, modelID: UUID, requestID: UUID) throws -> OmniXPCBatchResult {
        var result = OmniBatchResult()
        defer { omni_batch_result_free(&result) }
        try transcribeNative(samples: samples, settings: settings, result: &result)
        guard result.segment_count >= 0, result.segment_count <= OmniXPCBatchLimits.maximumSegmentCount,
              (0...OmniXPCProtocolLimits.maximumTokenCount).contains(Int(result.generated_token_count)),
              result.segment_count == 0 || result.segments != nil,
              let finishReason = OmniXPCBatchResult.FinishReason(rawValue: Int(result.finish_reason)) else {
            throw OmniXPCBatchFailure.error(.failed)
        }
        var stringByteCount = 0
        func string(_ pointer: UnsafeMutablePointer<CChar>?, maximumByteCount: Int, required: Bool = false) throws -> String? {
            guard let pointer else {
                guard !required else { throw OmniXPCBatchFailure.error(.failed) }
                return nil
            }
            var byteCount = 0
            while byteCount <= maximumByteCount, pointer[byteCount] != 0 { byteCount += 1 }
            guard byteCount <= maximumByteCount else { throw OmniXPCBatchFailure.error(.limit) }
            stringByteCount += byteCount + 1
            guard stringByteCount <= OmniXPCBatchLimits.maximumResultStringByteCount,
                  let value = String(bytes: UnsafeRawBufferPointer(start: pointer, count: byteCount), encoding: .utf8) else {
                throw OmniXPCBatchFailure.error(.failed)
            }
            return value
        }
        let text = try string(result.text, maximumByteCount: OmniXPCBatchLimits.maximumTextByteCount, required: true)!
        let language = try string(result.language, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount)
        var segments: [OmniXPCBatchSegment] = []
        for index in 0..<result.segment_count {
            let segment = result.segments![index]
            segments.append(try OmniXPCBatchSegment(
                startSeconds: segment.start_seconds, endSeconds: segment.end_seconds,
                text: string(segment.text, maximumByteCount: OmniXPCBatchLimits.maximumTextByteCount, required: true)!,
                speaker: string(segment.speaker, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount),
                language: string(segment.language, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount),
                emotion: string(segment.emotion, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount),
                event: string(segment.event, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount)
            ))
        }
        return try OmniXPCBatchResult(
            serviceInstanceID: serviceInstanceID, modelID: modelID, requestID: requestID, kind: model.kind,
            text: text, language: language, generatedTokenCount: Int(result.generated_token_count),
            finishReason: finishReason, segments: segments
        )
    }

    deinit { precondition(isDestroyed && handle == nil && cancellationCallCount == 0) }
}
#endif
