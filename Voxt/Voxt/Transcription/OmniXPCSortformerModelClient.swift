import Foundation
import OmniXPCContracts

#if os(macOS)
@MainActor
final class OmniXPCSortformerModelState {
    let reference: OmniXPCSortformerModelReference
    let loadOperationID: UUID
    var closing = false
    var unloading = false
    var closeTask: Task<Void, Error>?

    init(reference: OmniXPCSortformerModelReference, loadOperationID: UUID) {
        self.reference = reference
        self.loadOperationID = loadOperationID
    }
}

extension OmniXPCClient {
    /// Drains the original load scope, including provisional or still-live streams.
    func closeSortformerModel(
        _ model: OmniXPCSortformerModelReference, timeout: Duration = .seconds(60)
    ) async throws {
        try requireConnection(model.connectionID)
        if closedSortformerModels[model.modelID] == model { return }
        let state = try requireSortformerModel(model)
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model cleanup timeout must be positive.")
        }
        if let closing = state.closeTask { return try await closing.value }
        state.closing = true
        for stream in sortformerStreams.values where stream.reference.model == model {
            stream.closing = true
            stream.terminal = true
        }
        let closing = Task { @MainActor in
            defer { state.closeTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: model.connectionID, cancellationTarget: .sortformer
            ) { proxy, resolve in
                proxy.drainSortformerLoad(operationID: state.loadOperationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            try self.requireConnection(model.connectionID)
            self.retireSortformerModel(state)
        }
        state.closeTask = closing
        try await closing.value
    }

    func requireSortformerModel(_ model: OmniXPCSortformerModelReference) throws -> OmniXPCSortformerModelState {
        try requireConnection(model.connectionID)
        guard let state = sortformerModel, state.reference == model else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model is not owned by this client connection.")
        }
        return state
    }

    func retireSortformerModel(_ state: OmniXPCSortformerModelState) {
        guard connectionIdentifier == state.reference.connectionID, sortformerModel === state else { return }
        let streams = sortformerStreams.values.filter { $0.reference.model == state.reference }
        for stream in streams { retireSortformerStream(stream) }
        sortformerModel = nil
        if closedSortformerModels.count == OmniXPCSortformerLimits.maximumLoadsPerConnection,
           let retiredID = closedSortformerModels.keys.first {
            closedSortformerModels.removeValue(forKey: retiredID)
        }
        closedSortformerModels[state.reference.modelID] = state.reference
    }
}
#endif
