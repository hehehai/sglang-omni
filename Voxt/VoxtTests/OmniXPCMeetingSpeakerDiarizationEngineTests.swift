#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCMeetingSpeakerDiarizationEngineTests: XCTestCase {
    @MainActor
    func testBoundedRealPCMWholeBatchMappingSettingsAndProgress() async throws {
        let (engine, client, model, peer) = try await fixture()
        let descriptor = descriptor(startSample: 160_000, sampleCount: 64_001)
        let progress = CallerProgress()
        let turns = try await engine.diarizeSession(descriptors: [descriptor], loadAsset: { await Self.asset($0) },
            continuousAudioURL: nil, options: .init(minimumSpeakerConfidence: 1), progress: { await progress.append($0) })
        XCTAssertEqual(peer.audio.map { $0.count / 4 }, [32_000, 32_000, 1])
        XCTAssertEqual(peer.settings?.threshold, 0.5)
        XCTAssertEqual(peer.settings?.minimumDurationSeconds, 0)
        XCTAssertEqual(peer.settings?.mergeGapSeconds, 0.18)
        XCTAssertEqual(peer.settings?.speakerCacheMaximumFrameCount, 188)
        XCTAssertEqual(peer.settings?.fifoMaximumFrameCount, 188)
        XCTAssertEqual(turns.count, 3)
        for (index, turn) in turns.enumerated() {
            XCTAssertEqual(turn.speakerID, "sortformer-3")
            XCTAssertEqual(turn.displayName, MeetingSpeakerDisplayNameFormatter.displayName(ordinal: 4))
            XCTAssertNil(turn.confidence)
            XCTAssertEqual(turn.startSeconds, 10 + Double(index * 2), accuracy: 0.000001)
            XCTAssertEqual(turn.endSeconds, index == 2 ? 14 + 1.0 / 16_000 : 12 + Double(index * 2), accuracy: 0.000001)
        }
        let fractions = await progress.values
        XCTAssertEqual(fractions, [0, 32_000.0 / 64_001, 64_000.0 / 64_001, 1])
        XCTAssertEqual(peer.events, ["open", "feed", "feed", "feed", "close"])
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        XCTAssertEqual(client.connectionIdentifier, model.connectionID)
        XCTAssertEqual(peer.unloadCount, 0)
    }

    @MainActor
    func testSmallerPolicyAndResamplingDoNotPadOrReplay() async throws {
        let configuration = try configuration(chunkFrameCount: 1)
        let (engine, _, _, peer) = try await fixture(configuration: configuration)
        let asset = MeetingAudioAsset(source: .microphone, samples: [.nan] + Array(repeating: 0.25, count: 640),
                                      sampleRate: 8_000, sessionStartOffset: 0)
        _ = try await engine.diarize(asset: asset, options: .init())
        XCTAssertEqual(peer.audio.map { $0.count / 4 }, [1_280, 2])
        XCTAssertEqual(Array(peer.audio[0].prefix(4)), [0, 0, 0, 0])
        XCTAssertEqual(peer.events.last, "close")
    }

    @MainActor
    func testContinuityGapAndSourceResetCloseBeforeReplacementOpen() async throws {
        for (startSample, source, resets) in [(16_784, TranscriptAudioSource.microphone, false),
                                               (16_800, .microphone, true), (16_000, .systemAudio, true)] {
            let (engine, _, _, peer) = try await fixture()
            peer.blockClose = true
            let descriptors = [descriptor(sampleCount: 16_000), descriptor(startSample: startSample, source: source)]
            let operation = Task { try await engine.diarizeSession(descriptors: descriptors,
                loadAsset: { await Self.asset($0) }, continuousAudioURL: nil, options: .init(), progress: nil) }
            try await wait { peer.closeCount == 1 }
            XCTAssertEqual(peer.startCount, 1)
            XCTAssertEqual(peer.audio.count, resets ? 1 : 2)
            peer.blockClose = false
            peer.releaseClose()
            let turns = try await operation.value
            XCTAssertEqual(peer.startCount, resets ? 2 : 1)
            XCTAssertEqual(turns.map(\.source), [.microphone, source])
            XCTAssertEqual(peer.events, resets ? ["open", "feed", "close", "open", "feed", "close"]
                                               : ["open", "feed", "feed", "close"])
        }
    }

    @MainActor
    func testMissingOrEmptyAssetAfterFeedAwaitsOwnedClose() async throws {
        for empty in [false, true] {
            let (engine, client, _, peer) = try await fixture()
            peer.blockClose = true
            var returned = false
            let operation = Task {
                defer { returned = true }
                return try await engine.diarizeFile(descriptors: [descriptor(), descriptor(startSample: 1)], loadAsset: {
                    if $0.sessionStartOffset == 0 { return await Self.asset($0) }
                    return empty ? MeetingAudioAsset(source: .microphone, samples: [], sampleRate: 16_000, sessionStartOffset: 0) : nil
                }, options: .init(), progress: nil)
            }
            try await wait { peer.closeCount == 1 }
            XCTAssertFalse(returned)
            peer.releaseClose()
            do { _ = try await operation.value; XCTFail("Unavailable audio succeeded") }
            catch MeetingSpeakerFeedError.audioUnavailable {}
            XCTAssertTrue(client.sortformerStreams.isEmpty)
            XCTAssertEqual(peer.audio.count, 1)
        }
    }

    @MainActor
    func testMalformedReplyAndOpenFailureAwaitCloseWithoutClientInvalidation() async throws {
        for openFailure in [false, true] {
            let (engine, client, model, peer) = try await fixture()
            peer.corruptIdentity = !openFailure
            peer.startFailure = openFailure ? OmniXPCFailure.error(.nativeFailure, "Controlled open failure") : nil
            peer.blockClose = true
            var returned = false
            let operation = Task {
                defer { returned = true }
                return try await engine.diarize(asset: Self.asset(descriptor()), options: .init())
            }
            try await wait { peer.closeCount == 1 }
            XCTAssertFalse(returned)
            peer.releaseClose()
            do { _ = try await operation.value; XCTFail("Invalid exchange succeeded") } catch {}
            XCTAssertTrue(client.sortformerStreams.isEmpty)
            XCTAssertEqual(client.connectionIdentifier, model.connectionID)
            XCTAssertEqual(peer.audio.count, openFailure ? 0 : 1)
            XCTAssertEqual(peer.unloadCount, 0)
        }
    }

    @MainActor
    func testCancellationAndTooSlowHoldFilePermitUntilCloseBarrier() async throws {
        for cancel in [false, true] {
            let clock = CallerClock()
            let coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { { clock.markReleased() } })
            let (engine, client, _, peer) = try await fixture(coordinator: coordinator, timeSource: { clock.now() })
            peer.blockPush = cancel
            peer.blockClose = true
            var returned = false
            let operation = Task {
                defer { returned = true }
                return try await engine.diarizeFile(descriptors: [descriptor()], loadAsset: { await Self.asset($0) },
                                                     options: .init(), progress: nil)
            }
            try await wait { peer.audio.count == 1 }
            if cancel { operation.cancel() }
            try await wait { peer.closeCount == 1 }
            XCTAssertFalse(returned)
            XCTAssertFalse(clock.released)
            XCTAssertFalse(client.sortformerStreams.isEmpty)
            for method in 0..<3 {
                do {
                    if method == 0 { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()) }
                    else if method == 1 { _ = try await engine.diarizeFile(descriptors: [], loadAsset: { _ in nil }, options: .init(), progress: nil) }
                    else { _ = try await engine.diarizeSession(descriptors: [], loadAsset: { _ in nil }, continuousAudioURL: nil, options: .init(), progress: nil) }
                    XCTFail("Overlapping operation accepted")
                } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
            }
            XCTAssertEqual(peer.startCount, 1)
            let statistics = await coordinator.currentStatistics()
            XCTAssertEqual(statistics.submittedCount, 1)
            peer.releaseClose()
            do { _ = try await operation.value; XCTFail("Cancelled/slow operation succeeded") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch MeetingSpeakerFeedError.processingTooSlow { XCTAssertFalse(cancel) }
            XCTAssertTrue(clock.released)
            XCTAssertTrue(client.sortformerStreams.isEmpty)
            XCTAssertEqual(peer.audio.count, 1)
        }
    }

    @MainActor
    func testProgressCancellationClosesButCannotForceNoncooperativeReturn() async throws {
        let (engine, client, _, peer) = try await fixture()
        let progress = CallerProgress()
        var returned = false
        let operation = Task {
            defer { returned = true }
            return try await engine.diarizeSession(descriptors: [descriptor()], loadAsset: { await Self.asset($0) },
                continuousAudioURL: nil, options: .init(), progress: { if $0 == 1 { await progress.wait() } })
        }
        try await wait { await progress.isWaiting }
        operation.cancel()
        try await wait { peer.closeCount == 1 && client.sortformerStreams.isEmpty }
        XCTAssertFalse(returned)
        await progress.release()
        do { _ = try await operation.value; XCTFail("Cancelled progress succeeded") } catch is CancellationError {}
        XCTAssertTrue(returned)
    }

    @MainActor
    func testTrustedFilePCMIsNotSilentlySanitizedAndEmptySessionReportsCompletion() async throws {
        let (engine, client, _, peer) = try await fixture()
        do {
            _ = try await engine.diarizeFile(descriptors: [descriptor()], loadAsset: { _ in
                MeetingAudioAsset(source: .microphone, samples: [.nan], sampleRate: 16_000, sessionStartOffset: 0)
            }, options: .init(), progress: nil)
            XCTFail("Trusted nonfinite PCM was silently replaced")
        } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(peer.audio.count, 0)
        XCTAssertEqual(peer.closeCount, 1)
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        let progress = CallerProgress()
        let consumer: any MeetingSpeakerDiarizationEngine = engine
        let turns = try await consumer.diarizeFile(descriptors: [], loadAsset: { _ in nil }, options: .init(),
                                                    progress: { await progress.append($0) })
        XCTAssertTrue(turns.isEmpty)
        let fractions = await progress.values
        XCTAssertEqual(fractions, [0, 1])
        XCTAssertEqual(peer.startCount, 1)
    }

    @MainActor
    func testOverlappingSegmentsKeepPeerOrderAndClipToRealPCM() async throws {
        let (engine, _, _, peer) = try await fixture()
        peer.overlappingSpeakers = true
        let turns = try await engine.diarize(asset: Self.asset(descriptor(sampleCount: 1)), options: .init())
        XCTAssertEqual(turns.map(\.speakerID), ["sortformer-3", "sortformer-1"])
        for turn in turns {
            XCTAssertEqual(turn.startSeconds, 0)
            XCTAssertEqual(turn.endSeconds, 1.0 / 16_000)
        }
    }

    @MainActor
    func testFailedCloseSurfacesAndIsRetriedBeforeNewOpen() async throws {
        let (engine, client, _, peer) = try await fixture()
        peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        do { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()); XCTFail("Close failure hidden") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(client.sortformerStreams.count, 1)
        peer.closeFailure = nil
        _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init())
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        XCTAssertEqual(peer.startCount, 2)
        XCTAssertEqual(peer.unloadCount, 0)
    }

    @MainActor
    func testIncompatibleNativeGeometryStopsBeforeOpeningAStream() async throws {
        for (hopSampleCount, subsamplingFactor, usesAOSC) in [(80, 4, true), (160, 4, true), (160, 8, false)] {
            let configuration = try MeetingSortformerConfiguration(
                sampleRate: 16_000, featureHopSampleCount: hopSampleCount, subsamplingFactor: subsamplingFactor,
                chunkFrameCount: 188, speakerCacheFrameCount: 188, speakerCacheUpdateFrameCount: 188,
                usesAOSC: usesAOSC, chunkLeftContextFrameCount: 1, encoderMaximumFrameCount: 1_500
            )
            let (engine, client, _, peer) = try await fixture(configuration: configuration)
            do {
                _ = try await engine.diarize(asset: Self.asset(descriptor(sampleCount: 96_000)), options: .init())
                XCTFail("Incompatible timing geometry was accepted")
            } catch MeetingSpeakerFeedError.invalidConfiguration {}
            XCTAssertEqual(peer.startCount, 0)
            XCTAssertTrue(peer.audio.isEmpty)
            XCTAssertTrue(client.sortformerStreams.isEmpty)
            client.invalidate()
        }
    }

    private func descriptor(startSample: Int = 0, sampleCount: Int = 1, source: TranscriptAudioSource = .microphone) -> MeetingAudioAssetDescriptor {
        MeetingAudioAssetDescriptor(source: source, sampleRate: 16_000, startSample: startSample, sampleCount: sampleCount)
    }
    @MainActor
    private static func asset(_ descriptor: MeetingAudioAssetDescriptor) -> MeetingAudioAsset {
        MeetingAudioAsset(source: descriptor.source, samples: Array(repeating: 0.25, count: descriptor.sampleCount),
                          sampleRate: descriptor.sampleRate, sessionStartOffset: descriptor.sessionStartOffset)
    }
    private func configuration(chunkFrameCount: Int = 188) throws -> MeetingSortformerConfiguration {
        try MeetingSortformerConfiguration(sampleRate: 16_000, featureHopSampleCount: 160, subsamplingFactor: 8,
            chunkFrameCount: chunkFrameCount, speakerCacheFrameCount: 188, speakerCacheUpdateFrameCount: 188,
            usesAOSC: true, chunkLeftContextFrameCount: 1, encoderMaximumFrameCount: 1_500)
    }
    @MainActor
    private func fixture(configuration: MeetingSortformerConfiguration? = nil,
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
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CallerFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum CallerFailure: Error { case deadline }
private actor CallerProgress {
    var values: [Double] = []
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func append(_ fraction: Double) { values.append(fraction) }
    func wait() async { await withCheckedContinuation { isWaiting = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private nonisolated final class CallerClock: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = ContinuousClock.now
    private var calls = 0
    private var permitReleased = false
    var released: Bool { lock.withLock { permitReleased } }
    func markReleased() { lock.withLock { permitReleased = true } }
    func now() -> ContinuousClock.Instant {
        lock.withLock { defer { calls += 1 }; return startedAt.advanced(by: .seconds(calls == 0 ? 0 : 31)) }
    }
}

private nonisolated final class CallerPeer: OmniInferenceXPCProtocol {
    let modelID = UUID(), serviceInstanceID = UUID()
    var startCount = 0, closeCount = 0, unloadCount = 0
    var blockPush = false, blockClose = false, corruptIdentity = false, overlappingSpeakers = false
    var startFailure: NSError?, closeFailure: NSError?
    var settings: OmniXPCSortformerSettings?
    var events: [String] = []
    var audio: [Data] = []
    private var processedFrames: [String: UInt64] = [:]
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
        processedFrames[streamID] = 0
        reply(streamID, startFailure)
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
