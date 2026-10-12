#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
@testable import Voxt

nonisolated extension OmniXPCBatchTestPeer {
    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func unloadSpeaker(operationID: String, modelReference: Data,
                       withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func cancelSpeakerRequest(requestID: String, modelID: String?,
                              withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    private var unsupportedSpeaker: NSError {
        OmniXPCFailure.error(.incompatibleService, "This test peer does not implement speaker realtime inference.")
    }
}

nonisolated extension BatchOwnerPeer {
    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func unloadSpeaker(operationID: String, modelReference: Data,
                       withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func cancelSpeakerRequest(requestID: String, modelID: String?,
                              withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    private var unsupportedSpeaker: NSError {
        OmniXPCFailure.error(.incompatibleService, "This test peer does not implement speaker realtime inference.")
    }
}

nonisolated extension SortformerOwnershipPeer {
    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func unloadSpeaker(operationID: String, modelReference: Data,
                       withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func cancelSpeakerRequest(requestID: String, modelID: String?,
                              withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    private var unsupportedSpeaker: NSError {
        OmniXPCFailure.error(.incompatibleService, "This test peer does not implement speaker realtime inference.")
    }
}

nonisolated extension CallerPeer {
    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func unloadSpeaker(operationID: String, modelReference: Data,
                       withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unsupportedSpeaker) }
    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    func cancelSpeakerRequest(requestID: String, modelID: String?,
                              withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unsupportedSpeaker) }
    private var unsupportedSpeaker: NSError {
        OmniXPCFailure.error(.incompatibleService, "This test peer does not implement speaker realtime inference.")
    }
}

#endif
