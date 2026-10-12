#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
@testable import Voxt

nonisolated extension OmniXPCSpeakerTestPeer {
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { base.probe(withReply: reply) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadQwen(operationID: operationID, modelDirectory: modelDirectory, withReply: reply) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadQwen(operationID: operationID, modelID: modelID, withReply: reply) }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadSilero(operationID: operationID, modelDirectory: modelDirectory, withReply: reply) }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadSilero(operationID: operationID, modelID: modelID, withReply: reply) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.sileroSpeechTimestamps(requestID: requestID, modelID: modelID, audio: audio, settings: settings, withReply: reply) }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startSileroStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.pushSileroAudio(streamID: streamID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.finishSileroStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.closeSileroStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelSileroRequest(requestID: requestID, modelID: modelID, withReply: reply) }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadSortformer(operationID: operationID, modelDirectory: modelDirectory, withReply: reply) }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadSortformer(operationID: operationID, modelID: modelID, withReply: reply) }
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.drainSortformerLoad(operationID: operationID, withReply: reply) }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startSortformerStream(streamID: streamID, modelID: modelID, settings: settings, withReply: reply) }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.pushSortformerAudio(streamID: streamID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.finishSortformerStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.closeSortformerStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelSortformerRequest(requestID: requestID, modelID: modelID, withReply: reply) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startFinalSession(sessionID: sessionID, modelID: modelID, language: language, context: context, maximumTokenCount: maximumTokenCount, withReply: reply) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { base.pushFinalAudio(sessionID: sessionID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { base.finishFinalSession(sessionID: sessionID, modelID: modelID, withReply: reply) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startRealtimeSession(sessionID: sessionID, modelID: modelID, language: language, context: context, maximumTokenCount: maximumTokenCount, decodeIntervalSamples: decodeIntervalSamples, firstDecodeSamples: firstDecodeSamples, maximumSegmentSamples: maximumSegmentSamples, withReply: reply) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { base.pushRealtimeAudio(sessionID: sessionID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.finishRealtimeSession(sessionID: sessionID, modelID: modelID, withReply: reply) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.pollRealtimeEvents(sessionID: sessionID, modelID: modelID, acknowledgedEventSequence: acknowledgedEventSequence, maximumEventCount: maximumEventCount, withReply: reply) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.closeRealtimeSession(sessionID: sessionID, modelID: modelID, withReply: reply) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelRequest(requestID: requestID, modelID: modelID, withReply: reply) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { base.terminateForValidation(withReply: reply) }
    func loadBatch(operationID: String, kind: Int, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadBatch(operationID: operationID, kind: kind, modelDirectory: modelDirectory, withReply: reply) }
    func transcribeBatch(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.transcribeBatch(requestID: requestID, modelID: modelID, audio: audio, settings: settings, withReply: reply) }
    func unloadBatch(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadBatch(operationID: operationID, modelID: modelID, withReply: reply) }
    func drainBatchLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.drainBatchLoad(operationID: operationID, withReply: reply) }
    func cancelBatchRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelBatchRequest(requestID: requestID, modelID: modelID, withReply: reply) }
}
#endif
