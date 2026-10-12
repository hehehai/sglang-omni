/// Explicit leased diarization validation; production routing remains unchanged.
import Foundation
import OmniXPCContracts

#if os(macOS)
private nonisolated struct OmniXPCSortformerLoadReplyFailure: Error {
    let connectionID: UUID
}

extension OmniXPCClient {
    func loadSortformer(
        modelDirectory: URL, timeout: Duration = .seconds(300)
    ) async throws -> OmniXPCSortformerModelReference {
        try Task.checkCancellation()
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
        _ = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        let operationID = UUID().uuidString
        let model: OmniXPCSortformerModelReference
        do {
            model = try await perform(
                timeout: timeout, requiredConnectionID: connectionIdentifier,
                nativeRequestID: operationID, cancellationTarget: .sortformer
            ) { proxy, resolve in
                let connectionID = self.connectionIdentifier!
                proxy.loadSortformer(operationID: operationID, modelDirectory: relativePath) { modelID, instanceID, error in
                    if let error {
                        resolve(.failure(error))
                    } else if let modelID, let model = UUID(uuidString: modelID),
                              let instanceID, let instance = UUID(uuidString: instanceID) {
                        resolve(.success(OmniXPCSortformerModelReference(
                            modelID: model, serviceInstanceID: instance, connectionID: connectionID
                        )))
                    } else {
                        resolve(.failure(OmniXPCSortformerLoadReplyFailure(connectionID: connectionID)))
                    }
                }
            }
        } catch let failure as OmniXPCSortformerLoadReplyFailure {
            if connectionIdentifier == failure.connectionID {
                // Note (Omni): no model reference exists, so retire only this originating load operation.
                let cleanup = Task { @MainActor in
                    let _: Void = try await self.perform(
                        timeout: timeout, requiredConnectionID: failure.connectionID,
                        nativeRequestID: operationID, cancellationTarget: .sortformer
                    ) { proxy, resolve in
                        proxy.cancelSortformerRequest(requestID: operationID, modelID: nil) { error in
                            if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                        }
                    }
                }
                try await cleanup.value
            }
            throw OmniXPCFailure.error(.incompatibleService, "The service returned an invalid Sortformer model identity.")
        }
        if Task.isCancelled {
            let cleanup = Task { @MainActor in try await self.unloadSortformer(model) }
            try await cleanup.value
            throw CancellationError()
        }
        try requireConnection(model.connectionID)
        return model
    }

    func unloadSortformer(
        _ model: OmniXPCSortformerModelReference, timeout: Duration = .seconds(60)
    ) async throws {
        try requireConnection(model.connectionID)
        let operationID = UUID().uuidString
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: model.connectionID,
            nativeRequestID: operationID, cancellationTarget: .sortformer
        ) { proxy, resolve in
            proxy.unloadSortformer(operationID: operationID, modelID: model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
    }
}
#endif
