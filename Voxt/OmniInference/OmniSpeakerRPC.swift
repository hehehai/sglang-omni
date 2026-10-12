import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniInferenceSession {
    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        do {
            try admission.admitLoad {
                try speakerEngine.admitLoad(operationID: operationID, kind: kind, modelDirectory: modelDirectory,
                                            clientConnectionID: clientConnectionID, lifetime: speakerLifetime, reply: reply)
            }
        } catch { reply(nil, error as NSError) }
    }

    func unloadSpeaker(operationID: String, modelReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        speakerEngine.unload(operationID: operationID, modelReference: modelReference, lifetime: speakerLifetime, reply: reply)
    }

    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        speakerEngine.drainLoad(operationID: operationID, lifetime: speakerLifetime, reply: reply)
    }

    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        speakerEngine.start(sessionID: sessionID, modelReference: modelReference, settings: settings,
                            lifetime: speakerLifetime, reply: reply)
    }

    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        speakerEngine.push(sessionReference: sessionReference, audioSequence: audioSequence, audio: audio,
                           lifetime: speakerLifetime, reply: reply)
    }

    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        speakerEngine.commit(sessionReference: sessionReference, lifetime: speakerLifetime, reply: reply)
    }

    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        speakerEngine.finish(sessionReference: sessionReference, lifetime: speakerLifetime, reply: reply)
    }

    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        speakerEngine.poll(sessionReference: sessionReference, acknowledgedEventSequence: acknowledgedEventSequence,
                           maximumEventCount: maximumEventCount, lifetime: speakerLifetime, reply: reply)
    }

    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        speakerEngine.closeSession(sessionReference: sessionReference, lifetime: speakerLifetime, reply: reply)
    }

    func cancelSpeakerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try speakerEngine.cancel(requestID: requestID, modelID: modelID, lifetime: speakerLifetime)
            reply(nil)
        } catch { reply(error as NSError) }
    }
}
#endif
