/// Explicit leased diarization validation; production routing remains unchanged.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated struct OmniXPCSortformerLoadState: Sendable {
    let operationID: UUID
    var connectionID: UUID?
    var isLoading = true
}

nonisolated struct OmniXPCSortformerLoadCleanup: Sendable {
    let id: UUID
    let operationID: UUID
    let task: Task<Void, Error>
}

nonisolated struct OmniXPCSortformerModelDirectory: Sendable {
    let directory: URL
    let relativePath: String
    let container: URL
}

extension OmniXPCClient {
    func authorizedSortformerModelDirectory(_ modelDirectory: URL) throws -> OmniXPCSortformerModelDirectory {
        guard modelDirectory.isFileURL,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
              ) else {
            throw OmniXPCFailure.error(.configuration, "Sortformer requires a model in the configured shared container.")
        }
        let containerPath = container.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = modelDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryPath.hasPrefix(containerPath + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model is outside the shared container.")
        }
        let relativePath = String(directoryPath.dropFirst(containerPath.count + 1))
        let directory = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        return OmniXPCSortformerModelDirectory(directory: directory, relativePath: relativePath, container: container)
    }

    func loadSortformer(
        modelDirectory: URL, timeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60),
        operationID: UUID = UUID()
    ) async throws -> OmniXPCSortformerModelReference {
        try Task.checkCancellation()
        guard pendingSortformerLoad == nil, sortformerModel == nil else {
            throw OmniXPCFailure.error(.busy, "Retire the current Sortformer model and any pending load cleanup before loading another model.")
        }
        guard timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer load and cleanup timeouts must be positive.")
        }
        let directory = try authorizedSortformerModelDirectory(modelDirectory)
        let relativePath = directory.relativePath
        pendingSortformerLoad = OmniXPCSortformerLoadState(operationID: operationID)
        do {
            let model: OmniXPCSortformerModelReference = try await perform(
                timeout: timeout, requiredConnectionID: connectionIdentifier,
                nativeRequestID: operationID.uuidString, cancellationTarget: .sortformer
            ) { proxy, resolve in
                let connectionID = self.connectionIdentifier!
                self.pendingSortformerLoad?.connectionID = connectionID
                proxy.loadSortformer(operationID: operationID.uuidString, modelDirectory: relativePath) { modelID, instanceID, error in
                    if let error {
                        resolve(.failure(error))
                    } else if let modelID, let model = UUID(uuidString: modelID),
                              let instanceID, let instance = UUID(uuidString: instanceID) {
                        resolve(.success(OmniXPCSortformerModelReference(
                            modelID: model, serviceInstanceID: instance, connectionID: connectionID
                        )))
                    } else {
                        resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The service returned an invalid Sortformer model identity.")))
                    }
                }
            }
            try Task.checkCancellation()
            try requireConnection(model.connectionID)
            guard closedSortformerModels[model.modelID] == nil else {
                throw OmniXPCFailure.error(.incompatibleService, "The service reused a retired Sortformer model identity.")
            }
            sortformerModel = OmniXPCSortformerModelState(reference: model, loadOperationID: operationID)
            pendingSortformerLoad = nil
            return model
        } catch {
            pendingSortformerLoad?.isLoading = false
            try await closePendingSortformerLoad(timeout: cleanupTimeout)
            throw error
        }
    }

    /// Only a successful scoped drain reply releases a submitted load ticket.
    func closePendingSortformerLoad(timeout: Duration = .seconds(60), requiredOperationID: UUID? = nil) async throws {
        guard let load = pendingSortformerLoad else { return }
        guard requiredOperationID == nil || requiredOperationID == load.operationID else {
            throw OmniXPCFailure.error(.invalidRequest, "The pending Sortformer load belongs to another owner.")
        }
        guard !load.isLoading else {
            throw OmniXPCFailure.error(.busy, "The Sortformer load is still awaiting its reply or cancellation.")
        }
        guard let connectionID = load.connectionID else {
            pendingSortformerLoad = nil
            return
        }
        guard connectionIdentifier == connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The originating Sortformer connection is unavailable; cleanup is not confirmed.")
        }
        if let cleanup = sortformerLoadCleanup, cleanup.operationID == load.operationID {
            try await cleanup.task.value
            return
        }
        let cleanupID = UUID()
        let cleanup = Task { @MainActor in
            defer {
                if self.sortformerLoadCleanup?.id == cleanupID { self.sortformerLoadCleanup = nil }
            }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: connectionID, cancellationTarget: .sortformer
            ) { proxy, resolve in
                proxy.drainSortformerLoad(operationID: load.operationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            if self.pendingSortformerLoad?.operationID == load.operationID { self.pendingSortformerLoad = nil }
        }
        sortformerLoadCleanup = OmniXPCSortformerLoadCleanup(id: cleanupID, operationID: load.operationID, task: cleanup)
        try await cleanup.value
    }

    func unloadSortformer(
        _ model: OmniXPCSortformerModelReference, timeout: Duration = .seconds(60)
    ) async throws {
        let state = try requireSortformerModel(model)
        guard !state.closing, !state.unloading else {
            throw OmniXPCFailure.error(.busy, "The Sortformer model already has pending retirement.")
        }
        state.unloading = true
        defer { state.unloading = false }
        let operationID = UUID().uuidString
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: model.connectionID,
            nativeRequestID: operationID, cancellationTarget: .sortformer
        ) { proxy, resolve in
            proxy.unloadSortformer(operationID: operationID, modelID: model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
        retireSortformerModel(state)
    }
}
#endif
