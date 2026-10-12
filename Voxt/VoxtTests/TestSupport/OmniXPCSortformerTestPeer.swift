#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

@MainActor
func makeSortformerOwnershipFixture() async throws -> (OmniXPCClient, OmniXPCSortformerModelReference, SortformerOwnershipPeer) {
    let peer = SortformerOwnershipPeer()
    NSXPCConnection.setup = { $0.exportedObject = peer }
    defer { NSXPCConnection.setup = nil }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let properties = ["CFBundleIdentifier": "test.host", "OmniAppGroupIdentifier": "group.test.host",
                      "OmniInferenceServiceIdentifier": "test.service", "OmniHostBundleIdentifier": "test.host", "OmniTeamIdentifier": "TESTTEAM01"]
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
    let client = try OmniXPCClient(bundle: XCTUnwrap(Bundle(url: directory)))
    let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
    let modelDirectory = container.appendingPathComponent("Models/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: modelDirectory) }
    let model = try await client.loadSortformer(modelDirectory: modelDirectory)
    return (client, model, peer)
}

nonisolated final class SortformerOwnershipPeer: OmniInferenceXPCProtocol {
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

    var modelID = UUID()
    let serviceInstanceID = UUID()
    var startCount = 0, pushCount = 0, finishCount = 0, cancelCount = 0, closeCount = 0, otherCancelCount = 0
    var blockStart = false, blockPush = false, blockClose = false, corruptIdentity = false
    var corruptLoadIdentity = false, blockLoad = false, blockLoadDrain = false
    var loadCount = 0, loadDrainCount = 0, unloadCount = 0
    var blockUnload = false
    var unloadFailure: NSError?
    private var unloadReply: (@Sendable (NSError?) -> Void)?
    var loadFailure: NSError?, loadDrainFailure: NSError?
    var loadOperationID: String?
    var cancelledLoadOperationID: String?, drainedLoadOperationID: String?
    private var loadReply: (@Sendable (String?, String?, NSError?) -> Void)?
    private var loadDrainReply: (@Sendable (NSError?) -> Void)?
    var startFailure: NSError?
    var closeFailure: NSError?
    var settings: OmniXPCSortformerSettings?
    var lastBatch: OmniXPCSortformerProbabilityBatch?
    private var processedFrames: [String: UInt64] = [:]
    private var startReply: (@Sendable (String?, NSError?) -> Void)?
    private var startingID: String?
    private var closeReply: (@Sendable (NSError?) -> Void)?
    private var closingID: String?
    func releaseStart() { startReply?(startingID, startFailure); startReply = nil }
    func releaseClose() {
        if closeFailure == nil, let closingID { processedFrames.removeValue(forKey: closingID) }
        closeReply?(closeFailure); closeReply = nil
    }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        loadCount += 1
        modelID = UUID()
        loadOperationID = operationID
        loadReply = reply
        if !blockLoad { releaseLoad() }
    }
    func releaseLoad() {
        loadReply?(modelID.uuidString, corruptLoadIdentity ? nil : serviceInstanceID.uuidString, loadFailure)
        loadReply = nil
    }
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        loadDrainCount += 1
        drainedLoadOperationID = operationID
        loadDrainReply = reply
        if !blockLoadDrain { releaseLoadDrain() }
    }
    func releaseLoadDrain() {
        if loadDrainFailure == nil { processedFrames.removeAll() }
        loadDrainReply?(loadDrainFailure); loadDrainReply = nil
    }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        unloadCount += 1
        if !processedFrames.isEmpty { reply(OmniXPCFailure.error(.busy, "Undrained controlled streams")); return }
        unloadReply = reply
        if !blockUnload { releaseUnload() }
    }
    func releaseUnload() { unloadReply?(unloadFailure); unloadReply = nil }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) {
        startCount += 1
        self.settings = try! OmniXPCSortformerSettings.decode(settings)
        if let startFailure, startFailure.domain == "Voxt.Omni.XPC",
           [OmniXPCFailure.Code.invalidRequest.rawValue, OmniXPCFailure.Code.busy.rawValue].contains(startFailure.code) {
            reply(nil, startFailure); return
        }
        processedFrames[streamID] = 0
        if blockStart { startReply = reply; startingID = streamID } else { reply(streamID, startFailure) }
    }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        pushCount += 1
        if blockPush { return }
        let frameCount = (1 + audio.count / 4 / 160 + 7) / 8
        let previousFrameCount = processedFrames[streamID]!
        let processedFrameCount = previousFrameCount + UInt64(frameCount)
        processedFrames[streamID] = processedFrameCount
        let durationSeconds = OmniXPCSortformerLimits.frameDurationSeconds
        let startSeconds = Float(previousFrameCount) * Float(durationSeconds)
        let segment = try! OmniXPCSortformerSegment(startSeconds: Double(startSeconds),
            endSeconds: Double(startSeconds + Float(frameCount) * Float(durationSeconds)), speakerIndex: 3)
        let batch = try! OmniXPCSortformerProbabilityBatch(serviceInstanceID: corruptIdentity ? UUID() : serviceInstanceID,
            modelID: self.modelID, streamID: UUID(uuidString: streamID)!, audioSequence: sequence, processedFrameCount: processedFrameCount,
            frameCount: frameCount, speakerCount: 4, frameDurationSeconds: durationSeconds,
            probabilities: (0..<frameCount).flatMap { _ in [Float(0.1), 0.2, 0.3, 0.4] }, segments: [segment])
        lastBatch = batch
        reply(try! batch.encoded(), nil)
    }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        finishCount += 1; processedFrames.removeValue(forKey: streamID); reply(nil)
    }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        cancelCount += 1
        if modelID == nil { cancelledLoadOperationID = requestID }
        reply(nil)
    }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        closeCount += 1; closingID = streamID; closeReply = reply
        if !blockClose { releaseClose() }
    }
    private var unused: NSError { OmniXPCFailure.error(.invalidRequest, "Unused controlled-peer RPC") }
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { reply(0, "", 0, unused) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCancelCount += 1; reply(unused) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { reply(nil, nil, nil, nil, 0, false, unused) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCancelCount += 1; reply(unused) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
}
#endif
