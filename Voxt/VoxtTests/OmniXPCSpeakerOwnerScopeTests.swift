#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerOwnerScopeTests: XCTestCase {
    @MainActor
    func testPermanentCloseCancelsQueuedAdmissionAndWaitsForIncumbentPermit() async throws {
        for workClass: MeetingLocalInferenceWorkClass in [.fileASR, .finalASR] {
            let fixture = try OmniXPCSpeakerFixture(workClass: workClass)
            defer { fixture.dispose() }
            try await fixture.owner.prepare()
            let incumbent = try await fixture.coordinator.reserveOwnedPermit(.liveASRFinal)
            let starting = Task { try await fixture.owner.startSession(settings: .moss()) }
            try await speakerWait { await fixture.coordinator.currentStatistics().submittedCount == 3 }
            let closing = Task { try await fixture.owner.close() }
            try await speakerWait { await fixture.coordinator.currentStatistics().submittedCount == 4 }
            await speakerFailure { try await starting.value }
            XCTAssertTrue(fixture.owner.isClosing)
            XCTAssertFalse(fixture.owner.isClosed)
            XCTAssertTrue(fixture.peer.startSessions.isEmpty)
            XCTAssertTrue(fixture.peer.drainOperations.isEmpty)
            try fixture.assertReader(pinned: true)
            await fixture.coordinator.setRecordingActive(true)
            await fixture.coordinator.setMemoryPressureConstrained(true)
            fixture.hooks.constrainThermalState()
            closing.cancel()
            try await fixture.coordinator.completeOwnedPermit(incumbent)
            try await closing.value
            XCTAssertTrue(fixture.owner.isClosed)
            try fixture.assertReader(pinned: false)
        }
    }

    @MainActor
    func testForeignPreparedClientIsNotDrainedByRejectedOwnerLoad() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        let other = OmniXPCSpeakerModelOwner(client: fixture.client, kind: .nemotron,
            modelDirectory: fixture.directory, coordinator: fixture.coordinator)
        await speakerFailure { try await other.prepare() }
        XCTAssertFalse(other.hasPendingCleanup)
        XCTAssertTrue(fixture.peer.drainOperations.isEmpty)
        try await other.close()
        XCTAssertTrue(fixture.peer.drainOperations.isEmpty)
        try fixture.assertReader(pinned: true)
        try await fixture.owner.startSession(settings: .moss())
        try await fixture.owner.close()
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testCachedPrepareCannotPublishAnExternallyRetiredModel() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        let model = try XCTUnwrap(fixture.peer.model)
        try await fixture.client.closeSpeakerModel(model)
        try fixture.assertReader(pinned: true)
        await speakerFailure { try await fixture.owner.prepare() }
        XCTAssertEqual(fixture.peer.loadOperations.count, 1)
        XCTAssertEqual(fixture.peer.drainOperations.count, 1)
        try fixture.assertReader(pinned: false)
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        try await fixture.owner.prepare()
        XCTAssertEqual(fixture.peer.loadOperations.count, 2)
        try await fixture.owner.close()
    }

    @MainActor
    func testSessionCloseErrorRetiresModelOnlyAfterOriginalScopeBarrier() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        fixture.peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled stream close failure")
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled model drain failure")
        await speakerFailure { try await fixture.owner.closeSession() }
        XCTAssertTrue(fixture.owner.hasSession)
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        fixture.peer.drainFailure = nil
        let closing = Task { try await fixture.owner.closeSession() }
        try await speakerWait { fixture.peer.drainOperations.count == 2 }
        XCTAssertFalse(fixture.probeRan)
        fixture.peer.completeControlledWork()
        try await closing.value
        try await probe.value
        XCTAssertFalse(fixture.owner.hasSession)
        XCTAssertFalse(fixture.owner.hasPendingCleanup)
        XCTAssertFalse(fixture.owner.isClosed)
        XCTAssertEqual(fixture.peer.drainOperations, Array(repeating: fixture.peer.loadOperations[0], count: 2))
        try fixture.assertReader(pinned: false)
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        try await fixture.owner.close()
    }
}
#endif
