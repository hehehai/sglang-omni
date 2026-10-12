import Foundation
import OmniXPCContracts

#if os(macOS)
extension OmniXPCClient {
    func closePendingBatchLoad(timeout: Duration = .seconds(60), requiredOperationID: UUID? = nil) async throws {
        if let requiredOperationID, closedBatchLoadIDs.contains(requiredOperationID) { return }
        guard let state = pendingBatchLoad else {
            guard requiredOperationID == nil, batchModel == nil else {
                throw OmniXPCFailure.error(.invalidRequest, "There is no matching pending batch load to drain.")
            }
            return
        }
        guard requiredOperationID == nil || requiredOperationID == state.operationID else {
            throw OmniXPCFailure.error(.invalidRequest, "The pending batch load belongs to another owner.")
        }
        guard !state.isLoading else { throw OmniXPCBatchFailure.error(.busy) }
        try await closeBatchScope(state, timeout: timeout)
    }

    func closeBatchModel(_ model: OmniXPCBatchModelReference, timeout: Duration = .seconds(60)) async throws {
        if closedBatchModels[model.modelID] == model { return }
        let state = try requireBatchModel(model)
        try await closeBatchScope(state, timeout: timeout)
    }

    private func closeBatchScope(_ state: OmniXPCBatchLoadState, timeout: Duration) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The batch cleanup timeout must be positive.") }
        if let closing = state.closeTask { return try await closing.value }
        guard let connectionID = state.connectionID else {
            retireBatchScope(state)
            return
        }
        guard connectionIdentifier == connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The original batch connection is unavailable; cleanup is not confirmed.")
        }
        state.closing = true
        let closing = Task { @MainActor in
            defer { state.closeTask = nil }
            let _: Void = try await self.perform(
                timeout: timeout, requiredConnectionID: connectionID, cancellationTarget: .batch
            ) { proxy, resolve in
                proxy.drainBatchLoad(operationID: state.operationID.uuidString) { error in
                    if let error { resolve(.failure(error)) } else { resolve(.success(())) }
                }
            }
            self.retireBatchScope(state)
        }
        state.closeTask = closing
        try await closing.value
    }

    func unloadBatch(_ model: OmniXPCBatchModelReference, timeout: Duration = .seconds(60)) async throws {
        let state = try requireBatchModel(model)
        guard !state.closing, !state.requesting else { throw OmniXPCBatchFailure.error(.busy) }
        state.closing = true
        // note (assistant): An ambiguous unload keeps this ticket; original-load drain is the explicit retry path.
        let _: Void = try await perform(
            timeout: timeout, requiredConnectionID: model.connectionID, cancellationTarget: .batch
        ) { proxy, resolve in
            proxy.unloadBatch(operationID: UUID().uuidString, modelID: model.modelID.uuidString) { error in
                if let error { resolve(.failure(error)) } else { resolve(.success(())) }
            }
        }
        retireBatchScope(state)
    }

    func requireBatchModel(_ model: OmniXPCBatchModelReference) throws -> OmniXPCBatchLoadState {
        guard let state = batchModel, state.reference == model else {
            throw OmniXPCFailure.error(.invalidRequest, "The batch model is not owned by this client.")
        }
        guard connectionIdentifier == model.connectionID else {
            throw OmniXPCFailure.error(.disconnected, "The original batch connection is unavailable; cleanup is not confirmed.")
        }
        return state
    }

    private func retireBatchScope(_ state: OmniXPCBatchLoadState) {
        guard pendingBatchLoad === state || batchModel === state else { return }
        closedBatchLoadIDs.insert(state.operationID)
        if pendingBatchLoad === state { pendingBatchLoad = nil }
        if batchModel === state {
            let reference = state.reference!
            closedBatchModels[reference.modelID] = reference
            batchModel = nil
        }
    }
}
#endif
