import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniSpeakerInferenceEngine: @unchecked Sendable {
    nonisolated final class ConnectionLifetime: @unchecked Sendable {
        enum LoadState { case active, closed }
        enum Business { case model, session, unload }
        let id = UUID()
        // note (assistant): All connection and scope state is guarded by the owning engine lock.
        var isActive = true
        var clientConnectionID: UUID?
        var loads: [UUID: LoadState] = [:]
        var businessIDs: [UUID: Business] = [:]
        var models: [UUID: OmniXPCSpeakerModelReference] = [:]
        var sessions: [UUID: SessionRecord] = [:]
        var unloads: [UUID: OmniXPCSpeakerModelReference] = [:]

        func recordBusiness(_ identifier: UUID, kind: Business) throws {
            guard loads[identifier] == nil, businessIDs[identifier] == nil else {
                throw SpeakerCoreModel.error(.invalid)
            }
            guard businessIDs.values.filter({ $0 == kind }).count < maximumLedgerCount else {
                throw SpeakerCoreModel.error(.limit)
            }
            businessIDs[identifier] = kind
        }
    }

    static let maximumLedgerCount = 256
    static let maximumPollEventCount = 16
    enum ModelState { case unloaded, loading, ready, closing }
    private let configuration: OmniXPCConfiguration
    let queue = DispatchQueue(label: "Voxt.Omni.XPC.speaker")
    let lock = NSLock()
    var modelState: ModelState = .unloaded
    var owner: ConnectionLifetime?
    var loadOperationID: UUID?
    var modelReference: OmniXPCSpeakerModelReference?
    var model: SpeakerCoreModel?
    var session: SessionRecord?
    var cleanupPending = false
    var nextNativeSessionID: UInt64 = 1

    init(configuration: OmniXPCConfiguration) { self.configuration = configuration }

    func admitLoad(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                   lifetime: ConnectionLifetime, reply: @escaping @Sendable (Data?, NSError?) -> Void) throws {
        let operation = try identifier(operationID)
        let clientConnection = try identifier(clientConnectionID)
        guard let rawKind = Int32(exactly: kind), let kind = OmniXPCSpeakerKind(rawValue: rawKind),
              !modelDirectory.isEmpty, !modelDirectory.contains("\0"),
              modelDirectory.utf8.count <= OmniXPCProtocolLimits.maximumModelPathByteCount else {
            throw SpeakerCoreModel.error(.invalid)
        }
        try lock.withLock {
            guard lifetime.isActive else { throw SpeakerCoreModel.error(.cancelled) }
            guard lifetime.clientConnectionID == nil || lifetime.clientConnectionID == clientConnection,
                  lifetime.loads[operation] == nil, lifetime.businessIDs[operation] == nil else {
                throw SpeakerCoreModel.error(.invalid)
            }
            guard lifetime.loads.count < Self.maximumLedgerCount else { throw SpeakerCoreModel.error(.limit) }
            guard modelState == .unloaded else { throw SpeakerCoreModel.error(.busy) }
            lifetime.clientConnectionID = clientConnection
            lifetime.loads[operation] = .active
            owner = lifetime
            loadOperationID = operation
            modelState = .loading
            let shell = SpeakerCoreModel(kind: kind)
            model = shell
            queue.async { [self] in
                do {
                    let directoryLease = try OmniServiceIdentity.modelDirectoryLease(
                        relativePath: modelDirectory, configuration: configuration
                    )
                    guard lock.withLock({ lifetime.isActive && modelState == .loading }) else {
                        throw SpeakerCoreModel.error(.cancelled)
                    }
                    try shell.load(directoryLease: directoryLease)
                    let encoded = try lock.withLock { () throws -> Data in
                        guard lifetime.isActive, modelState == .loading else { throw SpeakerCoreModel.error(.cancelled) }
                        var modelID = UUID()
                        while lifetime.loads[modelID] != nil || lifetime.businessIDs[modelID] != nil { modelID = UUID() }
                        let reference = try OmniXPCSpeakerModelReference(
                            kind: kind, modelID: modelID, serviceInstanceID: OmniServiceIdentity.instanceID,
                            connectionID: clientConnection, loadOperationID: operation
                        )
                        let encoded = try reference.encoded()
                        try lifetime.recordBusiness(modelID, kind: .model)
                        lifetime.models[modelID] = reference
                        modelReference = reference
                        modelState = .ready
                        return encoded
                    }
                    reply(encoded, nil)
                } catch {
                    lock.withLock { modelState = .closing }
                    reply(nil, error as NSError)
                }
            }
        }
    }

    func requireValidationIdle() throws {
        try lock.withLock {
            guard modelState == .unloaded, model == nil, session == nil, owner == nil, !cleanupPending else {
                throw SpeakerCoreModel.error(.busy)
            }
        }
    }

    func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value),
              identifier.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw SpeakerCoreModel.error(.invalid)
        }
        return identifier
    }

    func requireOwner(_ lifetime: ConnectionLifetime, reference: OmniXPCSpeakerModelReference) throws {
        guard lifetime.isActive, owner === lifetime, modelReference == reference,
              lifetime.clientConnectionID == reference.connectionID,
              loadOperationID == reference.loadOperationID else { throw SpeakerCoreModel.error(.invalid) }
    }

    func requireLiveSession(_ lifetime: ConnectionLifetime, reference: OmniXPCSpeakerSessionReference) throws -> SessionRecord {
        try requireOwner(lifetime, reference: reference.model)
        guard let session, session.reference == reference, !session.isClosing, !session.isCancelled, !session.isClosed,
              modelState == .ready else { throw SpeakerCoreModel.error(.invalid) }
        return session
    }
}
#endif
