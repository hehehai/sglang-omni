#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCMeetingSpeakerOwnershipTests: OmniXPCMeetingCallerTestCase {
    @MainActor
    func testAmbiguousOpenAndFailedDrainBlockLaneBeforeReturningAndBeforeReuse() async throws {
        let coordinator = MeetingLocalInferenceCoordinator()
        let (engine, client, _, peer) = try await fixture(coordinator: coordinator)
        peer.startFailure = OmniXPCFailure.error(.nativeFailure, "Ambiguous start")
        peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Unknown native destruction")
        do { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()); XCTFail("Open succeeded") }
        catch {}
        let beforeRetry = await coordinator.currentStatistics()
        XCTAssertEqual(beforeRetry.submittedCount, 1)
        XCTAssertEqual(beforeRetry.completedCount, 0)
        var contenderRan = false
        let contender = Task {
            try await coordinator.withPermit(.liveASRFeed) { @MainActor in contenderRan = true }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(contenderRan)
        do { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()); XCTFail("Unknown cleanup accepted new work") }
        catch {}
        XCTAssertEqual(peer.startCount, 1)
        let afterRetry = await coordinator.currentStatistics()
        XCTAssertEqual(afterRetry.submittedCount, 2)
        XCTAssertEqual(afterRetry.completedCount, 0)
        contender.cancel()
        _ = await contender.result
        peer.startFailure = nil
        peer.closeFailure = nil
        _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init())
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        XCTAssertEqual(peer.startCount, 2)
    }

    @MainActor
    func testOpenFeedAndCloseAllHoldActualCoordinatorLane() async throws {
        for fileAnalysis in [false, true] {
            let coordinator = MeetingLocalInferenceCoordinator()
            let (engine, _, _, peer) = try await fixture(coordinator: coordinator)
            peer.blockStart = true
            peer.blockClose = true
            let operation = Task {
                if fileAnalysis {
                    return try await engine.diarizeFile(descriptors: [descriptor()], loadAsset: { await Self.asset($0) },
                                                       options: .init(), progress: nil)
                }
                return try await engine.diarize(asset: Self.asset(descriptor()), options: .init())
            }
            try await wait { peer.startCount == 1 }
            var statistics = await coordinator.currentStatistics()
            XCTAssertEqual(statistics.submittedCount, 1)
            XCTAssertEqual(statistics.completedCount, 0)
            peer.releaseStart()
            try await wait { peer.closeCount == 1 }
            statistics = await coordinator.currentStatistics()
            XCTAssertEqual(statistics.submittedCount, 3)
            XCTAssertEqual(statistics.completedCount, 2)
            peer.releaseClose()
            _ = try await operation.value
            statistics = await coordinator.currentStatistics()
            XCTAssertEqual(statistics.completedCount, 3)
            let pending = await engine.hasPendingCleanup
            XCTAssertFalse(pending)
        }
    }

    @MainActor
    func testPublicCloseCancelsOpeningAndCoalescesUncancelledDrain() async throws {
        let coordinator = MeetingLocalInferenceCoordinator()
        let (engine, client, _, peer) = try await fixture(coordinator: coordinator)
        peer.blockStart = true
        peer.blockClose = true
        let operation = Task { try await engine.diarize(asset: Self.asset(descriptor()), options: .init()) }
        try await wait { peer.startCount == 1 }
        var closed = false
        let first = Task { try await engine.close(); closed = true }
        let second = Task { try await engine.close() }
        try await wait { peer.closeCount == 1 }
        first.cancel()
        XCTAssertFalse(closed)
        XCTAssertEqual(client.sortformerStreams.count, 1)
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 0)
        peer.releaseStart()
        peer.releaseClose()
        try await first.value
        try await second.value
        do { _ = try await operation.value; XCTFail("Closed open continued to feed") } catch is CancellationError {}
        XCTAssertTrue(closed)
        XCTAssertEqual(peer.audio.count, 0)
        XCTAssertEqual(peer.closeCount, 1)
        let finalStatistics = await coordinator.currentStatistics()
        XCTAssertEqual(finalStatistics.completedCount, 1)
    }

    @MainActor
    func testCloseCancelsQueuedNotSubmittedOpenBeforeReleasingIdentity() async throws {
        let coordinator = MeetingLocalInferenceCoordinator()
        let blocker = try await coordinator.reserveOwnedPermit(.modelCleanup)
        let (engine, _, _, peer) = try await fixture(coordinator: coordinator)
        let operation = Task { try await engine.diarize(asset: Self.asset(descriptor()), options: .init()) }
        try await wait { await coordinator.currentStatistics().submittedCount == 2 }
        try await engine.close()
        do { _ = try await operation.value; XCTFail("Queued opening survived close") } catch is CancellationError {}
        XCTAssertEqual(peer.startCount, 0)
        let pending = await engine.hasPendingCleanup
        XCTAssertFalse(pending)
        try await coordinator.completeOwnedPermit(blocker)
        _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init())
        XCTAssertEqual(peer.startCount, 1)
    }

    @MainActor
    func testDisconnectNeverTurnsMissingBindingIntoDrainForOpenOrFeed() async throws {
        for duringOpen in [false, true] {
            let coordinator = MeetingLocalInferenceCoordinator()
            let (engine, client, _, peer) = try await fixture(coordinator: coordinator)
            peer.blockStart = duringOpen
            peer.blockPush = !duringOpen
            let operation = Task { try await engine.diarize(asset: Self.asset(descriptor()), options: .init()) }
            try await wait { duringOpen ? peer.startCount == 1 : peer.audio.count == 1 }
            client.invalidate()
            do { _ = try await operation.value; XCTFail("Disconnected operation succeeded") } catch {}
            XCTAssertTrue(client.sortformerStreams.isEmpty)
            let pending = await engine.hasPendingCleanup
            XCTAssertTrue(pending)
            let before = await coordinator.currentStatistics()
            do { try await engine.close(); XCTFail("Disconnect certified native destruction") } catch {}
            do { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()); XCTFail("Disconnected owner reopened") } catch {}
            let after = await coordinator.currentStatistics()
            XCTAssertEqual(before, after)
            XCTAssertEqual(after.completedCount, duringOpen ? 0 : 1)
            XCTAssertEqual(peer.startCount, 1)
        }
    }

    @MainActor
    func testPreadmissionRejectionReleasesPermitWithoutClosingBorrowedStream() async throws {
        let coordinator = MeetingLocalInferenceCoordinator()
        let (engine, client, model, peer) = try await fixture(coordinator: coordinator)
        let settings = try OmniXPCSortformerSettings(threshold: 0.5, minimumDurationSeconds: 0, mergeGapSeconds: 0.18,
                                                    speakerCacheMaximumFrameCount: 188, fifoMaximumFrameCount: 188)
        let borrowed = try await client.startSortformerStream(model: model, settings: settings)
        peer.startFailure = OmniXPCFailure.error(.busy, "Preadmission rejection")
        do { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()); XCTFail("Rejected open succeeded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        try await engine.close()
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 1)
        XCTAssertEqual(statistics.completedCount, 1)
        XCTAssertEqual(client.sortformerStreams.count, 1)
        XCTAssertEqual(peer.closeCount, 0)
        XCTAssertEqual(peer.unloadCount, 0)
        try await client.closeSortformerStream(borrowed)
    }

    @MainActor
    func testFailedFeedDrainRetainsFileAndNonfilePermitThroughTimeoutRetry() async throws {
        for fileAnalysis in [false, true] {
            let coordinator = MeetingLocalInferenceCoordinator()
            let (engine, _, _, peer) = try await fixture(coordinator: coordinator)
            peer.corruptIdentity = true
            peer.closeFailure = OmniXPCFailure.error(.timedOut, "Unconfirmed destruction")
            do {
                if fileAnalysis {
                    _ = try await engine.diarizeFile(descriptors: [descriptor()], loadAsset: { await Self.asset($0) },
                                                    options: .init(), progress: nil)
                } else {
                    _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init())
                }
                XCTFail("Invalid feed succeeded")
            } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.timedOut.rawValue) }
            let before = await coordinator.currentStatistics()
            XCTAssertEqual(before.submittedCount, 2)
            XCTAssertEqual(before.completedCount, 1)
            do { try await engine.close(); XCTFail("Timed-out drain released ownership") } catch {}
            let afterFailure = await coordinator.currentStatistics()
            XCTAssertEqual(afterFailure, before)
            peer.closeFailure = nil
            try await engine.close()
            let after = await coordinator.currentStatistics()
            XCTAssertEqual(after.submittedCount, 2)
            XCTAssertEqual(after.completedCount, 2)
            XCTAssertEqual(peer.audio.count, 1)
        }
    }

    @MainActor
    func testFailedCloseRetainsPermitAndExplicitRetryDoesNotReserveBehindItself() async throws {
        let coordinator = MeetingLocalInferenceCoordinator()
        let (engine, _, _, peer) = try await fixture(coordinator: coordinator)
        peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Unknown destruction")
        do { _ = try await engine.diarize(asset: Self.asset(descriptor()), options: .init()); XCTFail("Failed close hidden") } catch {}
        let before = await coordinator.currentStatistics()
        XCTAssertEqual(before.submittedCount, 3)
        XCTAssertEqual(before.completedCount, 2)
        peer.closeFailure = nil
        peer.blockClose = true
        let closeCount = peer.closeCount
        let first = Task { try await engine.close() }
        let second = Task { try await engine.close() }
        try await wait { peer.closeCount > closeCount }
        let during = await coordinator.currentStatistics()
        XCTAssertEqual(during, before)
        peer.releaseClose()
        try await first.value
        try await second.value
        let after = await coordinator.currentStatistics()
        XCTAssertEqual(after.submittedCount, 3)
        XCTAssertEqual(after.completedCount, 3)
    }

}
#endif
