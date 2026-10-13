/// Connection-scoped Silero loads with retryable original-load retirement.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated struct OmniXPCSileroLoadState: Sendable {
    let operationID: UUID
    var connectionID: UUID?
    var isLoading = true
}

nonisolated struct OmniXPCSileroLoadCleanup: Sendable {
    let id: UUID
    let operationID: UUID
    let task: Task<Void, Error>
}

extension OmniXPCClient {
    func loadSilero(
        modelDirectory: String, timeout: Duration = .seconds(240), cleanupTimeout: Duration = .seconds(60),
        operationID: UUID = UUID()
    ) async throws -> OmniXPCSileroModelReference {
        try Task.checkCancellation()
        guard pendingSileroLoad == nil, sileroModel == nil else {
            throw OmniXPCFailure.error(.busy, "Retire the current Silero model and pending load before loading another model.")
        }
        guard timeout > .zero, cleanupTimeout > .zero, !sileroLoadIDs.contains(operationID) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero operation identity or timeout is invalid.")
        }
        guard sileroLoadIDs.count < OmniXPCSileroLimits.maximumLoadsPerConnection else {
            throw OmniXPCFailure.error(.busy, "The Silero client load ledger is full.")
        }
        sileroLoadIDs.insert(operationID)
        pendingSileroLoad = OmniXPCSileroLoadState(operationID: operationID)
        do {
            let model: OmniXPCSileroModelReference = try await perform(
                timeout: timeout, requiredConnectionID: connectionIdentifier,
                nativeRequestID: operationID.uuidString, cancellationTarget: .silero
            ) { proxy, resolve in
                let connectionID = self.connectionIdentifier!
                self.pendingSileroLoad?.connectionID = connectionID
                proxy.loadSilero(operationID: operationID.uuidString, modelDirectory: modelDirectory) { modelID, instanceID, error in
                    if let error {
                        resolve(.failure(error))
                    } else if let modelID, let model = UUID(uuidString: modelID),
                              let instanceID, let instance = UUID(uuidString: instanceID) {
                        resolve(.success(OmniXPCSileroModelReference(
                            modelID: model, serviceInstanceID: instance, connectionID: connectionID
                        )))
                    } else {
                        resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The service returned an invalid Silero model identity.")))
                    }
                }
            }
            try Task.checkCancellation()
            try requireConnection(model.connectionID)
            guard closedSileroModels[model.modelID] == nil else {
                throw OmniXPCFailure.error(.incompatibleService, "The service reused a retired Silero model identity.")
            }
            sileroModel = OmniXPCSileroModelState(reference: model, loadOperationID: operationID)
            pendingSileroLoad = nil
            return model
        } catch {
            pendingSileroLoad?.isLoading = false
            try await closePendingSileroLoad(timeout: cleanupTimeout, requiredOperationID: operationID)
            throw error
        }
    }

    func closePendingSileroLoad(timeout: Duration = .seconds(60), requiredOperationID: UUID? = nil) async throws {
        guard let load = pendingSileroLoad else {
            guard requiredOperationID == nil || closedSileroLoadIDs.contains(requiredOperationID!) else {
                throw OmniXPCFailure.error(.invalidRequest, "The Silero load has no confirmed retirement.")
            }
            return
        }
        guard requiredOperationID == nil || requiredOperationID == load.operationID else {
            throw OmniXPCFailure.error(.invalidRequest, "The pending Silero load belongs to another owner.")
        }
        guard !load.isLoading else {
            throw OmniXPCFailure.error(.busy, "The Silero load is still awaiting its reply or cancellation.")
        }
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero cleanup timeout must be positive.")
        }
        guard let connectionID = load.connectionID else {
            closedSileroLoadIDs.insert(load.operationID)
            pendingSileroLoad = nil
            return
        }
        guard connectionIdentifier == connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The originating Silero connection is unavailable; cleanup is not confirmed.")
        }
        if let cleanup = sileroLoadCleanup, cleanup.operationID == load.operationID {
            return try await cleanup.task.value
        }
        let cleanupID = UUID()
        let cleanup = Task { @MainActor in
            defer {
                if self.sileroLoadCleanup?.id == cleanupID { self.sileroLoadCleanup = nil }
            }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: connectionID, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.drainSileroLoad(operationID: load.operationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            if self.pendingSileroLoad?.operationID == load.operationID {
                self.closedSileroLoadIDs.insert(load.operationID)
                self.pendingSileroLoad = nil
            }
        }
        sileroLoadCleanup = OmniXPCSileroLoadCleanup(id: cleanupID, operationID: load.operationID, task: cleanup)
        try await cleanup.value
    }

    func unloadSilero(_ model: OmniXPCSileroModelReference, timeout: Duration = .seconds(60)) async throws {
        let state = try requireSileroModel(model)
        guard !state.closing, !state.unloading else {
            throw OmniXPCFailure.error(.busy, "The Silero model already has pending retirement.")
        }
        state.unloading = true
        defer { state.unloading = false }
        let operationID = UUID().uuidString
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: model.connectionID, nativeRequestID: operationID,
            cancellationTarget: .silero
        ) { proxy, resolve in
            proxy.unloadSilero(operationID: operationID, modelID: model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
        retireSileroModel(state)
    }

    func sileroSpeechTimestamps(
        samples16k: [Float], settings: OmniXPCSileroSettings, model: OmniXPCSileroModelReference,
        timeout: Duration = .seconds(240)
    ) async throws -> [Range<Int>] {
        let state = try requireSileroModel(model)
        guard !state.closing, !state.unloading else {
            throw OmniXPCFailure.error(.busy, "The Silero model is retiring.")
        }
        try settings.validate()
        guard !samples16k.isEmpty, samples16k.count <= OmniXPCProtocolLimits.maximumSampleCount,
              samples16k.allSatisfy(\.isFinite) else {
            throw OmniXPCFailure.error(.invalidRequest, "Silero audio must contain at most 30 seconds of finite mono 16 kHz samples.")
        }
        let audio = OmniVoiceActivityStream.float32LittleEndian(samples16k)
        let encodedSettings = try settings.encoded()
        let requestID = UUID()
        let ranges: [Range<Int>] = try await perform(
            timeout: timeout, requiredConnectionID: model.connectionID, nativeRequestID: requestID.uuidString,
            cancellationModelID: model.modelID.uuidString, cancellationTarget: .silero
        ) { proxy, resolve in
            proxy.sileroSpeechTimestamps(
                requestID: requestID.uuidString, modelID: model.modelID.uuidString,
                audio: audio, settings: encodedSettings
            ) { reply, error in
                do {
                    if let error { throw error }
                    guard let reply else {
                        throw OmniXPCFailure.error(.incompatibleService, "The Silero service returned no result.")
                    }
                    let batch = try OmniXPCSileroTimestampBatch.decode(reply)
                    guard batch.serviceInstanceID == model.serviceInstanceID, batch.modelID == model.modelID,
                          batch.requestID == requestID, batch.sampleCount == samples16k.count else {
                        throw OmniXPCFailure.error(.incompatibleService, "The Silero service returned a stale or mismatched result.")
                    }
                    resolve(.success(batch.timestamps.map { Int($0.startSample)..<Int($0.endSample) }))
                } catch {
                    resolve(.failure(error))
                }
            }
        }
        try Task.checkCancellation()
        return ranges
    }
}
#endif
