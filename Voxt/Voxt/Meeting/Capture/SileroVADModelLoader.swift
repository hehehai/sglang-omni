// SileroVADModelLoader.swift
// Loads Silero VAD for runtime inference.

import Foundation
import MLX
import MLXAudioVAD

extension SileroVADModelSupport {
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
