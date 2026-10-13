import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCSileroModelState {
    let reference: OmniXPCSileroModelReference
    let loadOperationID: UUID
    var closing = false
    var unloading = false
    var closeTask: Task<Void, Error>?

    init(reference: OmniXPCSileroModelReference, loadOperationID: UUID) {
        self.reference = reference
        self.loadOperationID = loadOperationID
    }
}

extension OmniXPCClient {
    /// A successful original-load drain covers offline work and provisional streams too.
    func closeSileroModel(_ model: OmniXPCSileroModelReference, timeout: Duration = .seconds(60)) async throws {
        if closedSileroModels[model.modelID] == model { return }
        let state = try requireSileroModel(model)
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero cleanup timeout must be positive.")
        }
        if let closing = state.closeTask { return try await closing.value }
        state.closing = true
        for stream in sileroStreams.values where stream.reference.model == model {
            stream.closing = true
            stream.terminal = true
        }
        let closing = Task { @MainActor in
            defer { state.closeTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: model.connectionID, cancellationTarget: .silero
            ) { proxy, resolve in
                proxy.drainSileroLoad(operationID: state.loadOperationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            try self.requireConnection(model.connectionID)
            self.retireSileroModel(state)
        }
        state.closeTask = closing
        try await closing.value
    }

    func requireSileroModel(_ model: OmniXPCSileroModelReference) throws -> OmniXPCSileroModelState {
        guard let state = sileroModel, state.reference == model else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero model is not owned by this client.")
        }
        guard connectionIdentifier == model.connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The originating Silero connection is unavailable; cleanup is not confirmed.")
        }
        return state
    }

    func retireSileroModel(_ state: OmniXPCSileroModelState) {
        guard connectionIdentifier == state.reference.connectionID, sileroModel === state else { return }
        let streams = sileroStreams.values.filter { $0.reference.model == state.reference }
        for stream in streams { retireSileroStream(stream) }
        closedSileroLoadIDs.insert(state.loadOperationID)
        closedSileroModels[state.reference.modelID] = state.reference
        sileroModel = nil
    }
}
#endif
