#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCBatchModelOwnerTests: XCTestCase {
    @MainActor
    func testSixFamiliesReuseModelPreserveSettingsAndHoldReaderUntilExplicitClose() async throws {
        let settings: [OmniXPCBatchSettings] = [.whisper(language: "en", maximumTokenCount: 7, temperature: 0.1),
            .cohere(language: "en", usePunctuation: false, maximumTokenCount: 8, chunkDurationSeconds: 12),
            .moss(prompt: "fixture", maximumTokenCount: 9, stopAtEndOfText: true, stopOnTokenLoop: true),
            .nemotron(language: "en", chunkFrameCount: 10), .parakeet(chunkDurationSeconds: 30),
            .sensevoice(language: "en", useInverseTextNormalization: true)]
        for settings in settings {
            let fixture = try BatchOwnerFixture(kind: settings.kind)
            defer { fixture.dispose() }
            try await fixture.owner.prepare()
            try await fixture.owner.prepare()
            XCTAssertEqual(fixture.peer.base.loadCount, 1)
            XCTAssertEqual(fixture.hooks.restoreCount, 1)
            XCTAssertFalse(fixture.owner.hasPendingCleanup)
            for _ in 0..<2 {
                let result = try await fixture.owner.transcribe(audio: fixture.audio, settings: settings)
                XCTAssertEqual(result.kind, settings.kind)
                XCTAssertEqual(result.text, "fixture")
                XCTAssertEqual(fixture.peer.base.lastSettings, settings)
                XCTAssertEqual(fixture.peer.base.lastAudio, fixture.audio)
                try fixture.assertReader(pinned: true)
                try await fixture.coordinator.withPermit(.liveASRFinal) {}
            }
            XCTAssertEqual(fixture.hooks.beginCount, 3)
            XCTAssertEqual(fixture.hooks.restoreCount, 3)
            try await fixture.owner.close()
            try await fixture.owner.close()
            XCTAssertTrue(fixture.owner.isClosed)
            XCTAssertTrue(fixture.owner.isClosing)
            XCTAssertFalse(fixture.owner.hasPendingCleanup)
            XCTAssertEqual(fixture.peer.drainOperations, [fixture.peer.base.loadOperationID!])
            XCTAssertEqual(fixture.peer.base.otherCallCount, 0)
            try fixture.assertReader(pinned: false)
        }
    }

    @MainActor
    func testValidationAndExplicitPreparationRejectBeforeAdmissionOrRPC() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        await batchOwnerFailure { _ = try await fixture.request() }
        var statistics = await fixture.coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 0)
        try await fixture.owner.prepare()
        let invalidAudio = [Data(), Data([0]), Data(repeating: 0, count: 480_001 * 4),
            [Float.nan.bitPattern.littleEndian].withUnsafeBytes { Data($0) },
            [Float.infinity.bitPattern.littleEndian].withUnsafeBytes { Data($0) }]
        for audio in invalidAudio {
            await batchOwnerFailure { _ = try await fixture.owner.transcribe(audio: audio, settings: .whisper()) }
        }
        for settings in [OmniXPCBatchSettings.moss(), .whisper(temperature: .nan)] {
            await batchOwnerFailure { _ = try await fixture.owner.transcribe(audio: fixture.audio, settings: settings) }
        }
        await batchOwnerFailure { _ = try await fixture.request(timeout: .zero) }
        await batchOwnerFailure { _ = try await fixture.request(cleanupTimeout: .zero) }
        statistics = await fixture.coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 1)
        XCTAssertEqual(fixture.peer.base.requestCount, 0)
        let result = try await fixture.owner.transcribe(audio: Data(repeating: 0, count: 480_000 * 4), settings: .whisper())
        XCTAssertEqual(result.text, "fixture")
        try await fixture.owner.close()
    }

    @MainActor
    func testInvalidWorkClassesRejectWithoutAdmissionOrNativeWork() async throws {
        for workClass: MeetingLocalInferenceWorkClass in [.modelCleanup, .liveASRFeed, .liveASRFinal, .liveASRPartial,
            .realtimeTranslation, .fileSpeakerAnalysis, .speakerAnalysis, .detailTranslation, .summary] {
            let fixture = try BatchOwnerFixture(workClass: workClass)
            defer { fixture.dispose() }
            await batchOwnerFailure(code: .invalidRequest) { try await fixture.owner.prepare() }
            await batchOwnerFailure(code: .invalidRequest) { _ = try await fixture.request() }
            try await fixture.owner.close()
            let statistics = await fixture.coordinator.currentStatistics()
            XCTAssertEqual(statistics.submittedCount, 0)
            XCTAssertEqual(fixture.peer.base.loadCount, 0)
        }
    }

    @MainActor
    func testCancelledQueuedPreparationNeverLoadsOrReleasesIncumbent() async throws {
        for workClass: MeetingLocalInferenceWorkClass in [.fileASR, .finalASR] {
            let fixture = try BatchOwnerFixture(workClass: workClass)
            defer { fixture.dispose() }
            let incumbent = try await fixture.coordinator.reserveOwnedPermit(.liveASRFinal)
            let preparing = Task { try await fixture.owner.prepare() }
            try await batchOwnerWait { await fixture.coordinator.currentStatistics().submittedCount == 2 }
            preparing.cancel()
            await batchOwnerFailure { try await preparing.value }
            XCTAssertEqual(fixture.peer.base.loadCount, 0)
            XCTAssertEqual(fixture.hooks.beginCount, 0)
            try fixture.assertReader(pinned: false)
            let probe = try await fixture.blockedProbe()
            try await fixture.owner.close()
            XCTAssertFalse(fixture.probeRan)
            try await fixture.coordinator.completeOwnedPermit(incumbent)
            try await probe.value
        }
    }

    @MainActor
    func testCancelledAndDeadlinedLoadsWaitForActualControlledWorkExit() async throws {
        for cancel in [false, true] {
            let fixture = try BatchOwnerFixture()
            defer { fixture.dispose() }
            fixture.peer.holdLoadWork = true
            var returned = false
            let preparing = Task { defer { returned = true }; try await fixture.owner.prepare(timeout: cancel ? .seconds(5) : .milliseconds(20)) }
            try await batchOwnerWait { fixture.peer.nativeLoadActive }
            if cancel { preparing.cancel() }
            try await batchOwnerWait { !fixture.peer.drainOperations.isEmpty }
            XCTAssertFalse(returned)
            XCTAssertEqual(fixture.peer.acknowledgedDrains, 0)
            XCTAssertEqual(fixture.hooks.restoreCount, 0)
            try fixture.assertReader(pinned: true)
            let probe = try await fixture.blockedProbe()
            fixture.peer.finishLoadWork()
            await batchOwnerFailure { try await preparing.value }
            try await probe.value
            XCTAssertEqual(fixture.hooks.restoreCount, 1)
            XCTAssertEqual(fixture.peer.drainOperations, [fixture.peer.base.loadOperationID!])
            XCTAssertNil(fixture.client.batchModel)
            try fixture.assertReader(pinned: false)
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testFailedLoadCleanupRetainsOriginalPermitAndRetriesOriginalOperation() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        fixture.peer.base.corruptLoad = true
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        await batchOwnerFailure(code: .nativeFailure) { try await fixture.owner.prepare() }
        let operationID = fixture.peer.base.loadOperationID!
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertEqual(fixture.hooks.restoreCount, 0)
        try fixture.assertReader(pinned: true)
        await batchOwnerFailure { try await fixture.owner.prepare() }
        await batchOwnerFailure { _ = try await fixture.request() }
        let probe = try await fixture.blockedProbe()
        let before = await fixture.coordinator.currentStatistics().submittedCount
        fixture.peer.drainFailure = nil
        try await fixture.owner.close()
        try await probe.value
        let after = await fixture.coordinator.currentStatistics().submittedCount
        XCTAssertEqual(after, before)
        XCTAssertTrue(fixture.peer.drainOperations.allSatisfy { $0 == operationID })
        XCTAssertEqual(fixture.peer.base.loadCount, 1)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testConfirmedLoadFailureRequiresFreshExplicitPreparation() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        fixture.peer.base.loadFailure = OmniXPCFailure.error(.nativeFailure, "Controlled load failure")
        await batchOwnerFailure(code: .nativeFailure) { try await fixture.owner.prepare() }
        let original = fixture.peer.base.loadOperationID
        await batchOwnerFailure { _ = try await fixture.request() }
        XCTAssertEqual(fixture.peer.base.loadCount, 1)
        fixture.peer.base.loadFailure = nil
        try await fixture.owner.prepare()
        XCTAssertNotEqual(fixture.peer.base.loadOperationID, original)
        _ = try await fixture.request()
        try await fixture.owner.close()
    }

    @MainActor
    func testRequestFailuresAwaitScopedDrainThenRequireExplicitReload() async throws {
        for outcome: BatchOwnerPeer.RequestOutcome in [.success, .nativeFailure, .malformed, .wrongIdentity] {
            let fixture = try BatchOwnerFixture()
            defer { fixture.dispose() }
            try await fixture.owner.prepare()
            let original = fixture.peer.base.loadOperationID
            fixture.peer.requestOutcome = outcome
            fixture.peer.holdRequestWork = outcome == .success
            fixture.peer.holdDrain = true
            var returned = false
            let request = Task { defer { returned = true }; return try await fixture.request(timeout: .milliseconds(20)) }
            try await batchOwnerWait { !fixture.peer.drainOperations.isEmpty }
            XCTAssertFalse(returned)
            XCTAssertEqual(fixture.hooks.restoreCount, 1)
            try fixture.assertReader(pinned: true)
            let probe = try await fixture.blockedProbe()
            fixture.peer.holdDrain = false
            fixture.peer.finishRequestWork()
            fixture.peer.releaseDrain()
            await batchOwnerFailure { _ = try await request.value }
            try await probe.value
            XCTAssertEqual(fixture.peer.drainOperations, [original!])
            XCTAssertEqual(fixture.hooks.restoreCount, 2)
            try fixture.assertReader(pinned: false)
            await batchOwnerFailure { _ = try await fixture.request() }
            XCTAssertEqual(fixture.peer.base.requestCount, 1)
            fixture.peer.requestOutcome = .success
            fixture.peer.holdRequestWork = false
            try await fixture.owner.prepare()
            XCTAssertNotEqual(fixture.peer.base.loadOperationID, original)
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testRequestCleanupFailureReusesHeldPermitWithoutNestedAdmission() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        fixture.peer.requestOutcome = .nativeFailure
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled cleanup failure")
        await batchOwnerFailure { _ = try await fixture.request() }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        let submitted = await fixture.coordinator.currentStatistics().submittedCount
        fixture.peer.drainFailure = nil
        try await fixture.owner.close()
        try await probe.value
        let after = await fixture.coordinator.currentStatistics().submittedCount
        XCTAssertEqual(after, submitted)
        XCTAssertEqual(fixture.hooks.restoreCount, 2)
        XCTAssertEqual(fixture.peer.base.requestCount, 1)
    }

    @MainActor
    func testPermanentCloseCancelsActiveWorkCoalescesCancelledWaitersAndIgnoresLateSuccess() async throws {
        for loading in [false, true] {
            let fixture = try BatchOwnerFixture()
            defer { fixture.dispose() }
            if !loading { try await fixture.owner.prepare() }
            fixture.peer.holdLoadWork = loading
            fixture.peer.holdRequestWork = !loading
            var published = false
            let work = Task { if loading { try await fixture.owner.prepare() } else { _ = try await fixture.request() }; published = true }
            try await batchOwnerWait { fixture.peer.nativeLoadActive || fixture.peer.nativeRequestActive }
            let first = Task { try await fixture.owner.close() }
            try await batchOwnerWait { !fixture.peer.drainOperations.isEmpty }
            let second = Task { try await fixture.owner.close() }
            first.cancel()
            second.cancel()
            await batchOwnerFailure { try await fixture.owner.prepare() }
            await batchOwnerFailure { _ = try await fixture.request() }
            try fixture.assertReader(pinned: true)
            let probe = try await fixture.blockedProbe()
            if loading { fixture.peer.finishLoadWork() } else { fixture.peer.finishRequestWork() }
            await batchOwnerFailure { try await work.value }
            try await first.value
            try await second.value
            try await probe.value
            XCTAssertFalse(published)
            XCTAssertTrue(fixture.owner.isClosed)
            XCTAssertEqual(fixture.peer.drainOperations.count, 1)
            try fixture.assertReader(pinned: false)
        }
    }

    @MainActor
    func testIdleCloseRetryIsNondeferrableUnderRecordingMemoryAndThermalPressure() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        await fixture.coordinator.setRecordingActive(true)
        await fixture.coordinator.setMemoryPressureConstrained(true)
        fixture.hooks.constrainThermalState()
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled destruction failure")
        await batchOwnerFailure { try await fixture.owner.close() }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        XCTAssertTrue(fixture.owner.isClosing)
        XCTAssertFalse(fixture.owner.isClosed)
        let probe = try await fixture.blockedProbe()
        fixture.peer.drainFailure = nil
        try await fixture.owner.close()
        try await probe.value
        XCTAssertEqual(fixture.hooks.beginCount, 1)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testEmptyWrongOwnerNeverClaimsAnotherPendingLoadOrResidentModel() async throws {
        for pending in [false, true] {
            let fixture = try BatchOwnerFixture()
            defer { fixture.dispose() }
            fixture.peer.base.corruptLoad = pending
            fixture.peer.drainFailure = pending ? OmniXPCFailure.error(.nativeFailure, "Controlled pending failure") : nil
            if pending { await batchOwnerFailure { _ = try await fixture.client.loadBatch(kind: .whisper, modelDirectory: fixture.directory) } }
            else { _ = try await fixture.client.loadBatch(kind: .whisper, modelDirectory: fixture.directory) }
            let drainCount = fixture.peer.drainOperations.count
            await batchOwnerFailure { try await fixture.owner.prepare() }
            try await fixture.owner.close()
            XCTAssertEqual(fixture.peer.drainOperations.count, drainCount)
            let statistics = await fixture.coordinator.currentStatistics()
            XCTAssertEqual(statistics.submittedCount, 1)
            fixture.peer.drainFailure = nil
            if pending { try await fixture.client.closePendingBatchLoad(requiredOperationID: fixture.client.pendingBatchLoad!.operationID) }
            else { try await fixture.client.closeBatchModel(fixture.client.batchModel!.reference!) }
        }
        let empty = try BatchOwnerFixture()
        defer { empty.dispose() }
        try await empty.owner.close()
        let statistics = await empty.coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 0)
        XCTAssertTrue(empty.peer.drainOperations.isEmpty)
    }

    @MainActor
    func testDisconnectRetainsReaderAndLaneWithoutReloadOrRetarget() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        fixture.client.invalidate()
        await batchOwnerFailure { try await fixture.owner.prepare() }
        await batchOwnerFailure { try await fixture.owner.close() }
        await batchOwnerFailure { try await fixture.owner.close() }
        XCTAssertFalse(fixture.owner.isClosed)
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        probe.cancel()
        await batchOwnerFailure { try await probe.value }
        XCTAssertEqual(fixture.peer.base.loadCount, 1)
        XCTAssertNotNil(fixture.client.batchModel)
        XCTAssertTrue(fixture.peer.drainOperations.isEmpty)
    }

    @MainActor
    func testInvalidArtifactsAndExternalPathsRejectBeforeNativeLoad() async throws {
        try await verifyBatchOwnerArtifactRejections()
    }

    @MainActor
    func testCancelledQueuedAndActiveRequestsKeepCorrectOwnership() async throws {
        try await verifyBatchOwnerRequestCancellation()
    }

    @MainActor
    func testCloseDeadlineRetainsOwnershipAndCoalescedRetryUsesOriginalPermit() async throws {
        try await verifyBatchOwnerCloseDeadlineRetry()
    }

    @MainActor
    func testDisconnectedLoadAndRequestCannotManufactureRetirementProof() async throws {
        try await verifyBatchOwnerActiveDisconnect()
    }

    @MainActor
    func testCancellationAfterStoredSuccessAwaitsCloseBeforePublishing() async throws {
        try await verifyBatchOwnerLateCallerCancellation()
    }

    @MainActor
    func testCachedPrepareRejectsBorrowedRequestAndClosingModel() async throws {
        try await verifyBatchOwnerBorrowedClientWork()
    }

    @MainActor
    func testFinalASRUsesRequestedPolicyWithoutFileCacheHooks() async throws {
        let fixture = try BatchOwnerFixture(workClass: .finalASR)
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        _ = try await fixture.request()
        try await fixture.owner.close()
        XCTAssertEqual(fixture.hooks.beginCount, 0)
        XCTAssertEqual(fixture.hooks.restoreCount, 0)
        let statistics = await fixture.coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 3)
        XCTAssertEqual(statistics.completedCount, 3)
    }

    @MainActor
    func testCachedPrepareRejectsClosedOrReplacedClientReference() async throws {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        let original = try XCTUnwrap(fixture.client.batchModel?.reference)
        try await fixture.client.closeBatchModel(original)
        await batchOwnerFailure { try await fixture.owner.prepare() }
        let replacement = try await fixture.client.loadBatch(kind: .moss, modelDirectory: fixture.directory)
        await batchOwnerFailure { try await fixture.owner.prepare() }
        try await fixture.owner.close()
        XCTAssertEqual(fixture.peer.drainOperations.count, 1)
        _ = try await fixture.client.transcribeBatch(replacement, audio: fixture.audio, settings: .moss())
        try await fixture.client.closeBatchModel(replacement)
    }
}
#endif
