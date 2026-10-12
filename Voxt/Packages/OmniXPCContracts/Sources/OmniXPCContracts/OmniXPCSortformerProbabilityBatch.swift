import Foundation

public nonisolated struct OmniXPCSortformerProbabilityBatch: Codable, Equatable, Sendable {
    public let serviceInstanceID: UUID
    public let modelID: UUID
    public let streamID: UUID
    public let audioSequence: Int
    public let processedFrameCount: UInt64
    public let frameCount: Int
    public let speakerCount: Int
    public let frameDurationSeconds: Double
    public let probabilities: [Float]
    public let segments: [OmniXPCSortformerSegment]

    public init(
        serviceInstanceID: UUID, modelID: UUID, streamID: UUID, audioSequence: Int,
        processedFrameCount: UInt64, frameCount: Int, speakerCount: Int,
        frameDurationSeconds: Double, probabilities: [Float], segments: [OmniXPCSortformerSegment]
    ) throws {
        self.serviceInstanceID = serviceInstanceID
        self.modelID = modelID
        self.streamID = streamID
        self.audioSequence = audioSequence
        self.processedFrameCount = processedFrameCount
        self.frameCount = frameCount
        self.speakerCount = speakerCount
        self.frameDurationSeconds = frameDurationSeconds
        self.probabilities = probabilities
        self.segments = segments
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case serviceInstanceID, modelID, streamID, audioSequence, processedFrameCount
        case frameCount, speakerCount, frameDurationSeconds, probabilities, segments
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: SortformerWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability batch fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceInstanceID = try values.decode(UUID.self, forKey: .serviceInstanceID)
        modelID = try values.decode(UUID.self, forKey: .modelID)
        streamID = try values.decode(UUID.self, forKey: .streamID)
        audioSequence = try values.decode(Int.self, forKey: .audioSequence)
        processedFrameCount = try values.decode(UInt64.self, forKey: .processedFrameCount)
        frameCount = try values.decode(Int.self, forKey: .frameCount)
        speakerCount = try values.decode(Int.self, forKey: .speakerCount)
        frameDurationSeconds = try values.decode(Double.self, forKey: .frameDurationSeconds)
        let maximumProbabilityCount = OmniXPCSortformerLimits.maximumChunkFrameCount * OmniXPCSortformerLimits.speakerCount
        var probabilityElements = try values.nestedUnkeyedContainer(forKey: .probabilities)
        var segmentElements = try values.nestedUnkeyedContainer(forKey: .segments)
        guard (probabilityElements.count ?? 0) <= maximumProbabilityCount,
              (segmentElements.count ?? 0) <= OmniXPCSortformerLimits.maximumSegmentCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer output count exceeds validation limits.")
        }
        var probabilities: [Float] = []
        while !probabilityElements.isAtEnd {
            guard probabilities.count < maximumProbabilityCount else {
                throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability count exceeds validation limits.")
            }
            probabilities.append(try probabilityElements.decode(Float.self))
        }
        var segments: [OmniXPCSortformerSegment] = []
        while !segmentElements.isAtEnd {
            guard segments.count < OmniXPCSortformerLimits.maximumSegmentCount else {
                throw OmniXPCFailure.error(.incompatibleService, "The Sortformer segment count exceeds validation limits.")
            }
            segments.append(try segmentElements.decode(OmniXPCSortformerSegment.self))
        }
        self.probabilities = probabilities
        self.segments = segments
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(serviceInstanceID, forKey: .serviceInstanceID)
        try values.encode(modelID, forKey: .modelID)
        try values.encode(streamID, forKey: .streamID)
        try values.encode(audioSequence, forKey: .audioSequence)
        try values.encode(processedFrameCount, forKey: .processedFrameCount)
        try values.encode(frameCount, forKey: .frameCount)
        try values.encode(speakerCount, forKey: .speakerCount)
        try values.encode(frameDurationSeconds, forKey: .frameDurationSeconds)
        try values.encode(probabilities, forKey: .probabilities)
        try values.encode(segments, forKey: .segments)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= OmniXPCSortformerLimits.maximumBatchByteCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability batch exceeds its byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCSortformerLimits.maximumBatchByteCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability batch exceeds its byte limit.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability batch is invalid.")
        }
    }

    private func validate() throws {
        guard audioSequence >= 1,
              (1...OmniXPCSortformerLimits.maximumChunkFrameCount).contains(frameCount),
              speakerCount == OmniXPCSortformerLimits.speakerCount,
              processedFrameCount >= UInt64(frameCount),
              processedFrameCount <= OmniXPCSortformerLimits.maximumProcessedFrameCount,
              frameDurationSeconds.isFinite,
              frameDurationSeconds == OmniXPCSortformerLimits.frameDurationSeconds,
              probabilities.count == frameCount * speakerCount,
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              segments.count <= OmniXPCSortformerLimits.maximumSegmentCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer probability batch exceeds validation limits.")
        }
        let previousFrameCount = processedFrameCount - UInt64(frameCount)
        // Note (OpenAI): ABI5 bounds use the model's Float operations before widening absolute seconds.
        let startSeconds = Float(previousFrameCount) * Float(frameDurationSeconds)
        let endSeconds = Float(frameCount) * Float(frameDurationSeconds) + startSeconds
        var previousStartSeconds = Double(startSeconds)
        for segment in segments {
            guard segment.startSeconds >= previousStartSeconds,
                  segment.endSeconds <= Double(endSeconds) else {
                throw OmniXPCFailure.error(.incompatibleService, "The Sortformer absolute segment ranges are invalid.")
            }
            previousStartSeconds = segment.startSeconds
        }
    }
}
