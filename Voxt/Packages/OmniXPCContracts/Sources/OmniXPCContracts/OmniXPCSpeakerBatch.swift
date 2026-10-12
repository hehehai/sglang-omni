import Foundation

public nonisolated struct OmniXPCSpeakerBatch: Codable, Equatable, Sendable {
    public let session: OmniXPCSpeakerSessionReference
    public let events: [OmniXPCSpeakerEvent]
    public let isDrained: Bool

    public init(session: OmniXPCSpeakerSessionReference, events: [OmniXPCSpeakerEvent], isDrained: Bool) throws {
        self.session = session
        self.events = events
        self.isDrained = isDrained
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case session, events, isDrained }

    public init(from decoder: any Decoder) throws {
        try SpeakerWireField.require(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var elements = try values.nestedUnkeyedContainer(forKey: .events)
        guard (elements.count ?? 0) <= OmniXPCSpeakerLimits.maximumEventsPerBatch else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker event count exceeds its limit.")
        }
        var events: [OmniXPCSpeakerEvent] = []
        var stringByteCount = 0
        while !elements.isAtEnd {
            guard events.count < OmniXPCSpeakerLimits.maximumEventsPerBatch else {
                throw OmniXPCFailure.error(.invalidRequest, "The speaker event count exceeds its limit.")
            }
            let event = try elements.decode(OmniXPCSpeakerEvent.self)
            stringByteCount += event.stringByteCount
            guard stringByteCount <= OmniXPCSpeakerLimits.maximumBatchStringByteCount else {
                throw OmniXPCFailure.error(.invalidRequest, "The speaker batch strings exceed their total byte limit.")
            }
            events.append(event)
        }
        try self.init(session: values.decode(OmniXPCSpeakerSessionReference.self, forKey: .session),
                      events: events, isDrained: values.decode(Bool.self, forKey: .isDrained))
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(session, forKey: .session)
        try values.encode(events, forKey: .events)
        try values.encode(isDrained, forKey: .isDrained)
    }

    private func validate() throws {
        guard events.count <= OmniXPCSpeakerLimits.maximumEventsPerBatch, !isDrained || events.isEmpty else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker batch count or drain state is invalid.")
        }
        var previousSequence: UInt64?
        var stringByteCount = 0
        for (index, event) in events.enumerated() {
            try event.validate()
            guard event.session == session else {
                throw OmniXPCFailure.error(.invalidRequest, "The speaker event has a different owner scope.")
            }
            if let previousSequence {
                guard previousSequence < UInt64.max, event.eventSequence == previousSequence + 1 else {
                    throw OmniXPCFailure.error(.invalidRequest, "Speaker event sequences must be consecutive.")
                }
            } else { }
            previousSequence = event.eventSequence
            switch event.kind {
            case .completed, .cancelled, .failed:
                guard index == events.count - 1 else {
                    throw OmniXPCFailure.error(.invalidRequest, "A terminal speaker event must be last in its batch.")
                }
            case .updated, .segment:
                break
            }
            stringByteCount += event.stringByteCount
        }
        guard stringByteCount <= OmniXPCSpeakerLimits.maximumBatchStringByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker batch strings exceed their total byte limit.")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumBatchByteCount)
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumBatchByteCount)
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker batch is invalid.")
        }
    }
}
