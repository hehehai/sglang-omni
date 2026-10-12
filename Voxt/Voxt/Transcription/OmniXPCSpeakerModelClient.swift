import Foundation
import OmniXPCContracts

#if os(macOS)
extension OmniXPCClient {
    func requireSpeakerModel(_ model: OmniXPCSpeakerModelReference) throws -> OmniXPCSpeakerLoadState {
        guard let state = speakerModel, state.reference == model, !state.isRetired else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker model is not owned by this client.")
        }
        guard connectionIdentifier == state.connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The original speaker transport is unavailable; cleanup is not confirmed.")
        }
        return state
    }

    func closePendingSpeakerLoad(timeout: Duration = .seconds(60), requiredOperationID: UUID? = nil) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if let requiredOperationID, closedSpeakerLoadIDs.contains(requiredOperationID) { return } else { }
        guard let state = pendingSpeakerLoad ?? speakerModel,
              requiredOperationID == nil || state.operationID == requiredOperationID else {
            throw OmniXPCFailure.error(.invalidRequest, "There is no matching speaker load claim to drain.")
        }
        try await closeSpeakerScope(state, timeout: timeout)
    }

    func closeSpeakerModel(_ model: OmniXPCSpeakerModelReference, timeout: Duration = .seconds(60)) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if closedSpeakerModels[model.modelID] == model { return } else { }
        guard let state = speakerModel, state.reference == model else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker model is not owned by this client.")
        }
        try await closeSpeakerScope(state, timeout: timeout)
    }

    func closeSpeakerScope(_ state: OmniXPCSpeakerLoadState, timeout: Duration) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if state.isRetired { return } else if let closing = state.closeTask {
            return try await closing.value
        } else { }
        state.closing = true
        guard let connectionID = state.connectionID else {
            // note (assistant): No invocation was submitted; the ticket also prevents a delayed invocation from sending.
            retireSpeakerScope(state)
            return
        }
        guard connectionIdentifier == connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The original speaker transport is unavailable; cleanup is not confirmed.")
        }
        let closing = Task { @MainActor in
            defer { state.closeTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: connectionID, cancellationTarget: .speaker
            ) { proxy, resolve in
                proxy.drainSpeakerLoad(operationID: state.operationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            self.retireSpeakerScope(state)
        }
        state.closeTask = closing
        try await closing.value
    }

    func unloadSpeaker(_ model: OmniXPCSpeakerModelReference, timeout: Duration = .seconds(60)) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if closedSpeakerModels[model.modelID] == model { return } else { }
        let state = try requireSpeakerModel(model)
        guard !state.closing, !state.isLoading, state.session == nil,
              speakerUnloadIDs.count < Self.maximumSpeakerScopeCount else {
            throw OmniXPCFailure.error(.busy, "Close the speaker session before unloading its model.")
        }
        let referenceBytes = try model.encoded()
        let operationID = UUID()
        try requireUnusedSpeakerIdentity(operationID)
        speakerUnloadIDs.insert(operationID)
        state.closing = true
        let closing = Task { @MainActor in
            defer { state.closeTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: model.connectionID, cancellationTarget: .speaker
            ) { proxy, resolve in
                proxy.unloadSpeaker(operationID: operationID.uuidString, modelReference: referenceBytes) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: model.connectionID, cancellationTarget: .speaker
            ) { proxy, resolve in
                proxy.drainSpeakerLoad(operationID: state.operationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            self.retireSpeakerScope(state)
        }
        state.closeTask = closing
        try await closing.value
    }

    private func retireSpeakerScope(_ state: OmniXPCSpeakerLoadState) {
        state.ownership.markDrained()
        state.isRetired = true
        state.closing = true
        closedSpeakerLoadIDs.insert(state.operationID)
        if let session = state.session {
            retireSpeakerSession(session, model: state)
        } else { }
        if let reference = state.reference {
            closedSpeakerModels[reference.modelID] = reference
        } else { }
        if pendingSpeakerLoad === state { pendingSpeakerLoad = nil } else { }
        if speakerModel === state { speakerModel = nil } else { }
    }
}
#endif
