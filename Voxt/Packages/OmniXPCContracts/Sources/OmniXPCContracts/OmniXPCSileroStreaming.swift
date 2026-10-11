import Foundation

public nonisolated struct OmniXPCSileroStreamReference: Equatable, Sendable {
    public let streamID: UUID
    public let model: OmniXPCSileroModelReference

    public init(streamID: UUID, model: OmniXPCSileroModelReference) {
        self.streamID = streamID
        self.model = model
    }
}

public nonisolated struct OmniXPCSileroProbabilityBatch: Codable, Equatable, Sendable {
    public let serviceInstanceID: UUID
    public let modelID: UUID
    public let streamID: UUID
    public let audioSequence: Int
    public let processedSampleCount: UInt64
    public let probabilities: [Float]
    public let isFinal: Bool

    public init(
        serviceInstanceID: UUID, modelID: UUID, streamID: UUID, audioSequence: Int,
        processedSampleCount: UInt64, probabilities: [Float], isFinal: Bool
    ) {
        self.serviceInstanceID = serviceInstanceID
        self.modelID = modelID
        self.streamID = streamID
        self.audioSequence = audioSequence
        self.processedSampleCount = processedSampleCount
        self.probabilities = probabilities
        self.isFinal = isFinal
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case serviceInstanceID, modelID, streamID, audioSequence, processedSampleCount, probabilities, isFinal
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ProbabilityWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero probability batch fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceInstanceID = try values.decode(UUID.self, forKey: .serviceInstanceID)
        modelID = try values.decode(UUID.self, forKey: .modelID)
        streamID = try values.decode(UUID.self, forKey: .streamID)
        audioSequence = try values.decode(Int.self, forKey: .audioSequence)
        processedSampleCount = try values.decode(UInt64.self, forKey: .processedSampleCount)
        isFinal = try values.decode(Bool.self, forKey: .isFinal)
        let maximumCount = isFinal ? 1 : OmniXPCSileroLimits.maximumProbabilityCount
        var elements = try values.nestedUnkeyedContainer(forKey: .probabilities)
        guard (elements.count ?? 0) <= maximumCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero probability count exceeds validation limits.")
        }
        var probabilities: [Float] = []
        while !elements.isAtEnd {
            guard probabilities.count < maximumCount else {
                throw OmniXPCFailure.error(.incompatibleService, "The Silero probability count exceeds validation limits.")
            }
            probabilities.append(try elements.decode(Float.self))
        }
        self.probabilities = probabilities
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= OmniXPCSileroLimits.maximumProbabilityBatchByteCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero probability batch exceeds its byte limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= OmniXPCSileroLimits.maximumProbabilityBatchByteCount else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero probability batch exceeds its byte limit.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes)
        } catch {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero probability batch is invalid.")
        }
    }

    private func validate() throws {
        guard audioSequence >= (isFinal ? 0 : 1),
              processedSampleCount % UInt64(OmniXPCSileroLimits.frameSampleCount) == 0,
              probabilities.count <= (isFinal ? 1 : OmniXPCSileroLimits.maximumProbabilityCount),
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Silero probability batch exceeds validation limits.")
        }
    }
}

private nonisolated struct ProbabilityWireField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
