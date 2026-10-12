#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSortformerLoadOwnershipTests: XCTestCase {
    @MainActor
    func testLoadCancellationAndDeadlineAwaitDrainDespiteLateSuccessAndCancelAcknowledgement() async throws {
        for cancelled in [false, true] {
            let (client, model, peer, directory) = try await fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            peer.blockLoad = true
            peer.blockLoadDrain = true
            var returned = false
            let loading = Task {
                defer { returned = true }
                return try await client.loadSortformer(modelDirectory: directory, timeout: cancelled ? .seconds(30) : .milliseconds(10))
            }
            try await wait { peer.loadCount == 2 }
            if cancelled { loading.cancel() }
            try await wait { peer.loadDrainCount == 1 }
            XCTAssertFalse(returned)
            XCTAssertEqual(peer.cancelCount, 1)
            XCTAssertEqual(peer.drainedLoadOperationID, peer.loadOperationID)
            XCTAssertEqual(client.connectionIdentifier, model.connectionID)
            XCTAssertNotNil(client.pendingSortformerLoad)
            peer.releaseLoad()
            XCTAssertFalse(returned)
            peer.releaseLoadDrain()
            do { _ = try await loading.value; XCTFail("Abandoned load succeeded") }
            catch is CancellationError { XCTAssertTrue(cancelled) }
            catch { XCTAssertFalse(cancelled); XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.timedOut.rawValue) }
            XCTAssertNil(client.pendingSortformerLoad)
            XCTAssertEqual(peer.otherCancelCount, 0)
        }
    }

    @MainActor
    func testMalformedLoadAndNativeFailureWaitForTheScopedDrain() async throws {
        for malformed in [false, true] {
            let (client, _, peer, directory) = try await fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            peer.corruptLoadIdentity = malformed
            peer.loadFailure = malformed ? nil : OmniXPCFailure.error(.nativeFailure, "Controlled model creation failure")
            peer.blockLoadDrain = true
            var returned = false
            let loading = Task {
                defer { returned = true }
                return try await client.loadSortformer(modelDirectory: directory)
            }
            try await wait { peer.loadDrainCount == 1 }
            XCTAssertFalse(returned)
            XCTAssertNotNil(client.pendingSortformerLoad)
            peer.releaseLoadDrain()
            do { _ = try await loading.value; XCTFail("Invalid load succeeded") }
            catch { XCTAssertEqual((error as NSError).code, (malformed ? OmniXPCFailure.Code.incompatibleService : .nativeFailure).rawValue) }
            XCTAssertNil(client.pendingSortformerLoad)
            XCTAssertEqual(peer.cancelCount, 0)
        }
    }

    @MainActor
    func testCleanupFailureRetainsTicketBlocksReplacementAndCoalescesRetry() async throws {
        let (client, model, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        peer.corruptLoadIdentity = true
        peer.loadDrainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        do { _ = try await client.loadSortformer(modelDirectory: directory); XCTFail("Cleanup failure was hidden") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        let ticket = try XCTUnwrap(client.pendingSortformerLoad)
        XCTAssertEqual(ticket.connectionID, model.connectionID)
        do { _ = try await client.loadSortformer(modelDirectory: directory); XCTFail("An unresolved load was replaced") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        XCTAssertEqual(peer.loadCount, 2)
        peer.loadDrainFailure = nil
        peer.blockLoadDrain = true
        let first = Task { try await client.closePendingSortformerLoad() }
        let second = Task { try await client.closePendingSortformerLoad() }
        try await wait { peer.loadDrainCount == 2 }
        XCTAssertEqual(peer.drainedLoadOperationID, ticket.operationID.uuidString)
        peer.releaseLoadDrain()
        try await first.value
        try await second.value
        XCTAssertEqual(peer.loadDrainCount, 2)
        XCTAssertNil(client.pendingSortformerLoad)
        peer.corruptLoadIdentity = false
        let recovered = try await client.loadSortformer(modelDirectory: directory)
        XCTAssertEqual(recovered.connectionID, model.connectionID)
        try await client.unloadSortformer(recovered)
    }

    @MainActor
    func testCleanupDeadlineIsNotCompletionAndSameConnectionRetryDoesNotReplayLoad() async throws {
        let (client, model, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        peer.corruptLoadIdentity = true
        peer.blockLoadDrain = true
        do {
            _ = try await client.loadSortformer(modelDirectory: directory, cleanupTimeout: .milliseconds(10))
            XCTFail("Timed out drain succeeded")
        } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.timedOut.rawValue) }
        let originalID = peer.loadOperationID
        XCTAssertNotNil(client.pendingSortformerLoad)
        XCTAssertEqual(client.connectionIdentifier, model.connectionID)
        XCTAssertEqual(peer.cancelCount, 0)
        peer.blockLoadDrain = false
        try await client.closePendingSortformerLoad()
        XCTAssertEqual(peer.loadCount, 2)
        XCTAssertEqual(peer.drainedLoadOperationID, originalID)
        XCTAssertNil(client.pendingSortformerLoad)
    }

    @MainActor
    func testLostConnectionRetainsUnconfirmedCleanupAndCannotRetargetAReplacement() async throws {
        let (client, model, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        peer.blockLoad = true
        let loading = Task { try await client.loadSortformer(modelDirectory: directory) }
        try await wait { peer.loadCount == 2 }
        client.invalidate()
        do { _ = try await loading.value; XCTFail("Disconnected load succeeded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.disconnected.rawValue) }
        XCTAssertEqual(client.pendingSortformerLoad?.connectionID, model.connectionID)
        do { try await client.closePendingSortformerLoad(); XCTFail("A lost connection certified drain") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.disconnected.rawValue) }
        XCTAssertEqual(peer.loadDrainCount, 0)
        do { _ = try await client.loadSortformer(modelDirectory: directory); XCTFail("Unknown ownership was discarded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        peer.releaseLoad()
        XCTAssertNotNil(client.pendingSortformerLoad)
    }

    @MainActor
    func testConcurrentLoadOrCleanupCannotOvertakeInFlightLoad() async throws {
        let (client, _, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        peer.blockLoad = true
        let first = Task { try await client.loadSortformer(modelDirectory: directory) }
        try await wait { peer.loadCount == 2 }
        do { _ = try await client.loadSortformer(modelDirectory: directory); XCTFail("Concurrent load admitted") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        do { try await client.closePendingSortformerLoad(); XCTFail("In-flight load was discarded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        peer.releaseLoad()
        let model = try await first.value
        XCTAssertNil(client.pendingSortformerLoad)
        XCTAssertEqual(peer.loadDrainCount, 0)
        try await client.unloadSortformer(model)
    }

    @MainActor
    func testCoalescedCloseAndImmediateNextFailedLoadEachAwaitTheirOwnDrain() async throws {
        let (client, _, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        peer.corruptLoadIdentity = true
        for _ in 0..<100 {
            let previousDrainCount = peer.loadDrainCount
            peer.blockLoadDrain = true
            let first = Task(priority: .background) {
                do { _ = try await client.loadSortformer(modelDirectory: directory); XCTFail("Malformed first load succeeded") }
                catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue) }
            }
            try await wait { peer.loadDrainCount == previousDrainCount + 1 }
            var coalescerStarted = false
            let next = Task(priority: .high) {
                coalescerStarted = true
                try await client.closePendingSortformerLoad()
                peer.blockLoadDrain = false
                do { _ = try await client.loadSortformer(modelDirectory: directory); XCTFail("Malformed next load succeeded") }
                catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue) }
                XCTAssertEqual(peer.loadDrainCount, previousDrainCount + 2)
                XCTAssertNil(client.pendingSortformerLoad)
            }
            try await wait { coalescerStarted }
            peer.releaseLoadDrain()
            try await next.value
            await first.value
        }
    }

    @MainActor
    func testInvalidLocalTimeoutDoesNotSubmitOrCreateARecoveryTicket() async throws {
        let (client, _, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (timeout, cleanupTimeout) in [(Duration.zero, Duration.seconds(1)), (.seconds(1), .zero)] {
            do { _ = try await client.loadSortformer(modelDirectory: directory, timeout: timeout, cleanupTimeout: cleanupTimeout); XCTFail("Invalid timeout accepted") }
            catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        }
        XCTAssertEqual(peer.loadCount, 1)
        XCTAssertNil(client.pendingSortformerLoad)
        XCTAssertEqual(peer.loadDrainCount, 0)
    }

    @MainActor
    func testLoadedModelCloseAwaitsOriginalLoadDrainAndRejectsNewWork() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        let settings = try OmniXPCSortformerSettings(threshold: 0.5, minimumDurationSeconds: 0,
            mergeGapSeconds: 0.18, speakerCacheMaximumFrameCount: 188, fifoMaximumFrameCount: 188)
        let stream = try await client.startSortformerStream(model: model, settings: settings)
        let originalLoadID = peer.loadOperationID
        peer.blockLoadDrain = true
        var closed = false
        let closing = Task { try await client.closeSortformerModel(model); closed = true }
        try await wait { peer.loadDrainCount == 1 }
        XCTAssertFalse(closed)
        XCTAssertEqual(peer.drainedLoadOperationID, originalLoadID)
        XCTAssertNotNil(client.sortformerModel)
        XCTAssertEqual(client.sortformerStreams.count, 1)
        do { _ = try await client.startSortformerStream(model: model, settings: settings); XCTFail("Retiring model accepted a start") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        do { _ = try await client.pushSortformerAudio(Data(repeating: 0, count: 4), to: stream, sequence: 1); XCTFail("Retiring stream accepted audio") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        peer.releaseLoadDrain()
        try await closing.value
        XCTAssertNil(client.sortformerModel)
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        try await client.closeSortformerModel(model)
        XCTAssertEqual(peer.loadDrainCount, 1)
    }

    @MainActor
    func testFailedModelCloseRetainsBindingsAndCoalescesSameModelRetry() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        peer.loadDrainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled model destruction failure")
        do { try await client.closeSortformerModel(model); XCTFail("Failed model drain acknowledged") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(client.sortformerModel?.reference, model)
        XCTAssertNil(client.closedSortformerModels[model.modelID])
        peer.loadDrainFailure = nil
        peer.blockLoadDrain = true
        let first = Task { try await client.closeSortformerModel(model) }
        let second = Task { try await client.closeSortformerModel(model) }
        try await wait { peer.loadDrainCount == 2 }
        peer.releaseLoadDrain()
        try await first.value
        try await second.value
        XCTAssertEqual(peer.loadDrainCount, 2)
        XCTAssertNil(client.sortformerModel)
    }

    @MainActor
    func testUnloadTimeoutCanRetireByOriginalLoadEvenAfterItsReplyWasLost() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        peer.blockUnload = true
        let originalLoadID = peer.loadOperationID
        do { try await client.unloadSortformer(model, timeout: .milliseconds(10)); XCTFail("Blocked unload succeeded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.timedOut.rawValue) }
        XCTAssertEqual(client.sortformerModel?.reference, model)
        try await client.closeSortformerModel(model)
        XCTAssertEqual(peer.drainedLoadOperationID, originalLoadID)
        XCTAssertNil(client.sortformerModel)
        peer.releaseUnload()
        try await client.closeSortformerModel(model)
        XCTAssertEqual(peer.loadDrainCount, 1)
    }

    @MainActor
    func testModelDrainRetiresFailedProvisionalStartWithoutStreamActor() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        peer.startFailure = OmniXPCFailure.error(.nativeFailure, "Controlled ambiguous stream creation")
        peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled stream cleanup failure")
        let settings = try OmniXPCSortformerSettings(threshold: 0.5, minimumDurationSeconds: 0,
            mergeGapSeconds: 0.18, speakerCacheMaximumFrameCount: 188, fifoMaximumFrameCount: 188)
        do { _ = try await client.startSortformerStream(model: model, settings: settings); XCTFail("Failed start succeeded") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(client.sortformerStreams.count, 1)
        try await client.closeSortformerModel(model)
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        XCTAssertNil(client.sortformerModel)
        XCTAssertEqual(peer.loadDrainCount, 1)
    }

    @MainActor
    func testForgedModelCannotDrainAndOldCloseCannotAffectReplacement() async throws {
        let (client, model, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacement = try await client.loadSortformer(modelDirectory: directory)
        let forged = OmniXPCSortformerModelReference(modelID: replacement.modelID, serviceInstanceID: UUID(), connectionID: replacement.connectionID)
        do { try await client.closeSortformerModel(forged); XCTFail("Forged model retired") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        try await client.closeSortformerModel(model)
        XCTAssertEqual(peer.loadDrainCount, 0)
        XCTAssertEqual(client.sortformerModel?.reference, replacement)
        try await client.closeSortformerModel(replacement)
        XCTAssertNil(client.sortformerModel)
        client.invalidate()
        do { try await client.closeSortformerModel(replacement); XCTFail("Lost connection certified old cleanup") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
    }

    @MainActor
    private func fixture() async throws -> (OmniXPCClient, OmniXPCSortformerModelReference, SortformerOwnershipPeer, URL) {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        try await client.unloadSortformer(model)
        let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
        let directory = container.appendingPathComponent("Models/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (client, model, peer, directory)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LoadOwnershipFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
private enum LoadOwnershipFailure: Error { case deadline }
#endif
