#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerOwnerLifetimeTests: XCTestCase {
    @MainActor
    func testBothKindsAndWorkClassesKeepSameLaneAcrossACKAndPresentationUntilCheckedClose() async throws {
        for kind: OmniXPCSpeakerKind in [.moss, .nemotron] {
            for workClass: MeetingLocalInferenceWorkClass in [.fileASR, .finalASR] {
                let fixture = try OmniXPCSpeakerFixture(kind: kind, workClass: workClass)
                defer { fixture.dispose() }
                try await fixture.owner.prepare()
                try await fixture.owner.prepare()
                XCTAssertEqual(fixture.peer.loadOperations.count, 1)
                let restoresAfterPrepare = fixture.hooks.restoreCount
                try fixture.assertReader(pinned: true)
                try await fixture.owner.startSession(settings: .defaults(for: kind))
                let session = try XCTUnwrap(fixture.peer.session)
                let acknowledgement = try await fixture.owner.push(audio: fixture.audio)
                XCTAssertEqual(acknowledgement.session, session)
                XCTAssertTrue(fixture.peer.controlledWorkActive)
                let probe = try await fixture.blockedProbe()
                try await fixture.owner.commit()
                try await fixture.owner.finish()
                fixture.peer.events = [try OmniXPCSpeakerEvent(session: session, eventSequence: 1,
                    kind: .segment, segmentID: 0, text: "preview", isFinal: false)]
                let preview = try await fixture.owner.poll()
                XCTAssertNil(preview.events.first?.segments)
                XCTAssertFalse(preview.isDrained)
                fixture.peer.events = [try OmniXPCSpeakerEvent(session: session, eventSequence: 2,
                    kind: .completed, text: "final", segments: [])]
                let completed = try await fixture.owner.poll()
                XCTAssertEqual(completed.events.first?.segments, [])
                XCTAssertFalse(completed.isDrained)
                XCTAssertFalse(fixture.probeRan)
                XCTAssertEqual(fixture.hooks.restoreCount, restoresAfterPrepare)
                try fixture.assertReader(pinned: true)
                let closing = Task { try await fixture.owner.closeSession() }
                try await speakerWait { !fixture.peer.closedSessions.isEmpty }
                XCTAssertTrue(fixture.peer.controlledWorkActive)
                XCTAssertEqual(fixture.peer.acknowledgedCloses, 0)
                XCTAssertFalse(fixture.probeRan)
                XCTAssertEqual(fixture.hooks.restoreCount, restoresAfterPrepare)
                fixture.peer.completeControlledWork()
                try await closing.value
                try await probe.value
                XCTAssertFalse(fixture.owner.hasSession)
                XCTAssertFalse(fixture.owner.isClosed)
                XCTAssertEqual(fixture.peer.acknowledgedCloses, 1)
                try fixture.assertReader(pinned: true)
                try await fixture.owner.prepare()
                XCTAssertEqual(fixture.peer.loadOperations.count, 1)
                try await fixture.owner.close()
                XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
                try fixture.assertReader(pinned: false)
                XCTAssertEqual(fixture.hooks.beginCount, workClass == .fileASR ? 2 : 0)
                XCTAssertEqual(fixture.hooks.restoreCount, fixture.hooks.beginCount)
            }
        }
    }

    @MainActor
    func testTimeoutAndCancelACKDoNotReleaseActiveWorkerLaneOrReader() async throws {
        for cancel in [false, true] {
            let fixture = try OmniXPCSpeakerFixture()
            defer { fixture.dispose() }
            try await fixture.owner.prepare()
            try await fixture.owner.startSession(settings: .moss())
            fixture.peer.holdPushReply = true
            var returned = false
            let pushing = Task {
                defer { returned = true }
                return try await fixture.owner.push(audio: fixture.audio, timeout: cancel ? .seconds(5) : .milliseconds(20))
            }
            try await speakerWait { fixture.peer.controlledWorkActive }
            if cancel { pushing.cancel() }
            try await speakerWait { !fixture.peer.drainOperations.isEmpty }
            XCTAssertFalse(returned)
            XCTAssertFalse(fixture.peer.cancellations.isEmpty)
            XCTAssertEqual(fixture.peer.acknowledgedDrains, 0)
            XCTAssertEqual(fixture.hooks.restoreCount, 1)
            let probe = try await fixture.blockedProbe()
            try fixture.assertReader(pinned: true)
            fixture.peer.acknowledgePush()
            XCTAssertTrue(fixture.peer.controlledWorkActive)
            XCTAssertFalse(fixture.probeRan)
            fixture.peer.completeControlledWork()
            await speakerFailure { _ = try await pushing.value }
            try await probe.value
            XCTAssertEqual(fixture.peer.audioSequences, [1])
            XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
            try fixture.assertReader(pinned: false)
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testModelCloseDrainsActiveSessionUsingHeldLaneWithoutWaitingForPublicClose() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        fixture.peer.holdFinishReply = true
        let finishing = Task { try await fixture.owner.finish() }
        try await speakerWait { fixture.peer.finishCount == 1 }
        let first = Task { try await fixture.owner.close() }
        try await speakerWait { !fixture.peer.drainOperations.isEmpty }
        let second = Task { try await fixture.owner.close() }
        first.cancel()
        second.cancel()
        let probe = try await fixture.blockedProbe()
        let submitted = await fixture.coordinator.currentStatistics().submittedCount
        try fixture.assertReader(pinned: true)
        XCTAssertEqual(fixture.peer.acknowledgedDrains, 0)
        fixture.peer.acknowledgeFinish()
        fixture.peer.completeControlledWork()
        await speakerFailure { try await finishing.value }
        try await first.value
        try await second.value
        try await probe.value
        let after = await fixture.coordinator.currentStatistics().submittedCount
        XCTAssertEqual(after, submitted)
        XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
        XCTAssertTrue(fixture.owner.isClosed)
        XCTAssertFalse(fixture.owner.hasPendingCleanup)
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testFailedCloseRetriesSameHeldPermitAndOriginalScope() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled checked barrier failure")
        await speakerFailure { try await fixture.owner.close() }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertFalse(fixture.owner.isClosed)
        try fixture.assertReader(pinned: true)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        let probe = try await fixture.blockedProbe()
        let submitted = await fixture.coordinator.currentStatistics().submittedCount
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        fixture.peer.drainFailure = nil
        let closing = Task { try await fixture.owner.close() }
        try await speakerWait { fixture.peer.drainOperations.count == 2 }
        XCTAssertFalse(fixture.probeRan)
        fixture.peer.completeControlledWork()
        try await closing.value
        try await probe.value
        let after = await fixture.coordinator.currentStatistics().submittedCount
        XCTAssertEqual(after, submitted)
        XCTAssertEqual(fixture.peer.drainOperations, Array(repeating: fixture.peer.loadOperations[0], count: 2))
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testCloseSessionCancelledWaitersRetainModelButReleaseLaneOnlyOnce() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        let probe = try await fixture.blockedProbe()
        let first = Task { try await fixture.owner.closeSession() }
        try await speakerWait { fixture.peer.closedSessions.count == 1 }
        let second = Task { try await fixture.owner.closeSession() }
        first.cancel()
        second.cancel()
        fixture.peer.completeControlledWork()
        try await first.value
        try await second.value
        try await probe.value
        XCTAssertEqual(fixture.hooks.restoreCount, 2)
        XCTAssertFalse(fixture.owner.hasSession)
        try fixture.assertReader(pinned: true)
        try await fixture.owner.close()
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testDisconnectCannotRetargetOrTreatMissingMapsAsDrain() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        let original = fixture.peer.model
        fixture.client.invalidate()
        await speakerFailure { try await fixture.owner.prepare() }
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        await speakerFailure { try await fixture.owner.close() }
        fixture.peer.completeControlledWork()
        await speakerFailure { try await fixture.owner.close() }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertEqual(fixture.peer.model, original)
        XCTAssertEqual(fixture.peer.loadOperations.count, 1)
        XCTAssertTrue(fixture.peer.drainOperations.isEmpty)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        probe.cancel()
        await speakerFailure { try await probe.value }
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
    }
}
#endif
