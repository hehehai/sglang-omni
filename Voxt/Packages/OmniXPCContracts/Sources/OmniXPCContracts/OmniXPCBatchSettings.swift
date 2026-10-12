import Foundation

public nonisolated enum OmniXPCBatchSettings: Equatable, Sendable, Codable {
    case whisper(language: String? = nil, maximumTokenCount: Int = 0, temperature: Float = 0)
    case cohere(language: String? = nil, usePunctuation: Bool = true, maximumTokenCount: Int = 0,
                temperature: Float = 0, chunkDurationSeconds: Float = 1200, minimumChunkDurationSeconds: Float = 1)
    case moss(prompt: String? = nil, maximumTokenCount: Int? = nil, stopAtEndOfText: Bool = false, stopOnTokenLoop: Bool = false)
    case nemotron(language: String? = nil, chunkFrameCount: Int? = nil)
    case parakeet(chunkDurationSeconds: Double = 1200)
    case sensevoice(language: String? = nil, useInverseTextNormalization: Bool = false)

    public var kind: OmniXPCBatchKind {
        switch self {
        case .whisper: .whisper
        case .cohere: .cohere
        case .moss: .moss
        case .nemotron: .nemotron
        case .parakeet: .parakeet
        case .sensevoice: .sensevoice
        }
    }

    public static func defaults(for kind: OmniXPCBatchKind) -> Self {
        switch kind {
        case .whisper: .whisper()
        case .cohere: .cohere()
        case .moss: .moss()
        case .nemotron: .nemotron()
        case .parakeet: .parakeet()
        case .sensevoice: .sensevoice()
        }
    }

    public func validate() throws {
        let language: String?
        let valid: Bool
        switch self {
        case let .whisper(value, maximumTokenCount, temperature):
            language = value
            valid = (0...4096).contains(maximumTokenCount) && temperature.isFinite && temperature >= 0
        case let .cohere(value, _, maximumTokenCount, temperature, chunkDurationSeconds, minimumChunkDurationSeconds):
            language = value
            valid = (0...4096).contains(maximumTokenCount) && temperature.isFinite && temperature >= 0
                && chunkDurationSeconds.isFinite && (1...1200).contains(chunkDurationSeconds)
                && minimumChunkDurationSeconds.isFinite && (0...30).contains(minimumChunkDurationSeconds)
                && minimumChunkDurationSeconds <= chunkDurationSeconds
        case let .moss(prompt, maximumTokenCount, _, _):
            language = nil
            try BatchWireField.validateString(prompt, maximumByteCount: OmniXPCBatchLimits.maximumPromptByteCount)
            valid = maximumTokenCount == nil || (0...4096).contains(maximumTokenCount!)
        case let .nemotron(value, chunkFrameCount):
            language = value
            valid = chunkFrameCount == nil || (1...4096).contains(chunkFrameCount!)
        case let .parakeet(chunkDurationSeconds):
            language = nil
            valid = chunkDurationSeconds.isFinite
                && ((2...300).contains(chunkDurationSeconds) || (1199...1200).contains(chunkDurationSeconds))
        case let .sensevoice(value, _):
            language = value
            valid = true
        }
        try BatchWireField.validateString(language, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount)
        guard valid else { throw OmniXPCFailure.error(.invalidRequest, "The batch settings exceed validation limits.") }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, language, maximumTokenCount, temperature, usePunctuation, chunkDurationSeconds
        case minimumChunkDurationSeconds, prompt, stopAtEndOfText, stopOnTokenLoop, chunkFrameCount
        case useInverseTextNormalization
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(OmniXPCBatchKind.self, forKey: .kind)
        switch kind {
        case .whisper:
            try BatchWireField.require(decoder, fields: ["kind", "language", "maximumTokenCount", "temperature"])
            self = try .whisper(language: values.decodeIfPresent(String.self, forKey: .language),
                                maximumTokenCount: values.decode(Int.self, forKey: .maximumTokenCount),
                                temperature: values.decode(Float.self, forKey: .temperature))
        case .cohere:
            try BatchWireField.require(decoder, fields: ["kind", "language", "usePunctuation", "maximumTokenCount",
                                                        "temperature", "chunkDurationSeconds", "minimumChunkDurationSeconds"])
            self = try .cohere(language: values.decodeIfPresent(String.self, forKey: .language),
                               usePunctuation: values.decode(Bool.self, forKey: .usePunctuation),
                               maximumTokenCount: values.decode(Int.self, forKey: .maximumTokenCount),
                               temperature: values.decode(Float.self, forKey: .temperature),
                               chunkDurationSeconds: values.decode(Float.self, forKey: .chunkDurationSeconds),
                               minimumChunkDurationSeconds: values.decode(Float.self, forKey: .minimumChunkDurationSeconds))
        case .moss:
            try BatchWireField.require(decoder, fields: ["kind", "prompt", "maximumTokenCount", "stopAtEndOfText", "stopOnTokenLoop"])
            self = try .moss(prompt: values.decodeIfPresent(String.self, forKey: .prompt),
                             maximumTokenCount: values.decodeIfPresent(Int.self, forKey: .maximumTokenCount),
                             stopAtEndOfText: values.decode(Bool.self, forKey: .stopAtEndOfText),
                             stopOnTokenLoop: values.decode(Bool.self, forKey: .stopOnTokenLoop))
        case .nemotron:
            try BatchWireField.require(decoder, fields: ["kind", "language", "chunkFrameCount"])
            self = try .nemotron(language: values.decodeIfPresent(String.self, forKey: .language),
                                 chunkFrameCount: values.decodeIfPresent(Int.self, forKey: .chunkFrameCount))
        case .parakeet:
            try BatchWireField.require(decoder, fields: ["kind", "chunkDurationSeconds"])
            self = try .parakeet(chunkDurationSeconds: values.decode(Double.self, forKey: .chunkDurationSeconds))
        case .sensevoice:
            try BatchWireField.require(decoder, fields: ["kind", "language", "useInverseTextNormalization"])
            self = try .sensevoice(language: values.decodeIfPresent(String.self, forKey: .language),
                                   useInverseTextNormalization: values.decode(Bool.self, forKey: .useInverseTextNormalization))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case let .whisper(language, maximumTokenCount, temperature):
            try values.encode(language, forKey: .language)
            try values.encode(maximumTokenCount, forKey: .maximumTokenCount)
            try values.encode(temperature, forKey: .temperature)
        case let .cohere(language, usePunctuation, maximumTokenCount, temperature, chunkDurationSeconds, minimumChunkDurationSeconds):
            try values.encode(language, forKey: .language)
            try values.encode(usePunctuation, forKey: .usePunctuation)
            try values.encode(maximumTokenCount, forKey: .maximumTokenCount)
            try values.encode(temperature, forKey: .temperature)
            try values.encode(chunkDurationSeconds, forKey: .chunkDurationSeconds)
            try values.encode(minimumChunkDurationSeconds, forKey: .minimumChunkDurationSeconds)
        case let .moss(prompt, maximumTokenCount, stopAtEndOfText, stopOnTokenLoop):
            try values.encode(prompt, forKey: .prompt)
            try values.encode(maximumTokenCount, forKey: .maximumTokenCount)
            try values.encode(stopAtEndOfText, forKey: .stopAtEndOfText)
            try values.encode(stopOnTokenLoop, forKey: .stopOnTokenLoop)
        case let .nemotron(language, chunkFrameCount):
            try values.encode(language, forKey: .language)
            try values.encode(chunkFrameCount, forKey: .chunkFrameCount)
        case let .parakeet(chunkDurationSeconds):
            try values.encode(chunkDurationSeconds, forKey: .chunkDurationSeconds)
        case let .sensevoice(language, useInverseTextNormalization):
            try values.encode(language, forKey: .language)
            try values.encode(useInverseTextNormalization, forKey: .useInverseTextNormalization)
        }
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= OmniXPCBatchLimits.maximumSettingsByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch settings exceed their byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCBatchLimits.maximumSettingsByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch settings exceed their byte limit.")
        }
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The batch settings are invalid.")
        }
    }
}
