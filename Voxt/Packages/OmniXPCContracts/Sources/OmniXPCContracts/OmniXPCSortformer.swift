import Foundation

public nonisolated enum OmniXPCSortformerLimits {
    public static let sampleRate = 16_000
    public static let featureHopSampleCount = 160
    public static let subsamplingFactor = 8
    public static let maximumChunkSampleCount = 32_000
    public static let maximumStreamCount = 16
    public static let maximumLoadsPerConnection = 256
    public static let maximumStateFrameCount = 4096
    public static let maximumChunkFrameCount = 26
    public static let speakerCount = 4
    public static let maximumSegmentCount = 104
    public static let maximumSettingsByteCount = 1024
    public static let maximumBatchByteCount = 32_768
    public static let maximumDurationSeconds = 3600
    public static let maximumProcessedFrameCount = UInt64(Int32.max)
    public static let frameDurationSeconds = Double(
        Float(featureHopSampleCount) / Float(sampleRate) * Float(subsamplingFactor)
    )
}

public nonisolated struct OmniXPCSortformerSettings: Codable, Equatable, Sendable {
    public let threshold: Float
    public let minimumDurationSeconds: Float
    public let mergeGapSeconds: Float
    public let speakerCacheMaximumFrameCount: Int
    public let fifoMaximumFrameCount: Int

    public init(
        threshold: Float, minimumDurationSeconds: Float, mergeGapSeconds: Float,
        speakerCacheMaximumFrameCount: Int, fifoMaximumFrameCount: Int
    ) throws {
        self.threshold = threshold
        self.minimumDurationSeconds = minimumDurationSeconds
        self.mergeGapSeconds = mergeGapSeconds
        self.speakerCacheMaximumFrameCount = speakerCacheMaximumFrameCount
        self.fifoMaximumFrameCount = fifoMaximumFrameCount
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case threshold, minimumDurationSeconds, mergeGapSeconds
        case speakerCacheMaximumFrameCount, fifoMaximumFrameCount
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: SortformerWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer settings fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            threshold: values.decode(Float.self, forKey: .threshold),
            minimumDurationSeconds: values.decode(Float.self, forKey: .minimumDurationSeconds),
            mergeGapSeconds: values.decode(Float.self, forKey: .mergeGapSeconds),
            speakerCacheMaximumFrameCount: values.decode(Int.self, forKey: .speakerCacheMaximumFrameCount),
            fifoMaximumFrameCount: values.decode(Int.self, forKey: .fifoMaximumFrameCount)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(threshold, forKey: .threshold)
        try values.encode(minimumDurationSeconds, forKey: .minimumDurationSeconds)
        try values.encode(mergeGapSeconds, forKey: .mergeGapSeconds)
        try values.encode(speakerCacheMaximumFrameCount, forKey: .speakerCacheMaximumFrameCount)
        try values.encode(fifoMaximumFrameCount, forKey: .fifoMaximumFrameCount)
    }

    public func validate() throws {
        let durationRange: ClosedRange<Float> = 0...Float(OmniXPCSortformerLimits.maximumDurationSeconds)
        guard threshold.isFinite, (0...1).contains(threshold),
              minimumDurationSeconds.isFinite, durationRange.contains(minimumDurationSeconds),
              mergeGapSeconds.isFinite, durationRange.contains(mergeGapSeconds),
              (1...OmniXPCSortformerLimits.maximumStateFrameCount).contains(speakerCacheMaximumFrameCount),
              (0...OmniXPCSortformerLimits.maximumStateFrameCount).contains(fifoMaximumFrameCount) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer settings exceed validation limits.")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= OmniXPCSortformerLimits.maximumSettingsByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer settings exceed their byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCSortformerLimits.maximumSettingsByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer settings exceed their byte limit.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer settings are invalid.")
        }
    }
}

public nonisolated struct OmniXPCSortformerModelReference: Equatable, Sendable {
    public let modelID: UUID
    public let serviceInstanceID: UUID
    public let connectionID: UUID

    public init(modelID: UUID, serviceInstanceID: UUID, connectionID: UUID) {
        self.modelID = modelID
        self.serviceInstanceID = serviceInstanceID
        self.connectionID = connectionID
    }
}

public nonisolated struct OmniXPCSortformerStreamReference: Equatable, Sendable {
    public let streamID: UUID
    public let model: OmniXPCSortformerModelReference

    public init(streamID: UUID, model: OmniXPCSortformerModelReference) {
        self.streamID = streamID
        self.model = model
    }
}

nonisolated struct SortformerWireField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
