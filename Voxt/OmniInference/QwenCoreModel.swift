/// Retained Native model with a separately cancellable token for each final request.
import Foundation

#if os(macOS)
nonisolated struct QwenReply: Sendable {
    let text: String
    let language: String?
    let generatedTokenCount: Int
    let hitLengthLimit: Bool
}

nonisolated final class QwenCoreModel: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var request: OpaquePointer?

    init(directory: URL) throws {
        guard Int(omni_core_abi_version()) == OmniXPCProtocolLimits.abiVersion else {
            throw OmniXPCFailure.error(.incompatibleService, "The Native Core ABI is incompatible.")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        handle = omni_qwen_create(directory.path, &errorMessage)
        defer { omni_string_free(errorMessage) }
        guard handle != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Qwen model could not be loaded.")
        }
    }

    func prepareRequest() throws {
        try lock.withLock {
            precondition(handle != nil && request == nil)
            guard let token = omni_qwen_request_create() else {
                throw OmniXPCFailure.error(.nativeFailure, "The Native Qwen request could not be created.")
            }
            request = token
        }
    }

    func cancelRequest() {
        lock.withLock {
            guard let request else { return }
            omni_qwen_request_cancel(request)
        }
    }

    func transcribe(samples: [Float], language: String?, context: String?, maximumTokenCount: Int) throws -> QwenReply {
        let (modelHandle, requestToken) = lock.withLock {
            precondition(handle != nil && request != nil)
            return (handle!, request!)
        }
        defer {
            lock.withLock {
                omni_qwen_request_destroy(requestToken)
                request = nil
            }
        }
        var result = OmniQwenResult()
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            omni_qwen_result_free(&result)
            omni_string_free(errorMessage)
        }
        let success = withOptionalCString(language) { languagePointer in
            withOptionalCString(context) { contextPointer in
                samples.withUnsafeBufferPointer { buffer in
                    omni_qwen_transcribe_request(
                        modelHandle, requestToken, buffer.baseAddress, buffer.count,
                        languagePointer, contextPointer, Int32(maximumTokenCount), &result, &errorMessage
                    )
                }
            }
        }
        guard success == 1, let textPointer = result.text,
              result.generated_token_count >= 0, Int(result.generated_token_count) <= maximumTokenCount,
              result.hit_length_limit == 0 || result.hit_length_limit == 1 else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Qwen transcription failed.")
        }
        return QwenReply(
            text: String(cString: textPointer),
            language: result.language.map { String(cString: $0) },
            generatedTokenCount: Int(result.generated_token_count),
            hitLengthLimit: result.hit_length_limit == 1
        )
    }

    private func withOptionalCString(_ value: String?, operation: (UnsafePointer<CChar>?) -> Int32) -> Int32 {
        if let value {
            return value.withCString(operation)
        } else {
            return operation(nil)
        }
    }

    func close() {
        lock.withLock {
            precondition(request == nil)
            guard let handle else { return }
            self.handle = nil
            omni_qwen_destroy(handle)
        }
    }

    deinit { close() }
}
#endif
