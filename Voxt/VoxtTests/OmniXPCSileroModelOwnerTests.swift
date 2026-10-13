#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSileroModelOwnerTests: XCTestCase {
    @MainActor
    func testValidationBeforeLoadAndPreparedReaderLifetime() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let invalid = OmniXPCSileroModelOwner(client: client, modelDirectory: directory.deletingLastPathComponent(), coordinator: coordinator)
        do { _ = try await invalid.prepare(); XCTFail("Models root accepted") } catch {}
        XCTAssertEqual(peer.loadCount, 0)
        try await invalid.close()
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("config.json"))
        let malformed = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        do { _ = try await malformed.prepare(); XCTFail("Malformed artifacts accepted") } catch {}
        XCTAssertEqual(peer.loadCount, 0)
        _ = try await coordinator.withPermit(.liveASRFinal) { 1 }
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        try await malformed.close()
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        let model = try await owner.prepare()
        let reused = try await owner.prepare()
        XCTAssertEqual(model, reused)
        XCTAssertEqual(peer.loadCount, 1)
        XCTAssertEqual(try owner.requirePreparedModel(), model)
        try assertSileroReaderBusy(directory)
        _ = try await coordinator.withPermit(.liveASRFinal) { 2 }
        try await owner.close()
        XCTAssertEqual(peer.drainedOperationIDs, [try XCTUnwrap(peer.loadOperationID)])
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        do { _ = try await owner.prepare(); XCTFail("Closed owner reopened") } catch {}
    }

    @MainActor
    func testSubmittedMalformedLoadFailedBarrierRetainsReaderAndLaneForOriginalScopeRetry() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        peer.corruptLoadIdentity = true
        peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled failed retirement")
        do { _ = try await owner.prepare(); XCTFail("Malformed submitted load succeeded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        let originalOperationID = try XCTUnwrap(peer.loadOperationID)
        XCTAssertNotNil(client.pendingSileroLoad)
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        peer.drainFailure = nil
        try await owner.close()
        XCTAssertTrue(peer.drainedOperationIDs.allSatisfy { $0 == originalOperationID })
        XCTAssertEqual(peer.loadCount, 1)
        _ = try await coordinator.withPermit(.liveASRFinal) { 3 }
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testSubmittedTicketCannotBeRetiredByMissingClientMap() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        let model = try await owner.prepare()
        let ticket = try XCTUnwrap(owner.loadOwnership)
        XCTAssertEqual(ticket.phase, .submitted(connectionID: model.connectionID))
        let retainedState = try XCTUnwrap(client.sileroModel)
        client.sileroModel = nil
        do { try await owner.close(); XCTFail("Absent client state certified submitted ticket retirement") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(ticket.phase, .submitted(connectionID: model.connectionID))
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        XCTAssertTrue(peer.drainedOperationIDs.isEmpty)
        client.sileroModel = retainedState
        try await owner.close()
        XCTAssertEqual(ticket.phase, .drained)
        XCTAssertEqual(peer.drainedOperationIDs, [ticket.operationID.uuidString])
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testAmbiguousCommandFailureHoldsPermitAndReaderUntilOriginalModelDrainRetry() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        let ticket = try XCTUnwrap(owner.loadOwnership)
        let stream = try await owner.openStream()
        peer.blockPush = true
        peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled command retirement failure")
        do {
            _ = try await owner.pushAudio(Data(repeating: 0, count: 2048), to: stream, sequence: 1, timeout: .milliseconds(20))
            XCTFail("Ambiguous command released its retirement scope")
        } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(peer.pushCount, 1)
        XCTAssertGreaterThanOrEqual(peer.cancelCount, 1)
        XCTAssertEqual(peer.closeStreamCount, 1)
        XCTAssertEqual(peer.drainedOperationIDs, [ticket.operationID.uuidString])
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        XCTAssertThrowsError(try owner.requirePreparedModel())
        peer.drainFailure = nil
        try await owner.close()
        XCTAssertEqual(ticket.phase, .drained)
        XCTAssertEqual(peer.drainedOperationIDs, [ticket.operationID.uuidString, ticket.operationID.uuidString])
        _ = try await coordinator.withPermit(.liveASRFinal) { 9 }
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testRawTicketMarksSubmissionOnlyAtLoadAndRejectsForeignClient() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ticket = OmniXPCSileroLoadOwnership(client: client)
        XCTAssertEqual(ticket.phase, .notSubmitted)
        do {
            _ = try await client.loadSilero(modelDirectory: "Models/" + directory.lastPathComponent, timeout: .zero,
                                            operationID: ticket.operationID, ownership: ticket)
            XCTFail("Invalid timeout submitted a ticket")
        } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(ticket.phase, .notSubmitted)
        XCTAssertEqual(peer.loadCount, 0)
        let model = try await client.loadSilero(modelDirectory: "Models/" + directory.lastPathComponent,
                                                operationID: ticket.operationID, ownership: ticket)
        XCTAssertEqual(ticket.phase, .submitted(connectionID: model.connectionID))
        let (foreignClient, _, foreignDirectory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: foreignDirectory) }
        do { try await foreignClient.retireSileroLoad(ticket, timeout: .seconds(1)); XCTFail("Foreign client retired ticket") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(ticket.phase, .submitted(connectionID: model.connectionID))
        try await client.retireSileroLoad(ticket, timeout: .seconds(1))
        XCTAssertEqual(ticket.phase, .drained)
        XCTAssertEqual(peer.drainedOperationIDs, [ticket.operationID.uuidString])
    }

    @MainActor
    func testLostDrainReplyRetainsClaimsAndRetryNeverReloads() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        let originalOperationID = try XCTUnwrap(peer.loadOperationID)
        peer.loseDrainReply = true
        do { try await owner.close(timeout: .milliseconds(20)); XCTFail("Lost drain reply certified retirement") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.timedOut.rawValue) }
        XCTAssertNotNil(client.sileroModel)
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        peer.loseDrainReply = false
        try await owner.close()
        XCTAssertEqual(peer.drainedOperationIDs, [originalOperationID, originalOperationID])
        XCTAssertEqual(peer.loadCount, 1)
        _ = try await coordinator.withPermit(.liveASRFinal) { 4 }
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testDisconnectRetainsReaderAndLaneWithoutRetargeting() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        client.invalidate()
        do { try await owner.close(); XCTFail("Disconnect certified retirement") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.disconnected.rawValue) }
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        do { try await owner.close(); XCTFail("Retry retargeted disconnected scope") } catch {}
        XCTAssertEqual(peer.loadCount, 1)
        XCTAssertTrue(peer.drainedOperationIDs.isEmpty)
    }

    @MainActor
    func testCancellationAndConcurrentCloseAwaitOneUncancelledBarrier() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        peer.blockLoad = true
        peer.blockDrain = true
        var prepareReturned = false
        let preparing = Task { defer { prepareReturned = true }; return try await owner.prepare() }
        try await awaitSileroCondition { peer.loadCount == 1 }
        preparing.cancel()
        try await awaitSileroCondition { !peer.drainedOperationIDs.isEmpty }
        var firstClosed = false, secondClosed = false
        let first = Task { try await owner.close(); firstClosed = true }
        let second = Task { try await owner.close(); secondClosed = true }
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(prepareReturned)
        XCTAssertFalse(firstClosed)
        XCTAssertFalse(secondClosed)
        XCTAssertEqual(peer.drainedOperationIDs.count, 1)
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        peer.releaseLoad()
        peer.releaseDrain()
        do { _ = try await preparing.value; XCTFail("Cancelled preparation succeeded") } catch is CancellationError {}
        try await first.value
        try await second.value
        XCTAssertEqual(peer.drainedOperationIDs.count, 1)
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testCommandPermitsCoverBlockedPushAndOfflineCalls() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        let stream = try await owner.openStream()
        peer.blockPush = true
        let pushing = Task { try await owner.pushAudio(Data(repeating: 0, count: 2048), to: stream, sequence: 1) }
        try await awaitSileroCondition { peer.pushCount == 1 }
        try await assertSileroLaneBlocked(coordinator)
        peer.releasePush()
        _ = try await pushing.value
        _ = try await coordinator.withPermit(.liveASRFinal) { 5 }
        peer.blockOffline = true
        let offline = Task {
            try await owner.speechTimestamps(samples16k: [0, 1], settings: sileroOwnerSettings)
        }
        try await awaitSileroCondition { peer.offlineCount == 1 }
        try await assertSileroLaneBlocked(coordinator)
        peer.releaseOffline()
        let ranges = try await offline.value
        XCTAssertEqual(ranges, [0..<2])
        try await owner.close()
    }

    @MainActor
    func testStreamCloseCoalescesBarrierAndDoesNotCancelEntrustedCleanup() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        let stream = try await owner.openStream()
        peer.blockStreamClose = true
        var closedCount = 0
        let first = Task { try await owner.closeStream(stream); closedCount += 1 }
        let second = Task { try await owner.closeStream(stream); closedCount += 1 }
        try await awaitSileroCondition { peer.closeStreamCount == 1 }
        first.cancel()
        try await assertSileroLaneBlocked(coordinator)
        XCTAssertEqual(closedCount, 0)
        XCTAssertEqual(peer.closeStreamCount, 1)
        peer.releaseStreamClose()
        try await first.value
        try await second.value
        XCTAssertEqual(closedCount, 2)
        XCTAssertEqual(peer.closeStreamCount, 1)
        _ = try owner.requirePreparedModel()
        try await owner.close()
    }

    @MainActor
    func testSixteenStreamsAndStrictSequenceAreEnforcedBeforeSubmission() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: MeetingLocalInferenceCoordinator())
        _ = try await owner.prepare()
        var streams: [OmniXPCSileroStreamReference] = []
        for _ in 0..<16 { streams.append(try await owner.openStream()) }
        do { _ = try await owner.openStream(); XCTFail("Seventeenth stream admitted") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        XCTAssertEqual(peer.startCount, 16)
        do { _ = try await owner.pushAudio(Data(repeating: 0, count: 2048), to: streams[0], sequence: 2); XCTFail("Sequence gap admitted") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(peer.pushCount, 0)
        let batch = try await owner.pushAudio(Data(repeating: 0, count: 2048), to: streams[0], sequence: 1)
        XCTAssertEqual(batch.probabilities, [Float(1) / 16])
        do { _ = try await owner.pushAudio(Data(repeating: 0, count: 2048), to: streams[0], sequence: 1); XCTFail("Duplicate sequence admitted") } catch {}
        XCTAssertEqual(peer.pushCount, 1)
        try await owner.close()
    }
}

let sileroOwnerSettings = OmniXPCSileroSettings(
    threshold: 0.5, minimumSpeechMilliseconds: 0, minimumSilenceMilliseconds: 0, speechPaddingMilliseconds: 0
)
#endif
