#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSortformerModelOwnerTests: XCTestCase {
    @MainActor
    func testPreparationReleasesCommandLaneButRetainsReaderUntilModelClose() async throws {
        let (client, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = OwnerCacheHooks()
        let coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { hooks.begin() })
        let owner = OmniXPCSortformerModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        let prepared = try await owner.prepare()
        XCTAssertEqual(prepared.configuration.sampleRate, 16_000)
        XCTAssertEqual(peer.loadCount, 2)
        XCTAssertEqual(hooks.restoreCount, 1)
        try assertReaderBusy(directory)
        _ = try await coordinator.withPermit(.liveASRFinal) { 7 }
        let reused = try await owner.prepare()
        XCTAssertEqual(reused.model, prepared.model)
        XCTAssertEqual(peer.loadCount, 2)
        peer.blockLoadDrain = true
        var closed = false
        let closing = Task { try await owner.close(); closed = true }
        try await wait { peer.loadDrainCount == 1 }
        XCTAssertFalse(closed)
        try assertReaderBusy(directory)
        peer.releaseLoadDrain()
        try await closing.value
        XCTAssertTrue(owner.isClosed)
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        try await owner.close()
        XCTAssertEqual(peer.loadDrainCount, 1)
    }

    @MainActor
    func testCancelledLoadingAndCloseHoldLaneAndReaderThroughActualDrain() async throws {
        let (client, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = OwnerCacheHooks()
        let coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { hooks.begin() })
        let owner = OmniXPCSortformerModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        peer.blockLoad = true
        peer.blockLoadDrain = true
        var returned = false, probeRan = false
        let preparing = Task { defer { returned = true }; return try await owner.prepare() }
        try await wait { peer.loadCount == 2 }
        let closing = Task { try await owner.close() }
        try await wait { peer.loadDrainCount == 1 }
        let probe = Task { try await coordinator.withPermit(.liveASRFinal) { await MainActor.run { probeRan = true } } }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(returned)
        XCTAssertFalse(probeRan)
        XCTAssertEqual(hooks.restoreCount, 0)
        try assertReaderBusy(directory)
        peer.releaseLoad()
        peer.releaseLoadDrain()
        do { _ = try await preparing.value; XCTFail("Cancelled preparation succeeded") } catch is CancellationError {}
        try await closing.value
        try await probe.value
        XCTAssertTrue(owner.isClosed)
        XCTAssertEqual(hooks.restoreCount, 1)
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testFailedLoadCleanupRetainsPermitReaderAndOriginalOperationForRetry() async throws {
        let (client, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = OwnerCacheHooks()
        let coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { hooks.begin() })
        let owner = OmniXPCSortformerModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        peer.corruptLoadIdentity = true
        peer.loadDrainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled persistent drain failure")
        do { _ = try await owner.prepare(); XCTFail("Cleanup failure hidden") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        let originalOperation = peer.loadOperationID
        XCTAssertNotNil(client.pendingSortformerLoad)
        XCTAssertEqual(hooks.restoreCount, 0)
        try assertReaderBusy(directory)
        do { _ = try await owner.prepare(); XCTFail("Failed owner reopened") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        var probeRan = false
        let probe = Task { try await coordinator.withPermit(.liveASRFinal) { await MainActor.run { probeRan = true } } }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(probeRan)
        peer.loadDrainFailure = nil
        try await owner.close()
        try await probe.value
        XCTAssertEqual(peer.drainedLoadOperationID, originalOperation)
        XCTAssertEqual(peer.loadCount, 2)
        XCTAssertEqual(hooks.restoreCount, 1)
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    @MainActor
    func testFailedRetirementKeepsCleanupLaneAndCanCoalesceRetryUnderPressure() async throws {
        let (client, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = OwnerCacheHooks()
        let coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { hooks.begin() }, readThermalState: { hooks.thermalState })
        let owner = OmniXPCSortformerModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        await coordinator.setMemoryPressureConstrained(true)
        await coordinator.setRecordingActive(true)
        hooks.setCritical()
        peer.loadDrainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled model destruction failure")
        do { try await owner.close(); XCTFail("Failed retirement acknowledged") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertFalse(owner.isClosed)
        XCTAssertTrue(owner.isClosing)
        try assertReaderBusy(directory)
        var probeRan = false
        let probe = Task { try await coordinator.withPermit(.liveASRFinal) { await MainActor.run { probeRan = true } } }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(probeRan)
        peer.loadDrainFailure = nil
        peer.blockLoadDrain = true
        let before = peer.loadDrainCount
        async let first: Void = owner.close()
        async let second: Void = owner.close()
        try await wait { peer.loadDrainCount == before + 1 }
        peer.releaseLoadDrain()
        _ = try await (first, second)
        try await probe.value
        XCTAssertEqual(peer.loadDrainCount, before + 1)
        XCTAssertEqual(hooks.restoreCount, 1)
    }

    @MainActor
    func testLostConnectionRetainsOwnerReaderAndCleanupLaneWithoutRetargeting() async throws {
        let (client, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSortformerModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        client.invalidate()
        do { try await owner.close(); XCTFail("Lost connection certified owner cleanup") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertFalse(owner.isClosed)
        try assertReaderBusy(directory)
        var probeRan = false
        let probe = Task { try await coordinator.withPermit(.liveASRFinal) { await MainActor.run { probeRan = true } } }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(probeRan)
        probe.cancel()
        do { try await probe.value; XCTFail("Cancelled probe succeeded") } catch is CancellationError {}
    }

    @MainActor
    func testOtherOwnersModelOrLoadIsNeverRetiredByFailedPreparation() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
        let directory = container.appendingPathComponent("Models/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"modules_config\":{\"use_aosc\":true}}".utf8).write(to: directory.appendingPathComponent("config.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSortformerModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        do { _ = try await owner.prepare(); XCTFail("Another owner's model was replaced") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        XCTAssertEqual(peer.loadDrainCount, 0)
        XCTAssertEqual(client.sortformerModel?.reference, model)
        try await owner.close()
        XCTAssertEqual(peer.loadDrainCount, 0)
        try await client.closeSortformerModel(model)
    }

    @MainActor
    func testInvalidPathAndConfigurationRejectBeforeNativeLoadAndReleaseLane() async throws {
        let (client, peer, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for invalidPath in [false, true] {
            let hooks = OwnerCacheHooks()
            let coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { hooks.begin() })
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
            let owner = OmniXPCSortformerModelOwner(client: client,
                modelDirectory: invalidPath ? FileManager.default.temporaryDirectory : directory, coordinator: coordinator)
            do { _ = try await owner.prepare(); XCTFail("Invalid preparation succeeded") } catch {}
            XCTAssertEqual(peer.loadCount, 1)
            XCTAssertEqual(hooks.restoreCount, 1)
            _ = try await coordinator.withPermit(.liveASRFinal) { 3 }
            try await owner.close()
            XCTAssertEqual(peer.loadDrainCount, 0)
        }
    }

    @MainActor
    private func fixture() async throws -> (OmniXPCClient, SortformerOwnershipPeer, URL) {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        try await client.unloadSortformer(model)
        let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
        let directory = container.appendingPathComponent("Models/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"modules_config\":{\"use_aosc\":true}}".utf8).write(to: directory.appendingPathComponent("config.json"))
        return (client, peer, directory)
    }

    private func assertReaderBusy(_ directory: URL) throws {
        do { _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation); XCTFail("Owner reader released before retirement") }
        catch OmniModelStorageError.busy {}
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OwnerTestFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
private enum OwnerTestFailure: Error { case deadline }
private nonisolated final class OwnerCacheHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var restored = 0
    private var critical = false
    var restoreCount: Int { lock.withLock { restored } }
    var thermalState: ProcessInfo.ThermalState { lock.withLock { critical ? .critical : .nominal } }
    func setCritical() { lock.withLock { critical = true } }
    func begin() -> @Sendable () -> Void { { self.lock.withLock { self.restored += 1 } } }
}
#endif
