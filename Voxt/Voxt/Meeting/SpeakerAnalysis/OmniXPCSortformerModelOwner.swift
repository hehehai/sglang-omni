import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
nonisolated struct OmniXPCPreparedSortformerModel: Sendable {
    let model: OmniXPCSortformerModelReference
    let configuration: MeetingSortformerConfiguration
}

private nonisolated struct SortformerOwnerArtifacts: Sendable {
    let lease: OmniModelDirectoryLease
    let configuration: MeetingSortformerConfiguration
}

/// Explicit model preparation/retirement owner; borrowed callers retain it and await close.
@MainActor
final class OmniXPCSortformerModelOwner {
    private let client: OmniXPCClient
    private let modelDirectory: URL
    private let coordinator: MeetingLocalInferenceCoordinator
    private var directoryLease: OmniModelDirectoryLease?
    private var preparedModel: OmniXPCPreparedSortformerModel?
    private var loadOperationID: UUID?
    private var ownedPermit: MeetingLocalInferenceOwnedPermit?
    private var preparation: Task<OmniXPCPreparedSortformerModel, Error>?
    private var closing: Task<Void, Error>?
    private(set) var isClosing = false
    private(set) var isClosed = false

    init(client: OmniXPCClient, modelDirectory: URL, coordinator: MeetingLocalInferenceCoordinator = .shared) {
        self.client = client
        self.modelDirectory = modelDirectory
        self.coordinator = coordinator
    }

    func prepare(timeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60)) async throws -> OmniXPCPreparedSortformerModel {
        try Task.checkCancellation()
        guard !isClosing, !isClosed, ownedPermit == nil else {
            throw OmniXPCFailure.error(.busy, "Complete this Sortformer owner's cleanup before preparing a model.")
        }
        if let preparedModel {
            let modelState = try client.requireSortformerModel(preparedModel.model)
            guard !modelState.closing, !modelState.unloading else {
                throw OmniXPCFailure.error(.busy, "The borrowed Sortformer model is retiring.")
            }
            return preparedModel
        }
        guard preparation == nil else {
            throw OmniXPCFailure.error(.busy, "This Sortformer owner already has pending preparation.")
        }
        guard timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer preparation and cleanup timeouts must be positive.")
        }
        let operationID = UUID()
        loadOperationID = operationID
        let preparation = Task { @MainActor in
            defer { self.preparation = nil }
            self.ownedPermit = try await self.coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
            do {
                let authorized = try self.client.authorizedSortformerModelDirectory(self.modelDirectory)
                let artifacts = try await ModelDiskOperations.perform {
                    let lease = try OmniModelDirectoryLease.acquire(for: authorized.directory, mode: .sharedRead)
                    let reauthorized = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: authorized.relativePath, container: authorized.container
                    )
                    guard lease.directory.path == reauthorized.path else {
                        throw OmniXPCFailure.error(.invalidRequest, "The Sortformer model directory changed during authorization.")
                    }
                    let configuration = try MeetingSortformerConfiguration.load(from: lease.directory)
                    guard configuration.sampleRate == OmniXPCSortformerLimits.sampleRate,
                          configuration.featureHopSampleCount == OmniXPCSortformerLimits.featureHopSampleCount,
                          configuration.subsamplingFactor == OmniXPCSortformerLimits.subsamplingFactor,
                          configuration.usesAOSC else {
                        throw MeetingSpeakerFeedError.invalidConfiguration
                    }
                    let policy = try configuration.feedPolicy()
                    try configuration.validateEncoderCapacity(cacheMaximumFrameCount: policy.cacheMaximumFrames,
                        fifoMaximumFrameCount: MeetingSpeakerFeedPolicy.fifoMaximumFrames)
                    return SortformerOwnerArtifacts(lease: lease, configuration: configuration)
                }
                self.directoryLease = artifacts.lease
                try Task.checkCancellation()
                let model = try await self.client.loadSortformer(modelDirectory: artifacts.lease.directory,
                    timeout: timeout, cleanupTimeout: cleanupTimeout, operationID: operationID)
                let prepared = OmniXPCPreparedSortformerModel(model: model, configuration: artifacts.configuration)
                self.preparedModel = prepared
                try Task.checkCancellation()
                try await self.releaseOwnedPermit()
                return prepared
            } catch {
                // Note (assistant): failed cleanup keeps this owner and its lane retryable, not apparently idle.
                try await self.retireNativeScope(timeout: cleanupTimeout)
                self.directoryLease = nil
                try await self.releaseOwnedPermit()
                throw error
            }
        }
        self.preparation = preparation
        return try await withTaskCancellationHandler {
            let prepared = try await preparation.value
            if Task.isCancelled || isClosing || isClosed {
                try await close(timeout: cleanupTimeout)
                throw CancellationError()
            }
            return prepared
        } onCancel: {
            preparation.cancel()
        }
    }

    /// Failure or connection loss retains the reader and lane; retry on the original scope.
    func close(timeout: Duration = .seconds(60)) async throws {
        if isClosed { return }
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer owner cleanup timeout must be positive.")
        }
        if let closing { return try await closing.value }
        isClosing = true
        let closing = Task { @MainActor in
            defer { self.closing = nil }
            if let preparation = self.preparation {
                preparation.cancel()
                _ = await preparation.result
            }
            if self.preparedModel != nil || self.directoryLease != nil || self.ownedPermit != nil
                || self.ownsPendingLoad {
                if self.ownedPermit == nil {
                    self.ownedPermit = try await self.coordinator.reserveOwnedPermit(.modelCleanup)
                }
                try await self.retireNativeScope(timeout: timeout)
                self.directoryLease = nil
                try await self.releaseOwnedPermit()
            }
            self.isClosed = true
        }
        self.closing = closing
        try await closing.value
    }

    private var ownsPendingLoad: Bool {
        guard let operationID = loadOperationID else { return false }
        return client.pendingSortformerLoad?.operationID == operationID
    }

    private func retireNativeScope(timeout: Duration) async throws {
        if let preparedModel {
            try await client.closeSortformerModel(preparedModel.model, timeout: timeout)
            self.preparedModel = nil
        } else if ownsPendingLoad, let operationID = loadOperationID {
            try await client.closePendingSortformerLoad(timeout: timeout, requiredOperationID: operationID)
        }
    }

    private func releaseOwnedPermit() async throws {
        guard let ownedPermit else { return }
        try await coordinator.completeOwnedPermit(ownedPermit)
        self.ownedPermit = nil
    }
}
#endif
