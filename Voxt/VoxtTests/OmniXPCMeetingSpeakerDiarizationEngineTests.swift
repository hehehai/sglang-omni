#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCMeetingSpeakerDiarizationEngineTests: OmniXPCMeetingCallerTestCase {
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
            XCTAssertEqual(clock.releaseCount, 1)
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
            XCTAssertEqual(statistics.submittedCount, 2)
            XCTAssertEqual(statistics.completedCount, 1)
            peer.releaseClose()
            do { _ = try await operation.value; XCTFail("Cancelled/slow operation succeeded") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch MeetingSpeakerFeedError.processingTooSlow { XCTAssertFalse(cancel) }
            XCTAssertEqual(clock.releaseCount, 2)
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

}

private nonisolated final class CallerClock: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = ContinuousClock.now
    private var calls = 0
    private var releases = 0
    var releaseCount: Int { lock.withLock { releases } }
    func markReleased() { lock.withLock { releases += 1 } }
    func now() -> ContinuousClock.Instant {
        lock.withLock { defer { calls += 1 }; return startedAt.advanced(by: .seconds(calls == 0 ? 0 : 31)) }
    }
}

#endif
