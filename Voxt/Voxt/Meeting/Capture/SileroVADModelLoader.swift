// SileroVADModelLoader.swift
// Loads Silero VAD for runtime inference.

import Foundation
import MLX
import MLXAudioVAD
import OmniModelArtifacts

nonisolated final class SileroVADModelLease {
    private var ownedModel: SileroVAD?
    private var directoryLease: OmniModelDirectoryLease?

    var model: SileroVAD { ownedModel! }

    init(directoryLease: OmniModelDirectoryLease) throws {
        self.directoryLease = directoryLease
        ownedModel = try SileroVADModelSupport.loadModel(from: directoryLease.directory)
    }

    deinit {
        // Note (assistant): mapped weights must be destroyed before the cooperating reader is released.
        ownedModel = nil
        directoryLease = nil
    }
}

extension SileroVADModelSupport {
    nonisolated static func validatedModelDirectoryLease(from directory: URL) async throws -> OmniModelDirectoryLease {
        try await ModelDiskOperations.perform {
            let directoryLease = try OmniModelDirectoryLease.acquire(for: directory, mode: .sharedRead)
            try OmniModelArtifactValidation.validateSafetensorsDirectory(at: directoryLease.directory)
            return directoryLease
        }
    }

    /// Load Silero with MLX C-layer errors converted to Swift throws.
    ///
    /// `SileroVAD.fromModelDirectory` uses bare `eval()` internally; without a
    /// scoped `withError` handler those failures call `fatalError`.
    nonisolated static func loadModel(from directory: URL) throws -> SileroVAD {
        try withError {
            try SileroVAD.fromModelDirectory(directory)
        }
    }
}
