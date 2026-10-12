/// Explicit bounded-final client; no production factory or saved model selection uses this route.
import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCBatchLoadState {
    let operationID: UUID
    let kind: OmniXPCBatchKind
    var connectionID: UUID?
    var reference: OmniXPCBatchModelReference?
    var isLoading = true
    var closing = false
    var requesting = false
    var closeTask: Task<Void, Error>?

    init(operationID: UUID, kind: OmniXPCBatchKind) {
        self.operationID = operationID
        self.kind = kind
    }
}

extension OmniXPCClient {
    func loadBatch(kind: OmniXPCBatchKind, modelDirectory: URL, timeout: Duration = .seconds(300),
                   cleanupTimeout: Duration = .seconds(60), operationID: UUID = UUID()) async throws -> OmniXPCBatchModelReference {
        try Task.checkCancellation()
        guard pendingBatchLoad == nil, batchModel == nil else {
            throw OmniXPCFailure.error(.busy, "Retire the original batch load before loading another model.")
        }
        guard timeout > .zero, cleanupTimeout > .zero, !batchLoadIDs.contains(operationID),
              closedBatchModels[operationID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch load identity or timeout is invalid.")
        }
        guard batchLoadIDs.count < OmniXPCBatchLimits.maximumLoadsPerConnection else {
            throw OmniXPCBatchFailure.error(.limit)
        }
        guard modelDirectory.isFileURL, let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else { throw OmniXPCFailure.error(.configuration, "Batch models require the configured shared container.") }
        let containerPath = container.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = modelDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(containerPath + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch model is outside the shared container.")
        }
        let relativePath = String(directoryPath.dropFirst(containerPath.count + 1))
        _ = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        let state = OmniXPCBatchLoadState(operationID: operationID, kind: kind)
        batchLoadIDs.insert(operationID)
        pendingBatchLoad = state
        do {
            let model: OmniXPCBatchModelReference = try await perform(
                timeout: timeout, requiredConnectionID: connectionIdentifier,
                nativeRequestID: operationID.uuidString, cancellationTarget: .batch
            ) { proxy, resolve in
                let connectionID = self.connectionIdentifier!
                state.connectionID = connectionID
                proxy.loadBatch(operationID: operationID.uuidString, kind: kind.rawValue, modelDirectory: relativePath) {
                    modelID, instanceID, error in
                    if let error { resolve(.failure(error)) } else if
                        let modelID, modelID.utf8.count == 36, let model = UUID(uuidString: modelID),
                        let instanceID, instanceID.utf8.count == 36, let instance = UUID(uuidString: instanceID), model != operationID {
                        resolve(.success(OmniXPCBatchModelReference(
                            kind: kind, modelID: model, serviceInstanceID: instance,
                            connectionID: connectionID, loadOperationID: operationID
                        )))
                    } else {
                        resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The service returned an invalid batch model identity.")))
                    }
                }
            }
            try Task.checkCancellation()
            try requireConnection(model.connectionID)
            guard closedBatchModels[model.modelID] == nil, !batchLoadIDs.contains(model.modelID) else {
                throw OmniXPCFailure.error(.incompatibleService, "The service reused a batch identity.")
            }
            state.reference = model
            state.isLoading = false
            batchModel = state
            pendingBatchLoad = nil
            return model
        } catch {
            state.isLoading = false
            try await closePendingBatchLoad(timeout: cleanupTimeout, requiredOperationID: operationID)
            throw error
        }
    }

    func transcribeBatch(_ model: OmniXPCBatchModelReference, audio: Data, settings: OmniXPCBatchSettings,
                         timeout: Duration = .seconds(300)) async throws -> OmniXPCBatchResult {
        let state = try requireBatchModel(model)
        guard !state.closing, !state.requesting else { throw OmniXPCBatchFailure.error(.busy) }
        guard settings.kind == model.kind else { throw OmniXPCBatchFailure.error(.invalid) }
        let settingsBytes = try settings.encoded()
        _ = try OmniXPCRequestValidation.audioSamples(audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount)
        let requestID = UUID()
        state.requesting = true
        defer { state.requesting = false }
        do {
            let bytes: Data = try await perform(
                timeout: timeout, requiredConnectionID: model.connectionID,
                nativeRequestID: requestID.uuidString, cancellationModelID: model.modelID.uuidString, cancellationTarget: .batch
            ) { proxy, resolve in
                proxy.transcribeBatch(requestID: requestID.uuidString, modelID: model.modelID.uuidString,
                                      audio: audio, settings: settingsBytes) { bytes, error in
                    if let error { resolve(.failure(error)) } else if let bytes { resolve(.success(bytes)) } else {
                        resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The service returned no batch result.")))
                    }
                }
            }
            let result = try OmniXPCBatchResult.decode(bytes)
            guard result.kind == model.kind, result.modelID == model.modelID,
                  result.requestID == requestID, result.serviceInstanceID == model.serviceInstanceID else {
                throw OmniXPCFailure.error(.incompatibleService, "The batch result belongs to another request.")
            }
            return result
        } catch {
            // note (assistant): A lost reply is not a request barrier; keep the original model claim until scoped close succeeds.
            state.closing = true
            throw error
        }
    }
}
#endif
