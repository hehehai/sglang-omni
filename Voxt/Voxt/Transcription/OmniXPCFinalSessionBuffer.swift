/// Bounded final-only audio assembly; this does not produce realtime previews.
import Foundation

nonisolated struct OmniXPCModelReference: Equatable, Sendable {
    let modelID: UUID
    let serviceInstanceID: UUID
    let connectionID: UUID
}

nonisolated struct OmniXPCFinalSessionReference: Equatable, Sendable {
    let sessionID: UUID
    let model: OmniXPCModelReference
    let language: String?
    let maximumTokenCount: Int
}

nonisolated struct OmniXPCFinalSessionBuffer: Sendable {
    enum State: Equatable, Sendable {
        case receiving
        case finishing
        case cancelling
        case completed
        case cancelled
        case failed
    }

    let sessionID: UUID
    let modelID: UUID
    let language: String?
    let context: String?
    let maximumTokenCount: Int
    private(set) var state: State = .receiving
    private(set) var lastAcceptedSequence = 0
    private var audio = Data()

    var isTerminal: Bool {
        switch state {
        case .completed, .cancelled, .failed: true
        case .receiving, .finishing, .cancelling: false
        }
    }

    init(sessionID: UUID, modelID: UUID, language: String?, context: String?, maximumTokenCount: Int) throws {
        try OmniXPCRequestValidation.options(language: language, context: context, maximumTokenCount: maximumTokenCount)
        self.sessionID = sessionID
        self.modelID = modelID
        self.language = language
        self.context = context
        self.maximumTokenCount = maximumTokenCount
    }

    mutating func append(audio chunk: Data, sequence: Int) throws -> Int {
        guard state == .receiving, sequence == lastAcceptedSequence + 1,
              chunk.count <= OmniXPCProtocolLimits.maximumChunkAudioByteCount,
              chunk.count <= OmniXPCProtocolLimits.maximumAudioByteCount - audio.count else {
            throw OmniXPCFailure.error(.invalidRequest, "The final session chunk is stale, out of order or exceeds its audio budget.")
        }
        _ = try OmniXPCRequestValidation.samples(
            audio: chunk, language: language, context: context, maximumTokenCount: maximumTokenCount
        )
        audio.append(chunk)
        lastAcceptedSequence = sequence
        return sequence
    }

    mutating func beginFinish() throws -> [Float] {
        guard state == .receiving else {
            throw OmniXPCFailure.error(.invalidRequest, "The final session has already finished or was cancelled.")
        }
        let samples = try OmniXPCRequestValidation.samples(
            audio: audio, language: language, context: context, maximumTokenCount: maximumTokenCount
        )
        state = .finishing
        audio.removeAll(keepingCapacity: false)
        return samples
    }

    @discardableResult
    mutating func cancel() -> Bool {
        switch state {
        case .receiving:
            audio.removeAll(keepingCapacity: false)
            state = .cancelled
            return true
        case .finishing:
            state = .cancelling
            return true
        case .cancelling, .completed, .cancelled, .failed:
            return false
        }
    }

    @discardableResult
    mutating func complete(succeeded: Bool) -> Bool {
        switch state {
        case .finishing:
            state = succeeded ? .completed : .failed
            return true
        case .cancelling:
            state = .cancelled
            return true
        case .receiving, .completed, .cancelled, .failed:
            return false
        }
    }
}
