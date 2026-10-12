import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class SpeakerCoreStream: @unchecked Sendable {
    let nativeSessionID: UInt64
    private let model: SpeakerCoreModel
    private let pointerLock = NSLock()
    private var handle: OpaquePointer?
    private var hasModelLease = false
    private var isClosing = false

    init(model: SpeakerCoreModel, nativeSessionID: UInt64) {
        self.model = model
        self.nativeSessionID = nativeSessionID
    }

    func start(settings: OmniXPCSpeakerSettings) throws {
        try settings.validate()
        guard settings.kind == model.kind else { throw SpeakerCoreModel.error(.invalid) }
        guard !pointerLock.withLock({ isClosing }) else { throw SpeakerCoreModel.error(.cancelled) }
        let modelHandle = try model.reserveStream()
        pointerLock.withLock { hasModelLease = true }
        var nativeSettings = OmniSpeakerRealtimeSettings()
        try SpeakerCoreModel.check(omni_speaker_settings_default(model.kind.rawValue, &nativeSettings))
        var created: OpaquePointer?
        let status: Int32
        switch settings {
        case let .moss(prompt):
            if let prompt {
                status = prompt.withCString {
                    nativeSettings.family.moss.prompt = $0
                    return omni_speaker_realtime_create(modelHandle, nativeSessionID, &nativeSettings, &created)
                }
            } else {
                status = omni_speaker_realtime_create(modelHandle, nativeSessionID, &nativeSettings, &created)
            }
        case let .nemotron(language, chunkMilliseconds):
            nativeSettings.family.nemotron.has_chunk = chunkMilliseconds == nil ? 0 : 1
            nativeSettings.family.nemotron.chunk_milliseconds = chunkMilliseconds ?? 0
            if let language {
                status = language.withCString {
                    nativeSettings.family.nemotron.language = $0
                    return omni_speaker_realtime_create(modelHandle, nativeSessionID, &nativeSettings, &created)
                }
            } else {
                status = omni_speaker_realtime_create(modelHandle, nativeSessionID, &nativeSettings, &created)
            }
        }
        pointerLock.withLock {
            handle = created
            if isClosing { omni_speaker_realtime_cancel(handle) }
        }
        try SpeakerCoreModel.check(status)
        guard created != nil else { throw SpeakerCoreModel.error(.failed) }
    }

    // note (assistant): Only the engine queue runs commands/destroy; cancellation pins the pointer independently.
    func commandHandle(allowCancelled: Bool = false) throws -> OpaquePointer {
        try pointerLock.withLock {
            guard (!isClosing || allowCancelled), let handle else { throw SpeakerCoreModel.error(.cancelled) }
            return handle
        }
    }

    func push(audioSequence: UInt64, samples: [Float]) throws -> UInt64 {
        let handle = try commandHandle()
        var acceptedSequence: UInt64 = 0
        let status = samples.withUnsafeBufferPointer {
            omni_speaker_realtime_push(handle, audioSequence, $0.baseAddress, $0.count, &acceptedSequence)
        }
        try SpeakerCoreModel.check(status)
        guard acceptedSequence == audioSequence else { throw SpeakerCoreModel.error(.failed) }
        return acceptedSequence
    }

    func commit() throws { try SpeakerCoreModel.check(omni_speaker_realtime_commit(commandHandle())) }
    func finish() throws { try SpeakerCoreModel.check(omni_speaker_realtime_finish(commandHandle())) }

    func cancel() {
        pointerLock.withLock {
            isClosing = true
            omni_speaker_realtime_cancel(handle)
        }
    }

    func close() throws {
        try pointerLock.withLock {
            isClosing = true
            try SpeakerCoreModel.check(omni_speaker_realtime_destroy_checked(handle))
            handle = nil
            if hasModelLease {
                model.releaseStream()
                hasModelLease = false
            }
        }
    }

    deinit { precondition(handle == nil && !hasModelLease) }
}
#endif
