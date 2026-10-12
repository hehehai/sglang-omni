import Foundation

public nonisolated enum OmniXPCSpeakerEventKind: Int32, Codable, CaseIterable, Sendable {
    case updated = 1, segment, completed, cancelled, failed
}

public nonisolated struct OmniXPCSpeakerEvent: Codable, Equatable, Sendable {
    public let session: OmniXPCSpeakerSessionReference
    public let eventSequence: UInt64
    public let kind: OmniXPCSpeakerEventKind
    public let segmentID: Int32?
    public let text: String?
    public let isFinal: Bool?
    public let segments: [OmniXPCBatchSegment]?
    public let failureStatus: OmniXPCSpeakerStatus

    public init(session: OmniXPCSpeakerSessionReference, eventSequence: UInt64, kind: OmniXPCSpeakerEventKind,
                segmentID: Int32? = nil, text: String? = nil, isFinal: Bool? = nil,
                segments: [OmniXPCBatchSegment]? = nil, failureStatus: OmniXPCSpeakerStatus = .ok) throws {
        self.session = session
        self.eventSequence = eventSequence
        self.kind = kind
        self.segmentID = segmentID
        self.text = text
        self.isFinal = isFinal
        self.segments = segments
        self.failureStatus = failureStatus
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case session, eventSequence, kind, segmentID, text, isFinal, segments, failureStatus
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(OmniXPCSpeakerEventKind.self, forKey: .kind)
        var fields: Set<String> = ["session", "eventSequence", "kind", "failureStatus"]
        let isFinal: Bool?
        switch kind {
        case .segment:
            isFinal = try values.decode(Bool.self, forKey: .isFinal)
            fields.formUnion(["segmentID", "text", "isFinal"])
            if isFinal == true { fields.insert("segments") } else { }
        case .completed:
            isFinal = nil
            fields.formUnion(["text", "segments"])
        case .updated, .cancelled, .failed:
            isFinal = nil
        }
        try SpeakerWireField.require(decoder, fields: fields)
        let text = try fields.contains("text") ? values.decode(String.self, forKey: .text) : nil
        try SpeakerWireField.validateString(text, maximumByteCount: OmniXPCSpeakerLimits.maximumTextByteCount)
        let segments: [OmniXPCBatchSegment]?
        if fields.contains("segments") {
            var elements = try values.nestedUnkeyedContainer(forKey: .segments)
            guard (elements.count ?? 0) <= OmniXPCSpeakerLimits.maximumSegmentCount else {
                throw OmniXPCFailure.error(.invalidRequest, "The speaker segment count exceeds its limit.")
            }
            var decodedSegments: [OmniXPCBatchSegment] = []
            var stringByteCount = text.map { $0.utf8.count + 1 } ?? 0
            while !elements.isAtEnd {
                guard decodedSegments.count < OmniXPCSpeakerLimits.maximumSegmentCount else {
                    throw OmniXPCFailure.error(.invalidRequest, "The speaker segment count exceeds its limit.")
                }
                let segment = try elements.decode(OmniXPCBatchSegment.self)
                stringByteCount += segment.stringByteCount
                guard stringByteCount <= OmniXPCSpeakerLimits.maximumEventStringByteCount else {
                    throw OmniXPCFailure.error(.invalidRequest, "The speaker event strings exceed their total byte limit.")
                }
                decodedSegments.append(segment)
            }
            segments = decodedSegments
        } else {
            segments = nil
        }
        try self.init(session: values.decode(OmniXPCSpeakerSessionReference.self, forKey: .session),
                      eventSequence: values.decode(UInt64.self, forKey: .eventSequence), kind: kind,
                      segmentID: kind == .segment ? values.decode(Int32.self, forKey: .segmentID) : nil,
                      text: text, isFinal: isFinal, segments: segments,
                      failureStatus: values.decode(OmniXPCSpeakerStatus.self, forKey: .failureStatus))
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(session, forKey: .session)
        try values.encode(eventSequence, forKey: .eventSequence)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(segmentID, forKey: .segmentID)
        try values.encodeIfPresent(text, forKey: .text)
        try values.encodeIfPresent(isFinal, forKey: .isFinal)
        try values.encodeIfPresent(segments, forKey: .segments)
        try values.encode(failureStatus, forKey: .failureStatus)
    }

    public func validate() throws {
        guard eventSequence > 0 else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker event sequence must be positive.")
        }
        let validShape: Bool
        switch kind {
        case .updated:
            validShape = segmentID == nil && text == nil && isFinal == nil && segments == nil && failureStatus == .ok
        case .segment:
            validShape = (segmentID ?? -1) >= 0 && text != nil && isFinal != nil
                && (isFinal == true ? segments != nil : segments == nil) && failureStatus == .ok
        case .completed:
            validShape = segmentID == nil && text != nil && isFinal == nil && segments != nil && failureStatus == .ok
        case .cancelled:
            validShape = segmentID == nil && text == nil && isFinal == nil && segments == nil && failureStatus == .cancelled
        case .failed:
            validShape = segmentID == nil && text == nil && isFinal == nil && segments == nil
                && [.failed, .outOfMemory, .limit].contains(failureStatus)
        }
        guard validShape, (segments?.count ?? 0) <= OmniXPCSpeakerLimits.maximumSegmentCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker event fields do not match its kind or limits.")
        }
        try SpeakerWireField.validateString(text, maximumByteCount: OmniXPCSpeakerLimits.maximumTextByteCount)
        for segment in segments ?? [] { try segment.validate() }
        guard stringByteCount <= OmniXPCSpeakerLimits.maximumEventStringByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker event strings exceed their total byte limit.")
        }
    }

    var stringByteCount: Int {
        (text.map { $0.utf8.count + 1 } ?? 0) + (segments ?? []).reduce(0) { $0 + $1.stringByteCount }
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumEventByteCount)
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumEventByteCount)
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker event is invalid.")
        }
    }
}
