#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerOwnerRecoveryTests: XCTestCase {
    @MainActor
    func testMalformedLoadFailedDrainRetainsReaderAndOriginalPermitUntilExplicitRetry() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        fixture.peer.loadBytes = Data("{}".utf8)
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled failed model destruction")
        await speakerFailure { try await fixture.owner.prepare() }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertEqual(fixture.hooks.restoreCount, 0)
        try fixture.assertReader(pinned: true)
        await speakerFailure { try await fixture.owner.prepare() }
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        let probe = try await fixture.blockedProbe()
        let submitted = await fixture.coordinator.currentStatistics().submittedCount
        fixture.peer.drainFailure = nil
        try await fixture.owner.close()
        try await probe.value
        let after = await fixture.coordinator.currentStatistics().submittedCount
        XCTAssertEqual(after, submitted)
        XCTAssertTrue(fixture.peer.drainOperations.allSatisfy { $0 == fixture.peer.loadOperations[0] })
        XCTAssertEqual(fixture.peer.loadOperations.count, 1)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testMalformedStartNeverReleasesHeldLaneOnFailedScopeDrain() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        fixture.peer.startBytes = Data("{}".utf8)
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled failed session destruction")
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        fixture.peer.drainFailure = nil
        try await fixture.owner.close()
        try await probe.value
        XCTAssertEqual(fixture.peer.startSessions.count, 1)
        XCTAssertTrue(fixture.peer.drainOperations.allSatisfy { $0 == fixture.peer.loadOperations[0] })
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testModelCloseDeadlineRetainsSameLaneUntilOriginalDrainRetryConfirmation() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        fixture.peer.holdDrain = true
        await speakerFailure(code: .timedOut) { try await fixture.owner.close(timeout: .milliseconds(20)) }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertFalse(fixture.owner.isClosed)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        let submitted = await fixture.coordinator.currentStatistics().submittedCount
        let first = Task { try await fixture.owner.close() }
        try await speakerWait { fixture.peer.drainOperations.count == 2 }
        let second = Task { try await fixture.owner.close() }
        first.cancel()
        second.cancel()
        fixture.peer.holdDrain = false
        fixture.peer.releaseBarriers()
        try await first.value
        try await second.value
        try await probe.value
        let after = await fixture.coordinator.currentStatistics().submittedCount
        XCTAssertEqual(after, submitted)
        XCTAssertEqual(fixture.peer.drainOperations, Array(repeating: fixture.peer.loadOperations[0], count: 2))
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testActiveLoadCloseCoalescesCancelledWaitersWithoutLateModelPublication() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        fixture.peer.holdLoadReply = true
        var published = false
        let preparing = Task { try await fixture.owner.prepare(); published = true }
        try await speakerWait { fixture.peer.controlledLoadActive }
        let first = Task { try await fixture.owner.close() }
        try await speakerWait { !fixture.peer.drainOperations.isEmpty }
        let second = Task { try await fixture.owner.close() }
        first.cancel()
        second.cancel()
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        fixture.peer.completeLoad()
        await speakerFailure { try await preparing.value }
        try await first.value
        try await second.value
        try await probe.value
        XCTAssertFalse(published)
        XCTAssertTrue(fixture.owner.isClosed)
        XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
        try fixture.assertReader(pinned: false)
    }
}
#endif
