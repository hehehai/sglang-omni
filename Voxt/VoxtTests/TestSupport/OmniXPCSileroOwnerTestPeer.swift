#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts

nonisolated final class SileroOwnerTestPeer: OmniInferenceXPCProtocol {
    let modelID = UUID()
    let serviceInstanceID = UUID()
    var loadOperationID: String?
    var drainedOperationIDs: [String] = []
    var loadCount = 0
    var startCount = 0
    var pushCount = 0
    var offlineCount = 0
    var closeStreamCount = 0
    var cancelCount = 0
    var blockLoad = false
    var blockDrain = false
    var blockPush = false
    var blockOffline = false
    var blockStreamClose = false
    var loseDrainReply = false
    var corruptLoadIdentity = false
    var drainFailure: NSError?
    var receivedAudio: [(streamID: String, sequence: Int, bytes: Data)] = []
    private var receivedSampleCounts: [String: UInt64] = [:]
    private var sequences: [String: Int] = [:]
    private var loadReply: (@Sendable (String?, String?, NSError?) -> Void)?
    private var drainReply: (@Sendable (NSError?) -> Void)?
    private var pushReply: (@Sendable (Data?, NSError?) -> Void)?
    private var pushResult: Data?
    private var offlineReply: (@Sendable (Data?, NSError?) -> Void)?
    private var offlineResult: Data?
    private var closingStreamID: String?
    private var streamCloseReply: (@Sendable (NSError?) -> Void)?

    func loadSilero(operationID: String, modelDirectory: String,
                    withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        loadCount += 1
        loadOperationID = operationID
        loadReply = reply
        if !blockLoad { releaseLoad() }
    }

    func releaseLoad() {
        loadReply?(modelID.uuidString, corruptLoadIdentity ? nil : serviceInstanceID.uuidString, nil)
        loadReply = nil
    }

    func drainSileroLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        drainedOperationIDs.append(operationID)
        guard operationID == loadOperationID else {
            reply(OmniXPCFailure.error(.invalidRequest, "Wrong original load scope"))
            return
        }
        drainReply = reply
        if !blockDrain { releaseDrain() }
    }

    func releaseDrain() {
        if drainFailure == nil {
            receivedSampleCounts.removeAll()
            sequences.removeAll()
        }
        if !loseDrainReply { drainReply?(drainFailure) }
        drainReply = nil
    }

    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        guard modelID == self.modelID.uuidString, receivedSampleCounts.isEmpty else {
            reply(OmniXPCFailure.error(.busy, "Test model still has streams"))
            return
        }
        reply(nil)
    }

    func startSileroStream(streamID: String, modelID: String,
                           withReply reply: @escaping @Sendable (String?, NSError?) -> Void) {
        startCount += 1
        receivedSampleCounts[streamID] = 0
        sequences[streamID] = 0
        reply(streamID, nil)
    }

    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data,
                         withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        pushCount += 1
        receivedAudio.append((streamID, sequence, audio))
        let previousSampleCount = receivedSampleCounts[streamID]!
        let receivedSampleCount = previousSampleCount + UInt64(audio.count / 4)
        receivedSampleCounts[streamID] = receivedSampleCount
        sequences[streamID] = sequence
        let batch = OmniXPCSileroProbabilityBatch(
            serviceInstanceID: serviceInstanceID, modelID: self.modelID, streamID: UUID(uuidString: streamID)!,
            audioSequence: sequence, processedSampleCount: receivedSampleCount / 512 * 512,
            probabilities: (previousSampleCount / 512..<receivedSampleCount / 512).map { Self.probability(frameIndex: $0) },
            isFinal: false
        )
        pushResult = try! batch.encoded()
        pushReply = reply
        if !blockPush { releasePush() }
    }

    static func probability(frameIndex: UInt64) -> Float {
        Float(frameIndex % 8 + 1) / 16
    }

    func releasePush() {
        pushReply?(pushResult, nil)
        pushReply = nil
        pushResult = nil
    }

    func finishSileroStream(streamID: String, modelID: String,
                            withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        let receivedSampleCount = receivedSampleCounts[streamID]!
        let batch = OmniXPCSileroProbabilityBatch(
            serviceInstanceID: serviceInstanceID, modelID: self.modelID, streamID: UUID(uuidString: streamID)!,
            audioSequence: sequences[streamID]!, processedSampleCount: (receivedSampleCount + 511) / 512 * 512,
            probabilities: receivedSampleCount % 512 == 0 ? [] : [Self.probability(frameIndex: receivedSampleCount / 512)],
            isFinal: true
        )
        receivedSampleCounts.removeValue(forKey: streamID)
        sequences.removeValue(forKey: streamID)
        reply(try! batch.encoded(), nil)
    }

    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        closeStreamCount += 1
        closingStreamID = streamID
        streamCloseReply = reply
        if !blockStreamClose { releaseStreamClose() }
    }

    func releaseStreamClose() {
        if let closingStreamID {
            receivedSampleCounts.removeValue(forKey: closingStreamID)
            sequences.removeValue(forKey: closingStreamID)
        }
        streamCloseReply?(nil)
        streamCloseReply = nil
        closingStreamID = nil
    }

    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        cancelCount += 1
        reply(nil)
    }

    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data,
                                withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        offlineCount += 1
        let batch = OmniXPCSileroTimestampBatch(
            serviceInstanceID: serviceInstanceID, modelID: self.modelID, requestID: UUID(uuidString: requestID)!,
            sampleCount: audio.count / 4, timestamps: [OmniXPCSileroTimestamp(startSample: 0, endSample: Int64(audio.count / 4))]
        )
        offlineResult = try! batch.encoded()
        offlineReply = reply
        if !blockOffline { releaseOffline() }
    }

    func releaseOffline() {
        offlineReply?(offlineResult, nil)
        offlineReply = nil
        offlineResult = nil
    }
}
#endif
