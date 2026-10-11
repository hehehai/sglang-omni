import Foundation

public nonisolated enum OmniXPCSileroLimits {
    public static let frameSampleCount = 512
    public static let maximumChunkSampleCount = 32_000
    public static let maximumStreamCount = 16
    public static let maximumProbabilityCount = 63
    public static let maximumProbabilityBatchByteCount = 4096
    public static let maximumSettingsByteCount = 1024
    public static let maximumTimestampBatchByteCount = 65_536
    public static let maximumTimestampCount = 938
    public static let maximumOptionMilliseconds = 30_000
}

public nonisolated struct OmniXPCSileroSettings: Codable, Equatable, Sendable {
    public let threshold: Float
    public let minimumSpeechMilliseconds: Int
    public let minimumSilenceMilliseconds: Int
    public let speechPaddingMilliseconds: Int

    public init(
        threshold: Float, minimumSpeechMilliseconds: Int,
        minimumSilenceMilliseconds: Int, speechPaddingMilliseconds: Int
    ) {
        self.threshold = threshold
        self.minimumSpeechMilliseconds = minimumSpeechMilliseconds
        self.minimumSilenceMilliseconds = minimumSilenceMilliseconds
        self.speechPaddingMilliseconds = speechPaddingMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case threshold, minimumSpeechMilliseconds, minimumSilenceMilliseconds, speechPaddingMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: SileroWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero settings fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try values.decode(Float.self, forKey: .threshold)
        minimumSpeechMilliseconds = try values.decode(Int.self, forKey: .minimumSpeechMilliseconds)
        minimumSilenceMilliseconds = try values.decode(Int.self, forKey: .minimumSilenceMilliseconds)
        speechPaddingMilliseconds = try values.decode(Int.self, forKey: .speechPaddingMilliseconds)
        try validate()
    }

    public func validate() throws {
        let millisecondsRange = 0...OmniXPCSileroLimits.maximumOptionMilliseconds
        guard threshold.isFinite, (0...1).contains(threshold),
              millisecondsRange.contains(minimumSpeechMilliseconds),
              millisecondsRange.contains(minimumSilenceMilliseconds),
              millisecondsRange.contains(speechPaddingMilliseconds) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero settings exceed validation limits.")
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= OmniXPCSileroLimits.maximumSettingsByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero settings exceed their byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCSileroLimits.maximumSettingsByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero settings exceed their byte limit.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero settings are invalid.")
        }
    }
}

public nonisolated struct OmniXPCSileroModelReference: Equatable, Sendable {
    public let modelID: UUID
    public let serviceInstanceID: UUID
    public let connectionID: UUID

    public init(modelID: UUID, serviceInstanceID: UUID, connectionID: UUID) {
        self.modelID = modelID
        self.serviceInstanceID = serviceInstanceID
        self.connectionID = connectionID
    }
}

public nonisolated struct OmniXPCSileroTimestamp: Codable, Equatable, Sendable {
    public let startSample: Int64
    public let endSample: Int64

    public init(startSample: Int64, endSample: Int64) {
        self.startSample = startSample
        self.endSample = endSample
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case startSample, endSample
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: SileroWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startSample = try values.decode(Int64.self, forKey: .startSample)
        endSample = try values.decode(Int64.self, forKey: .endSample)
    }
}

public nonisolated struct OmniXPCSileroTimestampBatch: Codable, Equatable, Sendable {
    public let serviceInstanceID: UUID
    public let modelID: UUID
    public let requestID: UUID
    public let sampleCount: Int
    public let timestamps: [OmniXPCSileroTimestamp]

    public init(
        serviceInstanceID: UUID, modelID: UUID, requestID: UUID,
        sampleCount: Int, timestamps: [OmniXPCSileroTimestamp]
    ) {
        self.serviceInstanceID = serviceInstanceID
        self.modelID = modelID
        self.requestID = requestID
        self.sampleCount = sampleCount
        self.timestamps = timestamps
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case serviceInstanceID, modelID, requestID, sampleCount, timestamps
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: SileroWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp batch fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceInstanceID = try values.decode(UUID.self, forKey: .serviceInstanceID)
        modelID = try values.decode(UUID.self, forKey: .modelID)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        sampleCount = try values.decode(Int.self, forKey: .sampleCount)
        var ranges = try values.nestedUnkeyedContainer(forKey: .timestamps)
        guard (ranges.count ?? 0) <= OmniXPCSileroLimits.maximumTimestampCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp count exceeds validation limits.")
        }
        var timestamps: [OmniXPCSileroTimestamp] = []
        while !ranges.isAtEnd {
            guard timestamps.count < OmniXPCSileroLimits.maximumTimestampCount else {
                throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp count exceeds validation limits.")
            }
            timestamps.append(try ranges.decode(OmniXPCSileroTimestamp.self))
        }
        self.timestamps = timestamps
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= OmniXPCSileroLimits.maximumTimestampBatchByteCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp batch exceeds its byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCSileroLimits.maximumTimestampBatchByteCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp batch exceeds its byte limit.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp batch is invalid.")
        }
    }

    private func validate() throws {
        guard (1...OmniXPCProtocolLimits.maximumSampleCount).contains(sampleCount),
              timestamps.count <= OmniXPCSileroLimits.maximumTimestampCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp batch exceeds validation limits.")
        }
        var previousEndSample: Int64 = 0
        for timestamp in timestamps {
            guard timestamp.startSample >= previousEndSample,
                  timestamp.startSample < timestamp.endSample,
                  timestamp.endSample <= Int64(sampleCount) else {
                throw OmniXPCFailure.error(.incompatibleService, "The Silero timestamp ranges are invalid.")
            }
            previousEndSample = timestamp.endSample
        }
    }
}

private nonisolated struct SileroWireField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
