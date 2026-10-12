import Foundation

public nonisolated enum OmniXPCBatchKind: Int, Codable, CaseIterable, Sendable {
    case whisper = 1, cohere, moss, nemotron, parakeet, sensevoice
}

public nonisolated enum OmniXPCBatchLimits {
    public static let maximumLoadsPerConnection = 256
    public static let maximumOperationsPerConnection = 256
    public static let maximumSettingsByteCount = 65_536
    public static let maximumResultByteCount = 2 * 1024 * 1024
    public static let maximumTextByteCount = 65_536
    public static let maximumMetadataByteCount = 128
    public static let maximumPromptByteCount = 8192
    public static let maximumSegmentCount = 512
    public static let maximumResultStringByteCount = 262_144
}

public nonisolated struct OmniXPCBatchModelReference: Equatable, Sendable {
    public let kind: OmniXPCBatchKind
    public let modelID: UUID
    public let serviceInstanceID: UUID
    public let connectionID: UUID
    public let loadOperationID: UUID

    public init(kind: OmniXPCBatchKind, modelID: UUID, serviceInstanceID: UUID, connectionID: UUID, loadOperationID: UUID) {
        self.kind = kind
        self.modelID = modelID
        self.serviceInstanceID = serviceInstanceID
        self.connectionID = connectionID
        self.loadOperationID = loadOperationID
    }
}

public nonisolated enum OmniXPCBatchFailure {
    public enum Code: Int, Sendable {
        case invalid = 1, busy, cancelled, failed, outOfMemory, limit
    }

    public static func error(_ code: Code) -> NSError {
        NSError(domain: "Voxt.Omni.XPC.Batch", code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Native batch operation did not complete (status \(code.rawValue))."])
    }
}

nonisolated struct BatchWireField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func require(_ decoder: any Decoder, fields: Set<String>) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard Set(values.allKeys.map(\.stringValue)) == fields else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch message fields are invalid.")
        }
    }

    static func validateString(_ string: String?, maximumByteCount: Int) throws {
        guard (string?.utf8.count ?? 0) <= maximumByteCount, string?.contains("\0") != true else {
            throw OmniXPCFailure.error(.invalidRequest, "A batch string exceeds validation limits.")
        }
    }
}
