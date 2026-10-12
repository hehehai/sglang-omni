import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
/// Retain this explicit owner and await close; failed retirement keeps its reader and inference lane.
@MainActor
final class OmniXPCBatchModelOwner {
    let kind: OmniXPCBatchKind
    private let client: OmniXPCClient
    private let modelDirectory: URL
    private let coordinator: MeetingLocalInferenceCoordinator
    private let workClass: MeetingLocalInferenceWorkClass
    private var model: OmniXPCBatchModelReference?
    private var directoryLease: OmniModelDirectoryLease?
    private var loadOperationID: UUID?
    private var ownedPermit: MeetingLocalInferenceOwnedPermit?
    private var preparation: Task<Void, Error>?
    private var transcription: Task<OmniXPCBatchResult, Error>?
    private var closing: Task<Void, Error>?
    private(set) var isClosing = false
    private(set) var isClosed = false
    var hasPendingCleanup: Bool { ownedPermit != nil && preparation == nil && transcription == nil }

    init(client: OmniXPCClient, kind: OmniXPCBatchKind, modelDirectory: URL,
         coordinator: MeetingLocalInferenceCoordinator = .shared,
         workClass: MeetingLocalInferenceWorkClass = .fileASR) {
        self.client = client
        self.kind = kind
        self.modelDirectory = modelDirectory
        self.coordinator = coordinator
        self.workClass = workClass
    }

    func prepare(timeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60)) async throws {
        try Task.checkCancellation()
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        if let model {
            let state = try client.requireBatchModel(model)
            guard !state.closing, !state.requesting else { throw OmniXPCBatchFailure.error(.busy) }
            return
        }
        let operationID = UUID()
        loadOperationID = operationID
        let preparation = Task { @MainActor in
            defer { self.preparation = nil }
            self.ownedPermit = try await self.coordinator.reserveOwnedPermit(self.workClass)
            do {
                let authorized = try self.client.authorizedBatchModelDirectory(self.modelDirectory)
                let reader = try await ModelDiskOperations.perform {
                    let reader = try OmniModelDirectoryLease.acquire(for: authorized.directory, mode: .sharedRead)
                    let reauthorized = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: authorized.relativePath, container: authorized.container
                    )
                    guard reader.directory.path == reauthorized.path else {
                        throw OmniXPCFailure.error(.invalidRequest, "The batch directory changed during authorization.")
                    }
                    try OmniModelArtifactValidation.validateSafetensorsDirectory(at: reader.directory)
                    return reader
                }
                self.directoryLease = reader
                try Task.checkCancellation()
                self.model = try await self.client.loadBatch(kind: self.kind, modelDirectory: reader.directory,
                    timeout: timeout, cleanupTimeout: cleanupTimeout, operationID: operationID)
                try Task.checkCancellation()
                try await self.releasePermit()
            } catch {
                try await self.retireScope(timeout: cleanupTimeout)
                self.directoryLease = nil
                try await self.releasePermit()
                throw error
            }
        }
        self.preparation = preparation
        try await withTaskCancellationHandler {
            try await preparation.value
            if Task.isCancelled || isClosing || isClosed {
                try await close(timeout: cleanupTimeout)
                throw CancellationError()
            }
        } onCancel: {
            preparation.cancel()
        }
    }

    func transcribe(audio: Data, settings: OmniXPCBatchSettings, timeout: Duration = .seconds(300),
                    cleanupTimeout: Duration = .seconds(60)) async throws -> OmniXPCBatchResult {
        try Task.checkCancellation()
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        guard let model else {
            throw OmniXPCFailure.error(.invalidRequest, "Explicitly prepare the batch model before transcription.")
        }
        guard settings.kind == kind else { throw OmniXPCBatchFailure.error(.invalid) }
        _ = try settings.encoded()
        _ = try OmniXPCRequestValidation.audioSamples(audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount)
        let transcription = Task { @MainActor in
            defer { self.transcription = nil }
            self.ownedPermit = try await self.coordinator.reserveOwnedPermit(self.workClass)
            do {
                let result = try await self.client.transcribeBatch(model, audio: audio, settings: settings, timeout: timeout)
                try Task.checkCancellation()
                try await self.releasePermit()
                return result
            } catch {
                // note (assistant): the original model scope is the barrier even when the request reply was lost.
                try await self.retireScope(timeout: cleanupTimeout)
                self.directoryLease = nil
                try await self.releasePermit()
                throw error
            }
        }
        self.transcription = transcription
        return try await withTaskCancellationHandler {
            let result = try await transcription.value
            if Task.isCancelled || isClosing || isClosed {
                try await close(timeout: cleanupTimeout)
                throw CancellationError()
            }
            return result
        } onCancel: {
            transcription.cancel()
        }
    }

    func close(timeout: Duration = .seconds(60)) async throws {
        if isClosed { return }
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The batch cleanup timeout must be positive.") }
        if let closing { return try await closing.value }
        isClosing = true
        let closing = Task { @MainActor in
            defer { self.closing = nil }
            if let preparation = self.preparation {
                preparation.cancel()
                _ = await preparation.result
            }
            if let transcription = self.transcription {
                transcription.cancel()
                _ = await transcription.result
            }
            if self.model != nil || self.directoryLease != nil || self.ownedPermit != nil || self.ownsPendingLoad {
                if self.ownedPermit == nil {
                    self.ownedPermit = try await self.coordinator.reserveOwnedPermit(.modelCleanup)
                }
                try await self.retireScope(timeout: timeout)
                self.directoryLease = nil
                try await self.releasePermit()
            }
            self.isClosed = true
        }
        self.closing = closing
        try await closing.value
    }

    private var ownsPendingLoad: Bool {
        guard let loadOperationID else { return false }
        return client.pendingBatchLoad?.operationID == loadOperationID
    }

    private func retireScope(timeout: Duration) async throws {
        if let model {
            try await client.closeBatchModel(model, timeout: timeout)
            self.model = nil
        } else if ownsPendingLoad, let loadOperationID {
            try await client.closePendingBatchLoad(timeout: timeout, requiredOperationID: loadOperationID)
        }
        loadOperationID = nil
    }

    private func releasePermit() async throws {
        guard let ownedPermit else { return }
        try await coordinator.completeOwnedPermit(ownedPermit)
        self.ownedPermit = nil
    }

    private func requireAdmission(timeout: Duration, cleanupTimeout: Duration) throws {
        guard workClass == .fileASR || workClass == .finalASR, timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "Batch ownership requires final/file ASR and positive timeouts.")
        }
        guard !isClosing, !isClosed, ownedPermit == nil, preparation == nil, transcription == nil else {
            throw OmniXPCBatchFailure.error(.busy)
        }
    }
}
#endif
