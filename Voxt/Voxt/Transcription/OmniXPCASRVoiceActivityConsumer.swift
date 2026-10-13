import Foundation
import OmniXPCContracts

#if os(macOS)
/// Opt-in mono 16 kHz Float32 consumer; preparation is the entrusting caller's responsibility.
@MainActor
final class OmniXPCASRVoiceActivityConsumer {
    private final class Stream {
        let reference: OmniXPCSileroStreamReference
        var audioSequence = 0
        var busy = false
        var terminal = false
        var closing: Task<Void, Error>?

        init(reference: OmniXPCSileroStreamReference) { self.reference = reference }
    }

    private let owner: OmniXPCSileroModelOwner
    private var streams: [UUID: Stream] = [:]
    private var closing: Task<Void, Error>?
    private(set) var isClosing = false
    private(set) var isClosed = false

    init(owner: OmniXPCSileroModelOwner) throws {
        _ = try owner.requirePreparedModel()
        self.owner = owner
    }

    func openStream(timeout: Duration = .seconds(30)) async throws -> OmniXPCSileroStreamReference {
        try requireReady()
        let reference = try await owner.openStream(timeout: timeout)
        if isClosing || isClosed || Task.isCancelled {
            try await close(timeout: timeout)
            throw CancellationError()
        }
        streams[reference.streamID] = Stream(reference: reference)
        return reference
    }

    /// Nil means this call completed no frame; otherwise return its last completed frame, not an average.
    func probability(
        samples16k: [Float], to reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(30)
    ) async throws -> Float? {
        let stream = try requireStream(reference)
        guard !stream.busy, !stream.terminal else {
            throw OmniXPCFailure.error(.busy, "The ASR voice-activity stream is pending or terminal.")
        }
        guard timeout > .zero, samples16k.allSatisfy(\.isFinite) else {
            throw OmniXPCFailure.error(.invalidRequest, "ASR voice activity requires finite mono 16 kHz Float32 samples.")
        }
        let maximumChunkSampleCount = OmniXPCSileroLimits.maximumChunkSampleCount
        let chunkCount = samples16k.count / maximumChunkSampleCount
            + (samples16k.count % maximumChunkSampleCount == 0 ? 0 : 1)
        guard chunkCount <= Int.max - stream.audioSequence else {
            throw OmniXPCFailure.error(.invalidRequest, "The ASR voice-activity sequence would overflow.")
        }
        stream.busy = true
        defer { stream.busy = false }
        var lastFrameProbability: Float?
        var sampleOffset = 0
        while sampleOffset < samples16k.count {
            try Task.checkCancellation()
            let chunkSampleCount = min(maximumChunkSampleCount, samples16k.count - sampleOffset)
            let audio = Self.float32LittleEndian(Array(samples16k[sampleOffset..<(sampleOffset + chunkSampleCount)]))
            let sequence = stream.audioSequence + 1
            let batch = try await owner.pushAudio(audio, to: reference, sequence: sequence, timeout: timeout)
            stream.audioSequence = sequence
            if isClosing || isClosed || Task.isCancelled {
                try await close(timeout: timeout)
                throw CancellationError()
            }
            if let probability = batch.probabilities.last { lastFrameProbability = probability }
            sampleOffset += chunkSampleCount
        }
        return lastFrameProbability
    }

    func finishStream(
        _ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(60)
    ) async throws -> Float? {
        let stream = try requireStream(reference)
        guard !stream.busy, !stream.terminal else {
            throw OmniXPCFailure.error(.busy, "The ASR voice-activity stream is pending or terminal.")
        }
        stream.busy = true
        defer { stream.busy = false }
        let batch = try await owner.finishStream(reference, timeout: timeout)
        stream.terminal = true
        streams.removeValue(forKey: reference.streamID)
        if isClosing || isClosed || Task.isCancelled {
            try await close(timeout: timeout)
            throw CancellationError()
        }
        return batch.probabilities.last
    }

    func closeStream(_ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(60)) async throws {
        let stream = try requireStream(reference)
        guard !stream.busy else {
            throw OmniXPCFailure.error(.busy, "Use the entrusted owner's close to interrupt pending ASR voice activity.")
        }
        if let closing = stream.closing { return try await closing.value }
        stream.terminal = true
        let cleanup = Task { @MainActor in
            defer { stream.closing = nil }
            try await self.owner.closeStream(reference, timeout: timeout)
            self.streams.removeValue(forKey: reference.streamID)
        }
        stream.closing = cleanup
        try await cleanup.value
    }

    func speechTimestamps(
        samples16k: [Float], settings: OmniXPCSileroSettings, timeout: Duration = .seconds(240)
    ) async throws -> [Range<Int>] {
        try requireReady()
        return try await owner.speechTimestamps(samples16k: samples16k, settings: settings, timeout: timeout)
    }

    func close(timeout: Duration = .seconds(60)) async throws {
        if isClosed { return }
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The ASR voice-activity cleanup timeout must be positive.")
        }
        if let closing { return try await closing.value }
        isClosing = true
        let cleanup = Task { @MainActor in
            defer { self.closing = nil }
            try await self.owner.close(timeout: timeout)
            self.streams.removeAll()
            self.isClosed = true
        }
        closing = cleanup
        try await cleanup.value
    }

    nonisolated static func float32LittleEndian(_ samples16k: [Float]) -> Data {
        samples16k.withUnsafeBufferPointer { samples in
            var audio = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
            for sample in samples {
                var bits = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { audio.append(contentsOf: $0) }
            }
            return audio
        }
    }

    private func requireReady() throws {
        try Task.checkCancellation()
        guard !isClosing, !isClosed else {
            throw OmniXPCFailure.error(.invalidRequest, "The entrusted ASR voice-activity consumer is closing or closed.")
        }
        _ = try owner.requirePreparedModel()
    }

    private func requireStream(_ reference: OmniXPCSileroStreamReference) throws -> Stream {
        try requireReady()
        guard let stream = streams[reference.streamID], stream.reference == reference else {
            throw OmniXPCFailure.error(.invalidRequest, "The ASR voice-activity stream belongs to another consumer.")
        }
        return stream
    }
}
#endif
