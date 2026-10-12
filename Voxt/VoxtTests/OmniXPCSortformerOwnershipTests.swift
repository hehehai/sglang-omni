#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSortformerOwnershipTests: XCTestCase {
    @MainActor
    func testStructuredReturnAndThrowAwaitBarrier() async throws {
        for shouldThrow in [false, true] {
            let (client, model, peer) = try await makeSortformerOwnershipFixture()
            peer.blockClose = true
            var returned = false
            let operation = Task {
                defer { returned = true }
                return try await client.withSortformerDiarizationStream(model: model, settings: settings()) { stream in
                    let batch = try await stream.feed(samples16k: [0])
                    XCTAssertEqual(batch.probabilities, [0.1, 0.2, 0.3, 0.4])
                    XCTAssertEqual(batch.segments.first?.speakerIndex, 3)
                    if shouldThrow { throw SortformerOwnershipFailure.operation }
                    return 7
                }
            }
            try await wait { peer.closeCount == 1 }
            XCTAssertFalse(returned)
            XCTAssertEqual(client.sortformerStreams.count, 1)
            peer.releaseClose()
            if shouldThrow {
                do { _ = try await operation.value; XCTFail("Operation error lost") }
                catch SortformerOwnershipFailure.operation {}
            } else { let value = try await operation.value; XCTAssertEqual(value, 7) }
            XCTAssertTrue(client.sortformerStreams.isEmpty)
        }
    }

    @MainActor
    func testCancellationStartsCloseButCannotForceNoncooperativeOperationReturn() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        let gate = SortformerOwnershipGate()
        var returned = false
        let operation = Task {
            defer { returned = true }
            try await client.withSortformerDiarizationStream(model: model, settings: settings()) { _ in await gate.wait() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isWaiting) {
            guard ContinuousClock.now < deadline else { throw SortformerOwnershipFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
        operation.cancel()
        try await wait { client.sortformerStreams.isEmpty }
        XCTAssertFalse(returned)
        XCTAssertEqual(peer.closeCount, 1)
        await gate.open()
        do { try await operation.value; XCTFail("Cancelled scope succeeded") } catch is CancellationError {}
    }

    @MainActor
    func testRawActorPreservesWholeDTOSettingsAndFinishHasNoTail() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        let stream = try await OmniXPCDiarizationStream.open(client: client, model: model, settings: settings())
        XCTAssertEqual(peer.settings, try settings())
        do { _ = try await stream.feed(samples16k: [.nan]); XCTFail("NaN accepted") } catch {}
        let batch = try await stream.feed(samples16k: Array(repeating: 0, count: 1280))
        XCTAssertEqual(batch, peer.lastBatch)
        XCTAssertEqual(batch.audioSequence, 1)
        XCTAssertEqual(batch.frameCount, 2)
        XCTAssertEqual(peer.closeCount, 0)
        try await stream.finish()
        try await stream.close()
        XCTAssertEqual(peer.finishCount, 1)
        XCTAssertEqual(peer.pushCount, 1)
        XCTAssertEqual(peer.closeCount, 0)
        XCTAssertTrue(client.sortformerStreams.isEmpty)
    }

    @MainActor
    func testCancelAcknowledgementIsNotDrainAndOverlapDoesNotResubmitAudio() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        peer.blockPush = true
        peer.blockClose = true
        let stream = try await OmniXPCDiarizationStream.open(client: client, model: model, settings: settings())
        let feeding = Task { try await stream.feed(samples16k: [0]) }
        try await wait { peer.pushCount == 1 }
        do { try await stream.finish(); XCTFail("Overlapping finish accepted") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        let reference = try XCTUnwrap(client.sortformerStreams.values.first?.reference)
        try await client.cancelSortformerStream(reference)
        XCTAssertEqual(client.sortformerStreams.count, 1)
        var closed = false
        let closing = Task { try await stream.close(); closed = true }
        try await wait { peer.closeCount == 1 }
        XCTAssertFalse(closed)
        peer.releaseClose()
        try await closing.value
        do { _ = try await feeding.value; XCTFail("Abandoned feed succeeded") } catch {}
        XCTAssertEqual(peer.pushCount, 1)
        XCTAssertTrue(client.sortformerStreams.isEmpty)
    }

    @MainActor
    func testFailedCloseRetainsTerminalActorAndSameActorRetryCoalesces() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        let stream = try await OmniXPCDiarizationStream.open(client: client, model: model, settings: settings())
        peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        do { try await stream.close(); XCTFail("Drain failure hidden") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(client.sortformerStreams.count, 1)
        XCTAssertTrue(client.closedSortformerStreams.isEmpty)
        do { try await client.unloadSortformer(model); XCTFail("Undrained model unloaded") } catch {}
        do { _ = try await stream.feed(samples16k: [0]); XCTFail("Terminal actor reopened") } catch {}
        do { try await stream.finish(); XCTFail("Terminal actor finished") } catch {}
        peer.closeFailure = nil
        peer.blockClose = true
        let first = Task { try await stream.close() }
        let second = Task { try await stream.close() }
        await stream.requestClose()
        try await wait { peer.closeCount == 2 }
        peer.releaseClose()
        try await first.value
        try await second.value
        try await stream.close()
        XCTAssertEqual(peer.closeCount, 2)
        XCTAssertTrue(client.sortformerStreams.isEmpty)
        try await client.unloadSortformer(model)
    }

    @MainActor
    func testRemotePreAdmissionRejectionsReleaseOnlyProvisionalBinding() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        let healthy = try await client.startSortformerStream(model: model, settings: settings())
        let streamID = UUID()
        for code in [OmniXPCFailure.Code.invalidRequest, .busy] {
            peer.startFailure = OmniXPCFailure.error(code, "Controlled pre-admission rejection")
            for _ in 0..<17 {
                do { _ = try await client.startSortformerStream(model: model, settings: settings(), streamID: streamID); XCTFail("Rejected start succeeded") }
                catch { XCTAssertEqual((error as NSError).code, code.rawValue) }
            }
        }
        XCTAssertEqual(client.sortformerStreams.count, 1)
        XCTAssertTrue(client.closedSortformerStreams.isEmpty)
        XCTAssertEqual(peer.cancelCount, 0)
        XCTAssertEqual(peer.closeCount, 0)
        peer.startFailure = nil
        _ = try await client.pushSortformerAudio(Data(repeating: 0, count: 4), to: healthy, sequence: 1)
        let retry = try await client.startSortformerStream(model: model, settings: settings(), streamID: streamID)
        try await client.closeSortformerStream(retry)
        try await client.closeSortformerStream(healthy)
    }

    @MainActor
    func testAmbiguousStartAndCleanupFailuresRetainBinding() async throws {
        for failure in [NSError(domain: "foreign", code: OmniXPCFailure.Code.busy.rawValue),
                        OmniXPCFailure.error(.nativeFailure, "Controlled creation failure")] {
            let (client, model, peer) = try await makeSortformerOwnershipFixture()
            peer.startFailure = failure
            peer.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
            let streamID = UUID()
            do { _ = try await client.startSortformerStream(model: model, settings: settings(), streamID: streamID); XCTFail("Ambiguous start succeeded") }
            catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
            XCTAssertEqual(client.sortformerStreams.count, 1)
            XCTAssertEqual(peer.closeCount, 1)
            peer.closeFailure = nil
            try await client.closeSortformerStream(OmniXPCSortformerStreamReference(streamID: streamID, model: model))
        }
    }

    @MainActor
    func testCancelledStartLateReplyStillAwaitsClose() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        peer.blockStart = true
        peer.blockClose = true
        var returned = false
        let opening = Task {
            defer { returned = true }
            return try await OmniXPCDiarizationStream.open(client: client, model: model, settings: settings())
        }
        try await wait { peer.startCount == 1 }
        opening.cancel()
        try await wait { peer.closeCount == 1 }
        peer.releaseStart()
        XCTAssertFalse(returned)
        peer.releaseClose()
        do { _ = try await opening.value; XCTFail("Cancelled start succeeded") } catch is CancellationError {}
        XCTAssertTrue(client.sortformerStreams.isEmpty)
    }

    @MainActor
    func testDeadlineAndMalformedReplyNeverReplayOrInvalidateHealthyConnection() async throws {
        for timedOut in [false, true] {
            let (client, model, peer) = try await makeSortformerOwnershipFixture()
            peer.blockPush = timedOut
            peer.corruptIdentity = !timedOut
            let reference = try await client.startSortformerStream(model: model, settings: settings())
            do {
                _ = try await client.pushSortformerAudio(Data(repeating: 0, count: 4), to: reference, sequence: 1, timeout: .milliseconds(10))
                XCTFail("Invalid exchange succeeded")
            } catch { XCTAssertEqual((error as NSError).code, (timedOut ? OmniXPCFailure.Code.timedOut : .incompatibleService).rawValue) }
            XCTAssertEqual(peer.pushCount, 1)
            XCTAssertEqual(peer.closeCount, 1)
            XCTAssertEqual(client.connectionIdentifier, model.connectionID)
            XCTAssertEqual(peer.otherCancelCount, 0)
        }
    }

    @MainActor
    func testBoundedLiveAndRetiredBindingsRejectForgedAndStaleReferences() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        var references: [OmniXPCSortformerStreamReference] = []
        for _ in 0..<16 { references.append(try await client.startSortformerStream(model: model, settings: settings())) }
        do { _ = try await client.startSortformerStream(model: model, settings: settings()); XCTFail("Unbounded live streams") } catch {}
        let forgedModel = OmniXPCSortformerModelReference(modelID: model.modelID, serviceInstanceID: UUID(), connectionID: model.connectionID)
        let forged = OmniXPCSortformerStreamReference(streamID: references[0].streamID, model: forgedModel)
        do { try await client.closeSortformerStream(forged); XCTFail("Forged reference accepted") } catch {}
        XCTAssertEqual(peer.startCount, 16)
        XCTAssertEqual(peer.closeCount, 0)
        for reference in references { try await client.finishSortformerStream(reference); try await client.closeSortformerStream(reference) }
        for _ in 0..<257 {
            let reference = try await client.startSortformerStream(model: model, settings: settings())
            try await client.finishSortformerStream(reference)
            try await client.finishSortformerStream(reference)
        }
        XCTAssertEqual(client.closedSortformerStreams.count, 256)
        XCTAssertEqual(peer.closeCount, 0)
        client.invalidate()
        XCTAssertTrue(client.closedSortformerStreams.isEmpty)
        do { try await client.closeSortformerStream(references[0]); XCTFail("Stale connection accepted") } catch {}
    }

    @MainActor
    func testMalformedLoadReplyDrainsOnlyItsOriginatingOperation() async throws {
        let (client, model, peer) = try await makeSortformerOwnershipFixture()
        try await client.unloadSortformer(model)
        let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
        let directory = container.appendingPathComponent("Models/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        peer.corruptLoadIdentity = true
        do {
            _ = try await client.loadSortformer(modelDirectory: directory)
            XCTFail("Malformed load success was accepted")
        } catch {
            XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue)
        }
        XCTAssertEqual(peer.drainedLoadOperationID, peer.loadOperationID)
        XCTAssertEqual(peer.loadDrainCount, 1)
        XCTAssertEqual(peer.cancelCount, 0)
        XCTAssertEqual(peer.otherCancelCount, 0)
        XCTAssertEqual(client.connectionIdentifier, model.connectionID)
        peer.corruptLoadIdentity = false
        let recovered = try await client.loadSortformer(modelDirectory: directory)
        XCTAssertEqual(recovered.connectionID, model.connectionID)
        try await client.unloadSortformer(recovered)
        client.invalidate()
    }

    private func settings() throws -> OmniXPCSortformerSettings {
        try OmniXPCSortformerSettings(threshold: 0.4, minimumDurationSeconds: 0.2, mergeGapSeconds: 0.1,
                                      speakerCacheMaximumFrameCount: 188, fifoMaximumFrameCount: 40)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SortformerOwnershipFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum SortformerOwnershipFailure: Error { case operation, deadline }
private actor SortformerOwnershipGate {
    private var released = false
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { isWaiting = true; continuation = $0 } } }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

#endif
