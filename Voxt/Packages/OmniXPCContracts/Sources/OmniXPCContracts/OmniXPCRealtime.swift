import Foundation

public nonisolated enum OmniXPCRealtimeEventKind: Int, Codable, Sendable {
    case updated = 1
    case segment = 2
    case completed = 3
    case cancelled = 4
    case failed = 5
}

public nonisolated struct OmniXPCRealtimeEvent: Codable, Equatable, Sendable {
    public let sequence: Int
    public let kind: OmniXPCRealtimeEventKind
    public let segmentID: Int?
    public let text: String?
    public let isFinal: Bool?
    public let failureMessage: String?

    public init(
        sequence: Int, kind: OmniXPCRealtimeEventKind, segmentID: Int? = nil,
        text: String? = nil, isFinal: Bool? = nil, failureMessage: String? = nil
    ) {
        self.sequence = sequence
        self.kind = kind
        self.segmentID = segmentID
        self.text = text
        self.isFinal = isFinal
        self.failureMessage = failureMessage
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sequence, kind, segmentID, text, isFinal, failureMessage
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: RealtimeWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime event has unknown fields.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(Int.self, forKey: .sequence)
        kind = try values.decode(OmniXPCRealtimeEventKind.self, forKey: .kind)
        segmentID = try values.contains(.segmentID) ? values.decode(Int.self, forKey: .segmentID) : nil
        text = try values.contains(.text) ? values.decode(String.self, forKey: .text) : nil
        isFinal = try values.contains(.isFinal) ? values.decode(Bool.self, forKey: .isFinal) : nil
        failureMessage = try values.contains(.failureMessage) ? values.decode(String.self, forKey: .failureMessage) : nil
    }
}

public nonisolated struct OmniXPCRealtimeBatch: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let modelID: UUID
    public let serviceInstanceID: UUID
    public let events: [OmniXPCRealtimeEvent]
    public let isDrained: Bool

    public init(sessionID: UUID, modelID: UUID, serviceInstanceID: UUID, events: [OmniXPCRealtimeEvent], isDrained: Bool) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.serviceInstanceID = serviceInstanceID
        self.events = events
        self.isDrained = isDrained
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionID, modelID, serviceInstanceID, events, isDrained
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: RealtimeWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime batch fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        modelID = try values.decode(UUID.self, forKey: .modelID)
        serviceInstanceID = try values.decode(UUID.self, forKey: .serviceInstanceID)
        events = try values.decode([OmniXPCRealtimeEvent].self, forKey: .events)
        isDrained = try values.decode(Bool.self, forKey: .isDrained)
    }
}

public nonisolated struct OmniXPCRealtimeSettings: Equatable, Sendable {
    public let decodeIntervalSamples: Int
    public let firstDecodeSamples: Int
    public let maximumSegmentSamples: Int

    public init(
        decodeIntervalSamples: Int = 16_000, firstDecodeSamples: Int = 8_000, maximumSegmentSamples: Int = 48_000
    ) throws {
        let sampleRange = 1...OmniXPCProtocolLimits.maximumSampleCount
        guard sampleRange.contains(decodeIntervalSamples), sampleRange.contains(firstDecodeSamples),
              sampleRange.contains(maximumSegmentSamples) else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime settings exceed validation limits.")
        }
        self.decodeIntervalSamples = decodeIntervalSamples
        self.firstDecodeSamples = firstDecodeSamples
        self.maximumSegmentSamples = maximumSegmentSamples
    }
}

public nonisolated struct OmniXPCRealtimeSessionReference: Equatable, Sendable {
    public let sessionID: UUID
    public let model: OmniXPCModelReference
    public let language: String?
    public let maximumTokenCount: Int

    public init(sessionID: UUID, model: OmniXPCModelReference, language: String?, maximumTokenCount: Int) {
        self.sessionID = sessionID
        self.model = model
        self.language = language
        self.maximumTokenCount = maximumTokenCount
    }
}

public nonisolated enum OmniXPCRealtimeCodec {
    public static func encode(_ batch: OmniXPCRealtimeBatch) throws -> Data {
        try validate(batch)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(batch)
        guard data.count <= OmniXPCProtocolLimits.maximumRealtimeBatchByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime batch exceeds its byte limit.")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> OmniXPCRealtimeBatch {
        guard !data.isEmpty, data.count <= OmniXPCProtocolLimits.maximumRealtimeBatchByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime batch exceeds its byte limit.")
        }
        do {
            let batch = try JSONDecoder().decode(OmniXPCRealtimeBatch.self, from: data)
            try validate(batch)
            return batch
        } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime batch is invalid.")
        }
    }

    private static func validate(_ batch: OmniXPCRealtimeBatch) throws {
        guard batch.events.count <= OmniXPCProtocolLimits.maximumRealtimeEventsPerBatch,
              !batch.isDrained || batch.events.isEmpty else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime batch has invalid event counts or drain state.")
        }
        var previousSequence: Int?
        for (index, event) in batch.events.enumerated() {
            guard event.sequence > 0 else {
                throw OmniXPCFailure.error(.invalidRequest, "Realtime event sequences must be positive.")
            }
            if let previousSequence {
                guard previousSequence < Int.max, event.sequence == previousSequence + 1 else {
                    throw OmniXPCFailure.error(.invalidRequest, "Realtime event sequences must be consecutive.")
                }
            }
            previousSequence = event.sequence
            for string in [event.text, event.failureMessage].compactMap({ $0 }) {
                guard string.utf8.count <= OmniXPCProtocolLimits.maximumRealtimeEventStringByteCount,
                      !string.contains("\0") else {
                    throw OmniXPCFailure.error(.invalidRequest, "The realtime event string exceeds validation limits.")
                }
            }
            let validShape: Bool
            switch event.kind {
            case .updated, .cancelled:
                validShape = event.segmentID == nil && event.text == nil && event.isFinal == nil && event.failureMessage == nil
            case .segment:
                validShape = (event.segmentID ?? -1) >= 0 && event.text != nil && event.isFinal != nil && event.failureMessage == nil
            case .completed:
                validShape = event.segmentID == nil && event.text != nil && event.isFinal == nil && event.failureMessage == nil
            case .failed:
                validShape = event.segmentID == nil && event.text == nil && event.isFinal == nil
                    && event.failureMessage?.isEmpty == false
                    && event.failureMessage?.rangeOfCharacter(from: .controlCharacters) == nil
            }
            guard validShape else {
                throw OmniXPCFailure.error(.invalidRequest, "The realtime event fields do not match its kind.")
            }
            switch event.kind {
            case .completed, .cancelled, .failed:
                guard index == batch.events.count - 1 else {
                    throw OmniXPCFailure.error(.invalidRequest, "A terminal realtime event must be last in its batch.")
                }
            case .updated, .segment:
                break
            }
        }
    }
}

private nonisolated struct RealtimeWireField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
