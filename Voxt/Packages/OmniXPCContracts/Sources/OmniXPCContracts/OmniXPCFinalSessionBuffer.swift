/// Bounded final-only audio assembly; this does not produce realtime previews.
import Foundation

public nonisolated struct OmniXPCModelReference: Equatable, Sendable {
    public let modelID: UUID
    public let serviceInstanceID: UUID
    public let connectionID: UUID

    public init(modelID: UUID, serviceInstanceID: UUID, connectionID: UUID) {
        self.modelID = modelID
        self.serviceInstanceID = serviceInstanceID
        self.connectionID = connectionID
    }
}

public nonisolated struct OmniXPCFinalSessionReference: Equatable, Sendable {
    public let sessionID: UUID
    public let model: OmniXPCModelReference
    public let language: String?
    public let maximumTokenCount: Int

    public init(sessionID: UUID, model: OmniXPCModelReference, language: String?, maximumTokenCount: Int) {
        self.sessionID = sessionID
        self.model = model
        self.language = language
        self.maximumTokenCount = maximumTokenCount
    }
}

public nonisolated struct OmniXPCFinalSessionBuffer: Sendable {
    public enum State: Equatable, Sendable {
        case receiving
        case finishing
        case cancelling
        case completed
        case cancelled
        case failed
    }

    public let sessionID: UUID
    public let modelID: UUID
    public let language: String?
    public let context: String?
    public let maximumTokenCount: Int
    public private(set) var state: State = .receiving
    public private(set) var lastAcceptedSequence = 0
    private var audio = Data()

    public var isTerminal: Bool {
        switch state {
        case .completed, .cancelled, .failed: true
        case .receiving, .finishing, .cancelling: false
        }
    }

    public init(sessionID: UUID, modelID: UUID, language: String?, context: String?, maximumTokenCount: Int) throws {
        try OmniXPCRequestValidation.options(language: language, context: context, maximumTokenCount: maximumTokenCount)
        self.sessionID = sessionID
        self.modelID = modelID
        self.language = language
        self.context = context
        self.maximumTokenCount = maximumTokenCount
    }

    public mutating func append(audio chunk: Data, sequence: Int) throws -> Int {
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

    public mutating func beginFinish() throws -> [Float] {
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
    public mutating func cancel() -> Bool {
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
    public mutating func complete(succeeded: Bool) -> Bool {
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
