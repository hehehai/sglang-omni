import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniBatchInferenceEngine: @unchecked Sendable {
    nonisolated final class ConnectionLifetime: @unchecked Sendable {
        enum LoadState { case active, closed }
        let id = UUID()
        var isActive = true
        var loads: [UUID: LoadState] = [:]
        enum Business { case model, request, unload }
        var businessIDs: [UUID: Business] = [:]

        func recordBusiness(_ identifier: UUID, kind: Business) throws {
            guard loads[identifier] == nil, businessIDs[identifier] == nil else {
                throw OmniXPCBatchFailure.error(.invalid)
            }
            guard businessIDs.values.filter({ $0 == kind }).count < OmniXPCBatchLimits.maximumOperationsPerConnection else {
                throw OmniXPCBatchFailure.error(.limit)
            }
            businessIDs[identifier] = kind
        }
    }

    enum ModelState { case unloaded, loading, ready, closing }
    private let configuration: OmniXPCConfiguration
    let queue = DispatchQueue(label: "Voxt.Omni.XPC.batch")
    let lock = NSLock()
    var modelState: ModelState = .unloaded
    var owner: ConnectionLifetime?
    var loadOperationID: UUID?
    var modelID: UUID?
    var model: BatchCoreModel?
    var request: BatchCoreRequest?
    var requestID: UUID?
    var requestIDs: Set<UUID> = []
    var cleanupPending = false

    init(configuration: OmniXPCConfiguration) { self.configuration = configuration }

    func admitLoad(operationID: String, kind: Int, modelDirectory: String, lifetime: ConnectionLifetime,
                   reply: @escaping @Sendable (String?, String?, NSError?) -> Void) throws {
        let operation = try identifier(operationID)
        guard let kind = OmniXPCBatchKind(rawValue: kind), !modelDirectory.isEmpty,
              modelDirectory.utf8.count <= OmniXPCProtocolLimits.maximumModelPathByteCount,
              !modelDirectory.contains("\0") else { throw OmniXPCBatchFailure.error(.invalid) }
        try lock.withLock {
            guard lifetime.isActive else { throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.") }
            guard lifetime.loads[operation] == nil, lifetime.businessIDs[operation] == nil else {
                throw OmniXPCBatchFailure.error(.invalid)
            }
            guard modelState == .unloaded else { throw OmniXPCBatchFailure.error(.busy) }
            guard lifetime.loads.count < OmniXPCBatchLimits.maximumLoadsPerConnection else {
                throw OmniXPCBatchFailure.error(.limit)
            }
            lifetime.loads[operation] = .active
            owner = lifetime
            loadOperationID = operation
            modelState = .loading
            // note (assistant): Queue admission under the lock orders every cleanup barrier after accepted work.
            queue.async { [self] in
                do {
                    let directoryLease = try OmniServiceIdentity.modelDirectoryLease(
                        relativePath: modelDirectory, configuration: configuration
                    )
                    guard lock.withLock({ lifetime.isActive && modelState == .loading }) else {
                        throw OmniXPCBatchFailure.error(.cancelled)
                    }
                    let loaded = try BatchCoreModel(kind: kind, directoryLease: directoryLease)
                    let published = try lock.withLock { () throws -> UUID? in
                        model = loaded
                        guard lifetime.isActive, modelState == .loading else { return nil }
                        let newModelID = UUID()
                        try lifetime.recordBusiness(newModelID, kind: .model)
                        modelID = newModelID
                        modelState = .ready
                        return newModelID
                    }
                    if let published {
                        reply(published.uuidString, OmniServiceIdentity.instanceID.uuidString, nil)
                    } else {
                        throw OmniXPCBatchFailure.error(.cancelled)
                    }
                } catch {
                    lock.withLock {
                        if model == nil { clearModel() } else {
                            modelState = .closing
                            enqueueCleanup(lifetime: lifetime, operation: operation)
                        }
                    }
                    reply(nil, nil, error as NSError)
                }
            }
        }
    }

    func transcribe(requestID: String, modelID: String, audio: Data, settings: Data, lifetime: ConnectionLifetime,
                    reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        do {
            let requestedID = try identifier(requestID)
            let requestedModelID = try identifier(modelID)
            let settings = try OmniXPCBatchSettings.decode(settings)
            guard !audio.isEmpty, audio.count <= OmniXPCProtocolLimits.maximumAudioByteCount,
                  audio.count % MemoryLayout<UInt32>.size == 0 else { throw OmniXPCBatchFailure.error(.invalid) }
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard modelState == .ready, request == nil else { throw OmniXPCBatchFailure.error(.busy) }
                guard let model, settings.kind == model.kind else { throw OmniXPCBatchFailure.error(.invalid) }
                try lifetime.recordBusiness(requestedID, kind: .request)
                let lease = BatchCoreRequest(model: model)
                request = lease
                self.requestID = requestedID
                requestIDs.insert(requestedID)
                queue.async { [self] in
                    let outcome: Result<Data, Error>
                    do {
                        let samples = try OmniXPCRequestValidation.audioSamples(
                            audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount
                        )
                        try lease.create()
                        outcome = .success(try lease.transcribe(
                            samples: samples, settings: settings, serviceInstanceID: OmniServiceIdentity.instanceID,
                            modelID: requestedModelID, requestID: requestedID
                        ).encoded())
                    } catch { outcome = .failure(error) }
                    do {
                        try lease.drainAndDestroy()
                        let canReply = lock.withLock {
                            request = nil
                            self.requestID = nil
                            return lifetime.isActive && modelState == .ready
                        }
                        guard canReply else { throw OmniXPCBatchFailure.error(.cancelled) }
                        reply(try outcome.get(), nil)
                    } catch { reply(nil, error as NSError) }
                }
            }
        } catch { reply(nil, error as NSError) }
    }

    func cancel(requestID: String, modelID: String?, lifetime: ConnectionLifetime) throws {
        let requestedID = try identifier(requestID)
        let requestedModelID = try modelID.map(identifier)
        let cancelling = try lock.withLock { () throws -> BatchCoreRequest? in
            guard lifetime.isActive else { throw OmniXPCFailure.error(.disconnected, "The XPC connection is closing.") }
            if let requestedModelID {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard requestIDs.contains(requestedID) else { throw OmniXPCBatchFailure.error(.invalid) }
                return self.requestID == requestedID ? request : nil
            } else if lifetime.loads[requestedID] == .closed {
                return nil
            } else {
                guard owner === lifetime, loadOperationID == requestedID else { throw OmniXPCBatchFailure.error(.invalid) }
                modelState = .closing
                enqueueCleanup(lifetime: lifetime, operation: requestedID)
                return request
            }
        }
        cancelling?.cancel()
    }

    func disconnect(lifetime: ConnectionLifetime) {
        let cancelling = lock.withLock { () -> BatchCoreRequest? in
            lifetime.isActive = false
            guard owner === lifetime, let loadOperationID else { return nil }
            modelState = .closing
            enqueueCleanup(lifetime: lifetime, operation: loadOperationID)
            return request
        }
        cancelling?.cancel()
    }

    func requireValidationIdle() throws {
        try lock.withLock {
            guard modelState == .unloaded, model == nil, request == nil, owner == nil else {
                throw OmniXPCBatchFailure.error(.busy)
            }
        }
    }

    func identifier(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let identifier = UUID(uuidString: value) else {
            throw OmniXPCBatchFailure.error(.invalid)
        }
        return identifier
    }

    func requireOwner(_ lifetime: ConnectionLifetime, modelID: UUID) throws {
        guard lifetime.isActive, owner === lifetime, self.modelID == modelID else {
            throw OmniXPCBatchFailure.error(.invalid)
        }
    }
}
#endif
