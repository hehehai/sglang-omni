#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerOwnerAdmissionTests: XCTestCase {
    @MainActor
    func testExplicitPreparationAndInputValidationPrecedeRPCAndAdmission() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
        await speakerFailure { _ = try await fixture.owner.push(audio: fixture.audio) }
        var statistics = await fixture.coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 0)
        await speakerFailure { try await fixture.owner.prepare(timeout: .zero) }
        await speakerFailure { try await fixture.owner.prepare(cleanupTimeout: .zero) }
        XCTAssertTrue(fixture.peer.loadOperations.isEmpty)
        try await fixture.owner.prepare()
        for settings: OmniXPCSpeakerSettings in [.nemotron(), .moss(prompt: "<|audio_pad|><|audio_pad|>")] {
            await speakerFailure { try await fixture.owner.startSession(settings: settings) }
        }
        await speakerFailure { try await fixture.owner.startSession(settings: .moss(), timeout: .zero) }
        await speakerFailure { try await fixture.owner.startSession(settings: .moss(), cleanupTimeout: .zero) }
        statistics = await fixture.coordinator.currentStatistics()
        XCTAssertEqual(statistics.submittedCount, 1)
        XCTAssertTrue(fixture.peer.startSessions.isEmpty)
        try await fixture.owner.startSession(settings: .moss(prompt: "explicit"))
        let invalidAudio = [Data(), Data([0]), Data(repeating: 0, count: 32_001 * 4),
            [Float.nan.bitPattern.littleEndian].withUnsafeBytes { Data($0) },
            [Float.infinity.bitPattern.littleEndian].withUnsafeBytes { Data($0) }]
        for audio in invalidAudio {
            await speakerFailure { _ = try await fixture.owner.push(audio: audio) }
        }
        await speakerFailure { _ = try await fixture.owner.push(audio: fixture.audio, timeout: .zero) }
        await speakerFailure { _ = try await fixture.owner.poll(maximumEventCount: 0) }
        await speakerFailure { _ = try await fixture.owner.poll(maximumEventCount: 17) }
        XCTAssertTrue(fixture.peer.audioChunks.isEmpty)
        XCTAssertTrue(fixture.peer.pollAcknowledgements.isEmpty)
        XCTAssertEqual(fixture.peer.settings, [.moss(prompt: "explicit")])
        try await fixture.owner.close()
    }

    @MainActor
    func testNineInvalidWorkClassesNeverAcquireReaderOrSendNativeWork() async throws {
        for workClass: MeetingLocalInferenceWorkClass in [.modelCleanup, .liveASRFeed, .liveASRFinal, .liveASRPartial,
            .realtimeTranslation, .fileSpeakerAnalysis, .speakerAnalysis, .detailTranslation, .summary] {
            let fixture = try OmniXPCSpeakerFixture(workClass: workClass)
            defer { fixture.dispose() }
            await speakerFailure(code: .invalidRequest) { try await fixture.owner.prepare() }
            await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
            let statistics = await fixture.coordinator.currentStatistics()
            XCTAssertEqual(statistics.submittedCount, 0)
            XCTAssertTrue(fixture.peer.loadOperations.isEmpty)
            XCTAssertEqual(fixture.hooks.beginCount, 0)
            try fixture.assertReader(pinned: false)
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testActualArtifactReaderRejectsInvalidStructureAndBusyWriterBeforeLoad() async throws {
        for invalidArtifact in 0..<4 {
            let fixture = try OmniXPCSpeakerFixture()
            defer { fixture.dispose() }
            var writer: OmniModelDirectoryLease?
            switch invalidArtifact {
            case 0: try Data("not JSON".utf8).write(to: fixture.directory.appendingPathComponent("config.json"))
            case 1: try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("model.safetensors"))
            case 2: try Data([0]).write(to: fixture.directory.appendingPathComponent("model.safetensors"))
            default: writer = try OmniModelDirectoryLease.acquire(for: fixture.directory, mode: .exclusiveMutation)
            }
            await speakerFailure { try await fixture.owner.prepare() }
            withExtendedLifetime(writer) {}
            writer = nil
            XCTAssertTrue(fixture.peer.loadOperations.isEmpty)
            try fixture.assertReader(pinned: false)
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testQueuedStartCancellationPreservesPreparedModelAndIncumbentLane() async throws {
        for workClass: MeetingLocalInferenceWorkClass in [.fileASR, .finalASR] {
            let fixture = try OmniXPCSpeakerFixture(workClass: workClass)
            defer { fixture.dispose() }
            try await fixture.owner.prepare()
            let incumbent = try await fixture.coordinator.reserveOwnedPermit(.liveASRFinal)
            let starting = Task { try await fixture.owner.startSession(settings: .moss()) }
            try await speakerWait { await fixture.coordinator.currentStatistics().submittedCount == 3 }
            starting.cancel()
            await speakerFailure { try await starting.value }
            XCTAssertTrue(fixture.peer.startSessions.isEmpty)
            try fixture.assertReader(pinned: true)
            let probe = try await fixture.blockedProbe()
            try await fixture.coordinator.completeOwnedPermit(incumbent)
            try await probe.value
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testLateValidLoadAndStartRepliesCannotPublishAfterDeadline() async throws {
        for loading in [true, false] {
            let fixture = try OmniXPCSpeakerFixture()
            defer { fixture.dispose() }
            if !loading { try await fixture.owner.prepare() }
            fixture.peer.holdLoadReply = loading
            fixture.peer.holdStartReply = !loading
            var published = false
            let work = Task {
                if loading { try await fixture.owner.prepare(timeout: .milliseconds(20)) }
                else { try await fixture.owner.startSession(settings: .moss(), timeout: .milliseconds(20)) }
                published = true
            }
            try await speakerWait {
                loading ? !fixture.peer.drainOperations.isEmpty : !fixture.peer.closedSessions.isEmpty
            }
            try fixture.assertReader(pinned: true)
            XCTAssertEqual(fixture.peer.acknowledgedDrains, 0)
            let probe = try await fixture.blockedProbe()
            if loading { fixture.peer.completeLoad() } else { fixture.peer.completeStart() }
            await speakerFailure { try await work.value }
            try await probe.value
            XCTAssertFalse(published)
            XCTAssertFalse(fixture.owner.hasSession)
            XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
            try fixture.assertReader(pinned: false)
            await speakerFailure { try await fixture.owner.startSession(settings: .moss()) }
            XCTAssertEqual(fixture.peer.loadOperations.count, 1)
            try await fixture.owner.close()
        }
    }

    @MainActor
    func testIdleModelCloseBypassesPressureWithoutReplacingPreparedModel() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        await fixture.coordinator.setRecordingActive(true)
        await fixture.coordinator.setMemoryPressureConstrained(true)
        fixture.hooks.constrainThermalState()
        try await fixture.owner.close()
        XCTAssertEqual(fixture.peer.loadOperations.count, 1)
        XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
        XCTAssertEqual(fixture.hooks.beginCount, 1)
        XCTAssertTrue(fixture.owner.isClosed)
        try fixture.assertReader(pinned: false)
    }
}
#endif
