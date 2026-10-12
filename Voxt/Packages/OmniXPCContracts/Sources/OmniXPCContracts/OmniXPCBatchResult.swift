import Foundation

public nonisolated struct OmniXPCBatchSegment: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let speaker: String?
    public let language: String?
    public let emotion: String?
    public let event: String?

    public init(startSeconds: Double, endSeconds: Double, text: String,
                speaker: String?, language: String?, emotion: String?, event: String?) throws {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speaker = speaker
        self.language = language
        self.emotion = emotion
        self.event = event
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case startSeconds, endSeconds, text, speaker, language, emotion, event
    }

    public init(from decoder: any Decoder) throws {
        try BatchWireField.require(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(startSeconds: values.decode(Double.self, forKey: .startSeconds),
                      endSeconds: values.decode(Double.self, forKey: .endSeconds),
                      text: values.decode(String.self, forKey: .text),
                      speaker: values.decodeIfPresent(String.self, forKey: .speaker),
                      language: values.decodeIfPresent(String.self, forKey: .language),
                      emotion: values.decodeIfPresent(String.self, forKey: .emotion),
                      event: values.decodeIfPresent(String.self, forKey: .event))
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(startSeconds, forKey: .startSeconds)
        try values.encode(endSeconds, forKey: .endSeconds)
        try values.encode(text, forKey: .text)
        try values.encode(speaker, forKey: .speaker)
        try values.encode(language, forKey: .language)
        try values.encode(emotion, forKey: .emotion)
        try values.encode(event, forKey: .event)
    }

    public func validate() throws {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds >= startSeconds else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch segment time range is invalid.")
        }
        try BatchWireField.validateString(text, maximumByteCount: OmniXPCBatchLimits.maximumTextByteCount)
        for string in [speaker, language, emotion, event] {
            try BatchWireField.validateString(string, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount)
        }
    }

    var stringByteCount: Int {
        [text, speaker, language, emotion, event].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count + 1 }
    }
}

public nonisolated struct OmniXPCBatchResult: Codable, Equatable, Sendable {
    public enum FinishReason: Int, Codable, Sendable { case stop = 0, length = 1 }
    public let serviceInstanceID: UUID
    public let modelID: UUID
    public let requestID: UUID
    public let kind: OmniXPCBatchKind
    public let text: String
    public let language: String?
    public let generatedTokenCount: Int
    public let finishReason: FinishReason
    public let segments: [OmniXPCBatchSegment]

    public init(serviceInstanceID: UUID, modelID: UUID, requestID: UUID, kind: OmniXPCBatchKind,
                text: String, language: String?, generatedTokenCount: Int,
                finishReason: FinishReason, segments: [OmniXPCBatchSegment]) throws {
        self.serviceInstanceID = serviceInstanceID
        self.modelID = modelID
        self.requestID = requestID
        self.kind = kind
        self.text = text
        self.language = language
        self.generatedTokenCount = generatedTokenCount
        self.finishReason = finishReason
        self.segments = segments
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case serviceInstanceID, modelID, requestID, kind, text, language, generatedTokenCount, finishReason, segments
    }

    public init(from decoder: any Decoder) throws {
        try BatchWireField.require(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var segmentValues = try values.nestedUnkeyedContainer(forKey: .segments)
        var segments: [OmniXPCBatchSegment] = []
        while !segmentValues.isAtEnd {
            guard segments.count < OmniXPCBatchLimits.maximumSegmentCount else {
                throw OmniXPCFailure.error(.invalidRequest, "The batch segment count exceeds its limit.")
            }
            segments.append(try segmentValues.decode(OmniXPCBatchSegment.self))
        }
        try self.init(serviceInstanceID: values.decode(UUID.self, forKey: .serviceInstanceID),
                      modelID: values.decode(UUID.self, forKey: .modelID),
                      requestID: values.decode(UUID.self, forKey: .requestID),
                      kind: values.decode(OmniXPCBatchKind.self, forKey: .kind),
                      text: values.decode(String.self, forKey: .text),
                      language: values.decodeIfPresent(String.self, forKey: .language),
                      generatedTokenCount: values.decode(Int.self, forKey: .generatedTokenCount),
                      finishReason: values.decode(FinishReason.self, forKey: .finishReason), segments: segments)
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(serviceInstanceID, forKey: .serviceInstanceID)
        try values.encode(modelID, forKey: .modelID)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(kind, forKey: .kind)
        try values.encode(text, forKey: .text)
        try values.encode(language, forKey: .language)
        try values.encode(generatedTokenCount, forKey: .generatedTokenCount)
        try values.encode(finishReason, forKey: .finishReason)
        try values.encode(segments, forKey: .segments)
    }

    public func validate() throws {
        guard (0...OmniXPCProtocolLimits.maximumTokenCount).contains(generatedTokenCount),
              segments.count <= OmniXPCBatchLimits.maximumSegmentCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch output counters exceed validation limits.")
        }
        try BatchWireField.validateString(text, maximumByteCount: OmniXPCBatchLimits.maximumTextByteCount)
        try BatchWireField.validateString(language, maximumByteCount: OmniXPCBatchLimits.maximumMetadataByteCount)
        var stringByteCount = text.utf8.count + 1 + (language.map { $0.utf8.count + 1 } ?? 0)
        for segment in segments {
            try segment.validate()
            stringByteCount += segment.stringByteCount
        }
        guard stringByteCount <= OmniXPCBatchLimits.maximumResultStringByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch output strings exceed their total byte limit.")
        }
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= OmniXPCBatchLimits.maximumResultByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch result exceeds its byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCBatchLimits.maximumResultByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch result exceeds its byte limit.")
        }
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The batch result is invalid.")
        }
    }
}
