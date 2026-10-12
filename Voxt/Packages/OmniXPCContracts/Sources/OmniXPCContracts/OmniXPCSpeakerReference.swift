import Foundation

public nonisolated struct OmniXPCSpeakerModelReference: Codable, Equatable, Sendable {
    public let kind: OmniXPCSpeakerKind
    public let modelID: UUID
    public let serviceInstanceID: UUID
    public let connectionID: UUID
    public let loadOperationID: UUID

    public init(kind: OmniXPCSpeakerKind, modelID: UUID, serviceInstanceID: UUID,
                connectionID: UUID, loadOperationID: UUID) throws {
        for identifier in [modelID, serviceInstanceID, connectionID, loadOperationID] {
            try SpeakerWireField.validateUUID(identifier)
        }
        self.kind = kind
        self.modelID = modelID
        self.serviceInstanceID = serviceInstanceID
        self.connectionID = connectionID
        self.loadOperationID = loadOperationID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, modelID, serviceInstanceID, connectionID, loadOperationID
    }

    public init(from decoder: any Decoder) throws {
        try SpeakerWireField.require(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: values.decode(OmniXPCSpeakerKind.self, forKey: .kind),
                      modelID: values.decode(UUID.self, forKey: .modelID),
                      serviceInstanceID: values.decode(UUID.self, forKey: .serviceInstanceID),
                      connectionID: values.decode(UUID.self, forKey: .connectionID),
                      loadOperationID: values.decode(UUID.self, forKey: .loadOperationID))
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumReferenceByteCount)
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumReferenceByteCount)
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker model reference is invalid.")
        }
    }
}

public nonisolated struct OmniXPCSpeakerSessionReference: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let model: OmniXPCSpeakerModelReference

    public init(sessionID: UUID, model: OmniXPCSpeakerModelReference) throws {
        try SpeakerWireField.validateUUID(sessionID)
        self.sessionID = sessionID
        self.model = model
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case sessionID, model }

    public init(from decoder: any Decoder) throws {
        try SpeakerWireField.require(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionID: values.decode(UUID.self, forKey: .sessionID),
                      model: values.decode(OmniXPCSpeakerModelReference.self, forKey: .model))
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumReferenceByteCount)
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumReferenceByteCount)
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker session reference is invalid.")
        }
    }
}

public nonisolated struct OmniXPCSpeakerAudioAcknowledgement: Codable, Equatable, Sendable {
    public let session: OmniXPCSpeakerSessionReference
    public let audioSequence: UInt64

    public init(session: OmniXPCSpeakerSessionReference, audioSequence: UInt64) throws {
        guard audioSequence > 0 else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker audio sequence must be positive.")
        }
        self.session = session
        self.audioSequence = audioSequence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case session, audioSequence }

    public init(from decoder: any Decoder) throws {
        try SpeakerWireField.require(decoder, fields: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(session: values.decode(OmniXPCSpeakerSessionReference.self, forKey: .session),
                      audioSequence: values.decode(UInt64.self, forKey: .audioSequence))
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumReferenceByteCount)
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        try SpeakerWireField.validateBytes(bytes, maximumByteCount: OmniXPCSpeakerLimits.maximumReferenceByteCount)
        do { return try JSONDecoder().decode(Self.self, from: bytes) } catch {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker audio acknowledgement is invalid.")
        }
    }
}
