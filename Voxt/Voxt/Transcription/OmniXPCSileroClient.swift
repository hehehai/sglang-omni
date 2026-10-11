/// Explicit offline VAD validation; production VAD routing remains unchanged.
import Foundation
import OmniXPCContracts

#if os(macOS)
extension OmniXPCClient {
    func loadSilero(modelDirectory: String, timeout: Duration = .seconds(240)) async throws -> OmniXPCSileroModelReference {
        let operationID = UUID().uuidString
        let model: OmniXPCSileroModelReference = try await perform(
            timeout: timeout, nativeRequestID: operationID, cancellationTarget: .silero
        ) { proxy, resolve in
            let connectionID = self.connectionIdentifier!
            proxy.loadSilero(operationID: operationID, modelDirectory: modelDirectory) { modelID, instanceID, error in
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
        if Task.isCancelled {
            let cleanup = Task { @MainActor in try await self.unloadSilero(model) }
            try await cleanup.value
            throw CancellationError()
        }
        return model
    }

    func unloadSilero(_ model: OmniXPCSileroModelReference, timeout: Duration = .seconds(60)) async throws {
        try requireConnection(model.connectionID)
        let operationID = UUID().uuidString
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: model.connectionID, nativeRequestID: operationID,
            cancellationTarget: .silero
        ) { proxy, resolve in
            proxy.unloadSilero(operationID: operationID, modelID: model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
    }

    func sileroSpeechTimestamps(
        samples16k: [Float], settings: OmniXPCSileroSettings, model: OmniXPCSileroModelReference,
        timeout: Duration = .seconds(240)
    ) async throws -> [Range<Int>] {
        try requireConnection(model.connectionID)
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
