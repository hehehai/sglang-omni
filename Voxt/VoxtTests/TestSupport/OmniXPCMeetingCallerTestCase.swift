#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated class OmniXPCMeetingCallerTestCase: XCTestCase {
    func descriptor(startSample: Int = 0, sampleCount: Int = 1, source: TranscriptAudioSource = .microphone) -> MeetingAudioAssetDescriptor {
        MeetingAudioAssetDescriptor(source: source, sampleRate: 16_000, startSample: startSample, sampleCount: sampleCount)
    }
    @MainActor
    static func asset(_ descriptor: MeetingAudioAssetDescriptor) -> MeetingAudioAsset {
        MeetingAudioAsset(source: descriptor.source, samples: Array(repeating: 0.25, count: descriptor.sampleCount),
                          sampleRate: descriptor.sampleRate, sessionStartOffset: descriptor.sessionStartOffset)
    }
    func configuration(chunkFrameCount: Int = 188) throws -> MeetingSortformerConfiguration {
        try MeetingSortformerConfiguration(sampleRate: 16_000, featureHopSampleCount: 160, subsamplingFactor: 8,
            chunkFrameCount: chunkFrameCount, speakerCacheFrameCount: 188, speakerCacheUpdateFrameCount: 188,
            usesAOSC: true, chunkLeftContextFrameCount: 1, encoderMaximumFrameCount: 1_500)
    }
    @MainActor
    func fixture(configuration: MeetingSortformerConfiguration? = nil,
                         coordinator: MeetingLocalInferenceCoordinator = MeetingLocalInferenceCoordinator(),
                         timeSource: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) async throws
        -> (OmniXPCMeetingSpeakerDiarizationEngine, OmniXPCClient, OmniXPCSortformerModelReference, CallerPeer) {
        let peer = CallerPeer()
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
        let engine = try OmniXPCMeetingSpeakerDiarizationEngine(client: client, model: model,
            configuration: configuration ?? self.configuration(), coordinator: coordinator, timeSource: timeSource)
        return (engine, client, model, peer)
    }
    @MainActor
    func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CallerFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}


enum CallerFailure: Error { case deadline }
actor CallerProgress {
    var values: [Double] = []
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func append(_ fraction: Double) { values.append(fraction) }
    func wait() async { await withCheckedContinuation { isWaiting = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
nonisolated final class CallerPeer: OmniInferenceXPCProtocol {
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

    let modelID = UUID(), serviceInstanceID = UUID()
    var startCount = 0, closeCount = 0, unloadCount = 0
    var blockStart = false, blockPush = false, blockClose = false, corruptIdentity = false, overlappingSpeakers = false
    var startFailure: NSError?, closeFailure: NSError?
    var settings: OmniXPCSortformerSettings?
    var events: [String] = []
    var audio: [Data] = []
    private var processedFrames: [String: UInt64] = [:]
    private var startingID: String?
    private var startReply: (@Sendable (String?, NSError?) -> Void)?
    func releaseStart() { startReply?(startingID, startFailure); startReply = nil }
    private var closeReply: (@Sendable (NSError?) -> Void)?
    private var closingID: String?
    func releaseClose() {
        if closeFailure == nil, let closingID { processedFrames.removeValue(forKey: closingID) }
        closeReply?(closeFailure); closeReply = nil
    }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        reply(modelID.uuidString, serviceInstanceID.uuidString, nil)
    }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { unloadCount += 1; reply(nil) }
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) {
        startCount += 1; events.append("open")
        self.settings = try! OmniXPCSortformerSettings.decode(settings)
        if let startFailure, startFailure.domain == "Voxt.Omni.XPC",
           [OmniXPCFailure.Code.busy.rawValue, OmniXPCFailure.Code.invalidRequest.rawValue].contains(startFailure.code) {
            reply(nil, startFailure); return
        }
        processedFrames[streamID] = 0
        startingID = streamID
        startReply = reply
        if !blockStart { releaseStart() }
    }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        self.audio.append(audio); events.append("feed")
        if blockPush { return }
        let frameCount = (1 + audio.count / 4 / 160 + 7) / 8
        let previousFrameCount = processedFrames[streamID]!
        let processedFrameCount = previousFrameCount + UInt64(frameCount)
        processedFrames[streamID] = processedFrameCount
        let durationSeconds = OmniXPCSortformerLimits.frameDurationSeconds
        let startSeconds = Float(previousFrameCount) * Float(durationSeconds)
        let segment = try! OmniXPCSortformerSegment(startSeconds: Double(startSeconds),
            endSeconds: Double(startSeconds + Float(frameCount) * Float(durationSeconds)), speakerIndex: 3)
        let overlapping = try! OmniXPCSortformerSegment(startSeconds: segment.startSeconds, endSeconds: segment.endSeconds, speakerIndex: 1)
        let batch = try! OmniXPCSortformerProbabilityBatch(serviceInstanceID: corruptIdentity ? UUID() : serviceInstanceID,
            modelID: self.modelID, streamID: UUID(uuidString: streamID)!, audioSequence: sequence, processedFrameCount: processedFrameCount,
            frameCount: frameCount, speakerCount: 4, frameDurationSeconds: durationSeconds,
            probabilities: (0..<frameCount).flatMap { _ in [Float(0.1), 0.2, 0.3, 0.4] },
            segments: overlappingSpeakers ? [segment, overlapping] : [segment])
        reply(try! batch.encoded(), nil)
    }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        events.append("finish"); processedFrames.removeValue(forKey: streamID); reply(nil)
    }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        closeCount += 1; events.append("close"); closingID = streamID; closeReply = reply
        if !blockClose { releaseClose() }
    }
    private var unused: NSError { OmniXPCFailure.error(.invalidRequest, "Unused controlled-peer RPC") }
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { reply(0, "", 0, unused) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func drainSileroLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { reply(nil, nil, nil, nil, 0, false, unused) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
}
#endif
