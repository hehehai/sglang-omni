import Foundation

public nonisolated struct OmniXPCSortformerSegment: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let speakerIndex: Int

    public init(startSeconds: Double, endSeconds: Double, speakerIndex: Int) throws {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerIndex = speakerIndex
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case startSeconds, endSeconds, speakerIndex
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: SortformerWireField.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer segment fields are invalid.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startSeconds: values.decode(Double.self, forKey: .startSeconds),
            endSeconds: values.decode(Double.self, forKey: .endSeconds),
            speakerIndex: values.decode(Int.self, forKey: .speakerIndex)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(startSeconds, forKey: .startSeconds)
        try values.encode(endSeconds, forKey: .endSeconds)
        try values.encode(speakerIndex, forKey: .speakerIndex)
    }

    private func validate() throws {
        guard startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, startSeconds <= endSeconds,
              (0..<OmniXPCSortformerLimits.speakerCount).contains(speakerIndex) else {
            throw OmniXPCFailure.error(.incompatibleService, "The Sortformer segment exceeds validation limits.")
        }
    }
}
