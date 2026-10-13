#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

@MainActor
func makeBatchFixture() throws -> (OmniXPCClient, URL, OmniXPCBatchTestPeer) {
    let peer = OmniXPCBatchTestPeer()
    NSXPCConnection.setup = { $0.exportedObject = peer }
    let bundleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleDirectory) }
    let properties = ["CFBundleIdentifier": "test.host", "OmniAppGroupIdentifier": "group.test.host",
                      "OmniInferenceServiceIdentifier": "test.service", "OmniHostBundleIdentifier": "test.host", "OmniTeamIdentifier": "TESTTEAM01"]
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        .write(to: bundleDirectory.appendingPathComponent("Info.plist"))
    let client = try OmniXPCClient(bundle: XCTUnwrap(Bundle(url: bundleDirectory)))
    let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
    let modelDirectory = container.appendingPathComponent("Models/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    return (client, modelDirectory, peer)
}

nonisolated final class OmniXPCBatchTestPeer: OmniInferenceXPCProtocol {
    var modelID = UUID()
    let serviceInstanceID = UUID()
    var loadCount = 0, requestCount = 0, drainCount = 0, cancelCount = 0, unloadCount = 0, otherCallCount = 0
    var blockLoad = false, blockRequest = false, blockDrain = false, blockUnload = false
    var corruptLoad = false, corruptResult = false
    var loadFailure: NSError?, drainFailure: NSError?, unloadFailure: NSError?
    var loadOperationID: String?, drainedOperationID: String?, cancelledRequestID: String?, cancellationModelID: String?
    var lastKind: OmniXPCBatchKind?
    var lastSettings: OmniXPCBatchSettings?
    var lastAudio: Data?
    private var loadReply: (@Sendable (String?, String?, NSError?) -> Void)?
    private var drainReply: (@Sendable (NSError?) -> Void)?
    private var unloadReply: (@Sendable (NSError?) -> Void)?

    func loadBatch(operationID: String, kind: Int, modelDirectory: String,
                   withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        loadCount += 1
        modelID = UUID()
        lastKind = OmniXPCBatchKind(rawValue: kind)
        loadOperationID = operationID
        loadReply = reply
        if !blockLoad { releaseLoad() }
    }

    func releaseLoad() {
        loadReply?(modelID.uuidString, corruptLoad ? nil : serviceInstanceID.uuidString, loadFailure)
        loadReply = nil
    }

    func transcribeBatch(requestID: String, modelID: String, audio: Data, settings: Data,
                         withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        requestCount += 1
        lastSettings = try! OmniXPCBatchSettings.decode(settings)
        lastAudio = audio
        guard !blockRequest else { return }
        let result = try! OmniXPCBatchResult(serviceInstanceID: serviceInstanceID, modelID: self.modelID,
            requestID: corruptResult ? UUID() : UUID(uuidString: requestID)!, kind: lastKind!, text: "fixture", language: "",
            generatedTokenCount: 1, finishReason: .stop, segments: [])
        reply(try! result.encoded(), nil)
    }

    func cancelBatchRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        cancelCount += 1
        cancelledRequestID = requestID
        cancellationModelID = modelID
        reply(nil)
    }

    func drainBatchLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        drainCount += 1
        drainedOperationID = operationID
        drainReply = reply
        if !blockDrain { releaseDrain() }
    }

    func releaseDrain() { drainReply?(drainFailure); drainReply = nil }

    func unloadBatch(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        unloadCount += 1
        unloadReply = reply
        if !blockUnload { releaseUnload() }
    }

    func releaseUnload() { unloadReply?(unloadFailure); unloadReply = nil }
}

nonisolated extension OmniXPCBatchTestPeer {
    private var unavailable: NSError { OmniXPCFailure.error(.configuration, "This peer tests only batch routes.") }
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { reply(0, "", 0, unavailable) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unavailable) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unavailable) }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func drainSileroLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unavailable) }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unavailable) }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unavailable) }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unavailable) }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCallCount += 1; reply(unavailable) }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unavailable) }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unavailable) }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unavailable) }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCallCount += 1; reply(unavailable) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unavailable) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unavailable) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { reply(nil, nil, nil, nil, 0, false, unavailable) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unavailable) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unavailable) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unavailable) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCallCount += 1; reply(unavailable) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unavailable) }
}
#endif
