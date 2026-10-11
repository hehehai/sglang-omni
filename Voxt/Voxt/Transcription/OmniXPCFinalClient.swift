/// Explicit model/session operations for bounded final-only XPC transcription.
import Foundation

#if os(macOS)
extension OmniXPCClient {
    func loadQwen(modelDirectory: String, timeout: Duration = .seconds(240)) async throws -> OmniXPCModelReference {
        let operationID = UUID().uuidString
        return try await perform(timeout: timeout, nativeRequestID: operationID, resetConnectionOnCancel: true) { proxy, resolve in
            let connectionID = self.connectionIdentifier!
            proxy.loadQwen(operationID: operationID, modelDirectory: modelDirectory) { modelID, instanceID, error in
                if let error {
                    resolve(.failure(error))
                } else if let modelID, let model = UUID(uuidString: modelID),
                          let instanceID, let instance = UUID(uuidString: instanceID) {
                    resolve(.success(OmniXPCModelReference(modelID: model, serviceInstanceID: instance, connectionID: connectionID)))
                } else {
                    resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The service returned an invalid model identity.")))
                }
            }
        }
    }

    func unloadQwen(_ model: OmniXPCModelReference, timeout: Duration = .seconds(60)) async throws {
        try requireConnection(model.connectionID)
        let operationID = UUID().uuidString
        let _: Void = try await perform(timeout: timeout, nativeRequestID: operationID, resetConnectionOnCancel: true) { proxy, resolve in
            proxy.unloadQwen(operationID: operationID, modelID: model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
    }

    func startFinalSession(
        model: OmniXPCModelReference, language: String?, context: String? = nil,
        maximumTokenCount: Int, sessionID: UUID = UUID(), timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCFinalSessionReference {
        try requireConnection(model.connectionID)
        try OmniXPCRequestValidation.options(language: language, context: context, maximumTokenCount: maximumTokenCount)
        return try await perform(timeout: timeout, nativeRequestID: sessionID.uuidString, cancellationModelID: model.modelID.uuidString) { proxy, resolve in
            proxy.startFinalSession(
                sessionID: sessionID.uuidString, modelID: model.modelID.uuidString,
                language: language, context: context, maximumTokenCount: maximumTokenCount
            ) { instanceID, error in
                if let error {
                    resolve(.failure(error))
                } else if let instanceID, UUID(uuidString: instanceID) == model.serviceInstanceID {
                    resolve(.success(OmniXPCFinalSessionReference(
                        sessionID: sessionID, model: model, language: language, maximumTokenCount: maximumTokenCount
                    )))
                } else {
                    resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The model belongs to a different service instance.")))
                }
            }
        }
    }

    func pushFinalAudio(
        _ audio: Data, to session: OmniXPCFinalSessionReference, sequence: Int, timeout: Duration = .seconds(30)
    ) async throws {
        try requireConnection(session.model.connectionID)
        guard audio.count <= OmniXPCProtocolLimits.maximumChunkAudioByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The final audio chunk exceeds its transport budget.")
        }
        _ = try OmniXPCRequestValidation.samples(
            audio: audio, language: session.language, context: nil, maximumTokenCount: session.maximumTokenCount
        )
        let accepted: Int = try await perform(timeout: timeout, nativeRequestID: session.sessionID.uuidString, cancellationModelID: session.model.modelID.uuidString) { proxy, resolve in
            proxy.pushFinalAudio(sessionID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString, sequence: sequence, audio: audio) { accepted, error in
                if let error { resolve(.failure(error)) } else { resolve(.success(accepted)) }
            }
        }
        guard accepted == sequence else {
            throw OmniXPCFailure.error(.incompatibleService, "The service acknowledged a different audio chunk.")
        }
    }

    func finishFinalSession(
        _ session: OmniXPCFinalSessionReference, timeout: Duration = .seconds(240)
    ) async throws -> ASRTranscriptionResult {
        try requireConnection(session.model.connectionID)
        return try await perform(timeout: timeout, nativeRequestID: session.sessionID.uuidString, cancellationModelID: session.model.modelID.uuidString) { proxy, resolve in
            proxy.finishFinalSession(sessionID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString) { echoedID, instanceID, text, language, count, limited, error in
                if let error {
                    resolve(.failure(error))
                } else if let echoedID, UUID(uuidString: echoedID) == session.sessionID,
                          let instanceID, UUID(uuidString: instanceID) == session.model.serviceInstanceID,
                          let text, count >= 0, count <= session.maximumTokenCount {
                    resolve(.success(ASRTranscriptionResult(
                        text: text, language: language,
                        languageProvenance: session.language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? .requested : (language == nil ? .unknown : .detected),
                        generationMetadata: ASRGenerationMetadata(generatedTokenCount: count, hitLengthLimit: limited)
                    )))
                } else {
                    resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The service returned a stale or invalid final result.")))
                }
            }
        }
    }

    func cancelFinalSession(_ session: OmniXPCFinalSessionReference, timeout: Duration = .seconds(30)) async throws {
        try requireConnection(session.model.connectionID)
        let _: Void = try await perform(timeout: timeout) { proxy, resolve in
            proxy.cancelRequest(requestID: session.sessionID.uuidString, modelID: session.model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
    }

    func transcribeFinal(
        model: OmniXPCModelReference, audio: Data, language: String?, context: String? = nil,
        maximumTokenCount: Int, timeout: Duration = .seconds(240)
    ) async throws -> ASRTranscriptionResult {
        _ = try OmniXPCRequestValidation.samples(
            audio: audio, language: language, context: context, maximumTokenCount: maximumTokenCount
        )
        let session = try await startFinalSession(
            model: model, language: language, context: context, maximumTokenCount: maximumTokenCount
        )
        do {
            var sequence = 1
            for offset in stride(from: 0, to: audio.count, by: OmniXPCProtocolLimits.maximumChunkAudioByteCount) {
                try Task.checkCancellation()
                let end = min(offset + OmniXPCProtocolLimits.maximumChunkAudioByteCount, audio.count)
                try await pushFinalAudio(audio.subdata(in: offset..<end), to: session, sequence: sequence)
                sequence += 1
            }
            return try await finishFinalSession(session, timeout: timeout)
        } catch {
            let cleanup = Task { @MainActor in
                guard self.connectionIdentifier == model.connectionID else { return }
                // note (Codex): A stale model's cleanup must not reset another model on the same connection.
                try? await self.cancelFinalSession(session)
            }
            await cleanup.value
            throw error
        }
    }

}
#endif
