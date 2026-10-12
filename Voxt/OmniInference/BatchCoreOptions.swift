import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension BatchCoreRequest {
    func transcribeNative(samples: [Float], settings: OmniXPCBatchSettings, result: inout OmniBatchResult) throws {
        try settings.validate()
        guard settings.kind == model.kind else { throw OmniXPCBatchFailure.error(.invalid) }
        let optionalString: String?
        switch settings {
        case let .whisper(language, _, _), let .cohere(language, _, _, _, _, _),
             let .nemotron(language, _), let .sensevoice(language, _): optionalString = language
        case let .moss(prompt, _, _, _): optionalString = prompt
        case .parakeet: optionalString = nil
        }
        let requestHandle = try commandHandle()
        func invoke(_ string: UnsafePointer<CChar>?) throws {
            var options = OmniBatchOptions()
            try BatchCoreModel.check(omni_batch_options_default(Int32(model.kind.rawValue), &options))
            switch settings {
            case let .whisper(_, maximumTokenCount, temperature):
                options.family.whisper.language = string
                options.family.whisper.maximum_token_count = Int32(maximumTokenCount)
                options.family.whisper.temperature = temperature
            case let .cohere(_, usePunctuation, maximumTokenCount, temperature, chunkDurationSeconds, minimumChunkDurationSeconds):
                options.family.cohere.language = string
                options.family.cohere.use_punctuation = usePunctuation ? 1 : 0
                options.family.cohere.maximum_token_count = Int32(maximumTokenCount)
                options.family.cohere.temperature = temperature
                options.family.cohere.chunk_duration_seconds = chunkDurationSeconds
                options.family.cohere.minimum_chunk_duration_seconds = minimumChunkDurationSeconds
            case let .moss(_, maximumTokenCount, stopAtEndOfText, stopOnTokenLoop):
                options.family.moss.prompt = string
                options.family.moss.maximum_token_count = Int32(maximumTokenCount ?? -1)
                options.family.moss.stop_at_end_of_text = stopAtEndOfText ? 1 : 0
                options.family.moss.stop_on_token_loop = stopOnTokenLoop ? 1 : 0
            case let .nemotron(_, chunkFrameCount):
                options.family.nemotron.language = string
                options.family.nemotron.chunk_frame_count = Int32(chunkFrameCount ?? 0)
            case let .parakeet(chunkDurationSeconds):
                options.family.parakeet.chunk_duration_seconds = chunkDurationSeconds
            case let .sensevoice(_, useInverseTextNormalization):
                options.family.sensevoice.language = string
                options.family.sensevoice.use_inverse_text_normalization = useInverseTextNormalization ? 1 : 0
            }
            let status = samples.withUnsafeBufferPointer {
                omni_batch_transcribe(requestHandle, $0.baseAddress, $0.count, &options, &result)
            }
            try BatchCoreModel.check(status)
        }
        if let optionalString { try optionalString.withCString(invoke) } else { try invoke(nil) }
    }
}
#endif
