import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCSpeakerLoadOwnership {
    enum Phase { case notSubmitted, submitted, drained }
    let operationID: UUID
    let kind: OmniXPCSpeakerKind
    private(set) var phase = Phase.notSubmitted
    private var clientIdentity: ObjectIdentifier?

    init(operationID: UUID, kind: OmniXPCSpeakerKind) {
        self.operationID = operationID
        self.kind = kind
    }

    func bind(client: OmniXPCClient, operationID: UUID, kind: OmniXPCSpeakerKind) throws {
        guard self.operationID == operationID, self.kind == kind, phase == .notSubmitted,
              clientIdentity == nil || clientIdentity == ObjectIdentifier(client) else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker load ticket belongs to another attempt.")
        }
        clientIdentity = ObjectIdentifier(client)
    }

    func markSubmitted() {
        precondition(clientIdentity != nil && phase == .notSubmitted)
        phase = .submitted
    }

    func markDrained() { phase = .drained }
}

@MainActor
final class OmniXPCSpeakerLoadState {
    let operationID: UUID
    let kind: OmniXPCSpeakerKind
    let ownership: OmniXPCSpeakerLoadOwnership
    var connectionID: UUID?
    var reference: OmniXPCSpeakerModelReference?
    var isLoading = true
    var closing = false
    var isRetired = false
    var session: OmniXPCSpeakerSessionState?
    var closeTask: Task<Void, Error>?

    init(operationID: UUID, kind: OmniXPCSpeakerKind, ownership: OmniXPCSpeakerLoadOwnership) {
        self.operationID = operationID
        self.kind = kind
        self.ownership = ownership
    }
}

nonisolated struct OmniXPCSpeakerModelDirectory: Sendable {
    let directory: URL
    let relativePath: String
    let container: URL
}

extension OmniXPCClient {
    static let maximumSpeakerScopeCount = 256
    static let maximumSpeakerPollEventCount = 16

    func authorizedSpeakerModelDirectory(_ modelDirectory: URL) throws -> OmniXPCSpeakerModelDirectory {
        guard modelDirectory.isFileURL, let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else { throw OmniXPCFailure.error(.configuration, "Speaker models require the configured shared container.") }
        let containerPath = container.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = modelDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(containerPath + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker model is outside the shared container.")
        }
        let relativePath = String(directoryPath.dropFirst(containerPath.count + 1))
        let directory = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        return OmniXPCSpeakerModelDirectory(directory: directory, relativePath: relativePath, container: container)
    }

    func loadSpeaker(kind: OmniXPCSpeakerKind, modelDirectory: URL, timeout: Duration = .seconds(300),
                     cleanupTimeout: Duration = .seconds(60), operationID: UUID = UUID(),
                     ownership: OmniXPCSpeakerLoadOwnership? = nil) async throws -> OmniXPCSpeakerModelReference {
        let ownership = ownership ?? OmniXPCSpeakerLoadOwnership(operationID: operationID, kind: kind)
        try ownership.bind(client: self, operationID: operationID, kind: kind)
        try Task.checkCancellation()
        guard pendingSpeakerLoad == nil, speakerModel == nil else {
            throw OmniXPCFailure.error(.busy, "Retire the original speaker load before loading another model.")
        }
        guard timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker timeouts must be positive.")
        }
        try requireUnusedSpeakerIdentity(operationID)
        guard speakerLoadIDs.count < Self.maximumSpeakerScopeCount else {
            throw OmniXPCFailure.error(.busy, "The speaker load history is full.")
        }
        let relativePath = try authorizedSpeakerModelDirectory(modelDirectory).relativePath
        let state = OmniXPCSpeakerLoadState(operationID: operationID, kind: kind, ownership: ownership)
        speakerLoadIDs.insert(operationID)
        pendingSpeakerLoad = state
        do {
            let model: OmniXPCSpeakerModelReference = try await perform(
                timeout: timeout, requiredConnectionID: connectionIdentifier,
                nativeRequestID: operationID.uuidString, cancellationTarget: .speaker
            ) { proxy, resolve in
                guard self.pendingSpeakerLoad === state, !state.closing,
                      let connectionID = self.connectionIdentifier else {
                    resolve(.failure(OmniXPCFailure.error(.cancelled, "The speaker load was closed before submission.")))
                    return
                }
                state.connectionID = connectionID
                ownership.markSubmitted()
                proxy.loadSpeaker(operationID: operationID.uuidString, kind: Int(kind.rawValue),
                                  modelDirectory: relativePath, clientConnectionID: connectionID.uuidString) { bytes, error in
                    do {
                        if let error { throw error } else { }
                        guard let bytes else {
                            throw OmniXPCFailure.error(.incompatibleService, "The service returned no speaker model reference.")
                        }
                        let model = try OmniXPCSpeakerModelReference.decode(bytes)
                        guard model.kind == kind, model.loadOperationID == operationID,
                              model.connectionID == connectionID, model.modelID != operationID else {
                            throw OmniXPCFailure.error(.incompatibleService, "The speaker model reference does not match its load.")
                        }
                        resolve(.success(model))
                    } catch { resolve(.failure(error)) }
                }
            }
            try Task.checkCancellation()
            try requireConnection(model.connectionID)
            guard pendingSpeakerLoad === state, !state.closing, !state.isRetired else {
                throw OmniXPCFailure.error(.cancelled, "The speaker load is closing.")
            }
            try requireUnusedSpeakerIdentity(model.modelID)
            if let identity = speakerServiceIdentity, identity.connectionID == model.connectionID {
                guard identity.serviceInstanceID == model.serviceInstanceID else {
                    throw OmniXPCFailure.error(.incompatibleService, "The speaker service identity changed on its transport.")
                }
            } else { }
            speakerServiceIdentity = (model.connectionID, model.serviceInstanceID)
            state.reference = model
            state.isLoading = false
            speakerModel = state
            pendingSpeakerLoad = nil
            return model
        } catch {
            state.isLoading = false
            try await closeSpeakerScope(state, timeout: cleanupTimeout)
            throw error
        }
    }

    func requireUnusedSpeakerIdentity(_ identifier: UUID) throws {
        guard identifier.uuidString != "00000000-0000-0000-0000-000000000000",
              !speakerLoadIDs.contains(identifier), !speakerSessionIDs.contains(identifier),
              !speakerUnloadIDs.contains(identifier), closedSpeakerModels[identifier] == nil,
              speakerModel?.reference?.modelID != identifier else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker business identity is invalid or already used.")
        }
    }
}
#endif
