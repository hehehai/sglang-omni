#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts

extension SileroOwnerTestPeer {
    func loadSpeaker(operationID: String, kind: Int, modelDirectory: String, clientConnectionID: String,
                     withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func unloadSpeaker(operationID: String, modelReference: Data,
                       withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func drainSpeakerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func startSpeakerSession(sessionID: String, modelReference: Data, settings: Data,
                             withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func pushSpeakerAudio(sessionReference: Data, audioSequence: UInt64, audio: Data,
                          withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func commitSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func finishSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func pollSpeakerEvents(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
                           withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeSpeakerSession(sessionReference: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelSpeakerRequest(requestID: String, modelID: String?,
                              withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func loadBatch(operationID _: String, kind _: Int, modelDirectory _: String,
                   withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        reply(nil, nil, OmniXPCFailure.error(.invalidRequest, "This test peer does not implement batch inference."))
    }
    func transcribeBatch(requestID _: String, modelID _: String, audio _: Data, settings _: Data,
                         withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        reply(nil, OmniXPCFailure.error(.invalidRequest, "This test peer does not implement batch inference."))
    }
    func cancelBatchRequest(requestID _: String, modelID _: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        reply(OmniXPCFailure.error(.invalidRequest, "This test peer does not implement batch inference."))
    }
    func drainBatchLoad(operationID _: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        reply(OmniXPCFailure.error(.invalidRequest, "This test peer does not implement batch inference."))
    }
    func unloadBatch(operationID _: String, modelID _: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        reply(OmniXPCFailure.error(.invalidRequest, "This test peer does not implement batch inference."))
    }

    nonisolated private var unused: NSError { OmniXPCFailure.error(.invalidRequest, "Unused portable test RPC") }
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { reply(0, "", 0, unused) }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { reply(nil, nil, nil, nil, 0, false, unused) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }}
#endif
