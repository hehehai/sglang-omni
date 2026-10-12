import Foundation

public nonisolated enum OmniXPCSpeakerSettings: Codable, Equatable, Sendable {
    case moss(prompt: String? = nil)
    case nemotron(language: String? = nil, chunkMilliseconds: Double? = nil)

    public var kind: OmniXPCSpeakerKind {
        switch self {
        case .moss: .moss
        case .nemotron: .nemotron
        }
    }

    public static func defaults(for kind: OmniXPCSpeakerKind) -> Self {
        switch kind {
        case .moss: .moss()
        case .nemotron: .nemotron()
        }
    }

    public func validate(for model: OmniXPCSpeakerModelReference) throws {
        guard kind == model.kind else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker settings do not match the model family.")
        }
        try validate()
    }

    public func validate() throws {
        switch self {
        case let .moss(prompt):
            try SpeakerWireField.validateString(prompt, maximumByteCount: OmniXPCSpeakerLimits.maximumPromptByteCount)
            guard (prompt?.components(separatedBy: "<|audio_pad|>").count ?? 1) <= 2 else {
                throw OmniXPCFailure.error(.invalidRequest, "The speaker prompt has multiple audio placeholders.")
            }
        case let .nemotron(language, chunkMilliseconds):
            try SpeakerWireField.validateString(language, maximumByteCount: OmniXPCSpeakerLimits.maximumMetadataByteCount)
            guard chunkMilliseconds.map({
                $0.isFinite && $0 > 0 && $0 <= OmniXPCSpeakerLimits.maximumChunkMilliseconds
            }) ?? true else {
                throw OmniXPCFailure.error(.invalidRequest, "The speaker chunk duration exceeds validation limits.")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, prompt, language, chunkMilliseconds }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(OmniXPCSpeakerKind.self, forKey: .kind)
        switch kind {
        case .moss:
            try SpeakerWireField.require(decoder, fields: ["kind", "prompt"])
            self = try .moss(prompt: values.decodeIfPresent(String.self, forKey: .prompt))
        case .nemotron:
            try SpeakerWireField.require(decoder, fields: ["kind", "language", "chunkMilliseconds"])
            self = try .nemotron(language: values.decodeIfPresent(String.self, forKey: .language),
                                chunkMilliseconds: values.decodeIfPresent(Double.self, forKey: .chunkMilliseconds))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case let .moss(prompt):
            try values.encode(prompt, forKey: .prompt)
        case let .nemotron(language, chunkMilliseconds):
            try values.encode(language, forKey: .language)
            try values.encode(chunkMilliseconds, forKey: .chunkMilliseconds)
        }
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumSettingsByteCount)
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumSettingsByteCount)
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker settings are invalid.")
        }
    }
}
