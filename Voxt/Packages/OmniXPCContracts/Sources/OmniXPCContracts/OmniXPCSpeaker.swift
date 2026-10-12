import Foundation

public nonisolated enum OmniXPCSpeakerKind: Int32, Codable, CaseIterable, Sendable {
    case moss = 1, nemotron = 2
}

public nonisolated enum OmniXPCSpeakerStatus: Int32, Codable, CaseIterable, Sendable {
    case ok = 0, invalid, busy, cancelled, failed, outOfMemory, limit
}

public nonisolated enum OmniXPCSpeakerLimits {
    public static let sampleRate = 16_000
    public static let maximumChunkSampleCount = 32_000
    public static let maximumSessionSampleCount = 480_000
    public static let maximumPromptByteCount = 8192
    public static let maximumMetadataByteCount = 128
    public static let maximumChunkMilliseconds: Double = 120_000
    public static let maximumTextByteCount = 65_536
    public static let maximumSegmentCount = 512
    public static let maximumEventStringByteCount = 262_144
    public static let maximumEventsPerBatch = 64
    public static let maximumBatchStringByteCount = 4 * 1024 * 1024
    public static let maximumReferenceByteCount = 4096
    public static let maximumSettingsByteCount = 65_536
    public static let maximumEventByteCount = 2 * 1024 * 1024
    public static let maximumBatchByteCount = 4 * 1024 * 1024
}

nonisolated struct SpeakerWireField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func require(_ decoder: any Decoder, fields: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard Set(values.allKeys.map(\.stringValue)) == fields else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker message fields are invalid.")
        }
    }

    static func validateString(_ string: String?, maximumByteCount: Int) throws {
        guard (string?.utf8.count ?? 0) <= maximumByteCount, string?.contains("\0") != true else {
            throw OmniXPCFailure.error(.invalidRequest, "A speaker string exceeds validation limits.")
        }
    }

    static func validateUUID(_ identifier: UUID) throws {
        guard identifier.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker identifiers must be nonzero UUIDs.")
        }
    }

    static func validateBytes(_ bytes: Data, maximumByteCount: Int) throws {
        guard !bytes.isEmpty, bytes.count <= maximumByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker message exceeds its byte limit.")
        }
    }
}
