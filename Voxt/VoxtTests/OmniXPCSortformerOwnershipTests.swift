#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSortformerOwnershipTests: XCTestCase {
    @MainActor
    func testStructuredReturnAndThrowAwaitBarrier() async throws {
        for shouldThrow in [false, true] {
            let (client, model, peer) = try await fixture()
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
        let (client, model, peer) = try await fixture()
        let gate = SortformerOwnershipGate()
        var returned = false
        let operation = Task {
            defer { returned = true }
            try await client.withSortformerDiarizationStream(model: model, settings: settings()) { _ in await gate.wait() }
        }
        try await wait { peer.startCount == 1 }
        operation.cancel()
        try await wait { client.sortformerStreams.isEmpty }
        XCTAssertFalse(returned)
        XCTAssertEqual(peer.closeCount, 1)
        await gate.open()
        do { try await operation.value; XCTFail("Cancelled scope succeeded") } catch is CancellationError {}
    }

    @MainActor
    func testRawActorPreservesWholeDTOSettingsAndFinishHasNoTail() async throws {
        let (client, model, peer) = try await fixture()
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
        let (client, model, peer) = try await fixture()
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
        let (client, model, peer) = try await fixture()
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
        let (client, model, peer) = try await fixture()
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
            let (client, model, peer) = try await fixture()
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
        let (client, model, peer) = try await fixture()
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
            let (client, model, peer) = try await fixture()
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
        let (client, model, peer) = try await fixture()
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
    func testMalformedLoadReplyCancelsOnlyItsOriginatingOperation() async throws {
        let (client, model, peer) = try await fixture()
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
        XCTAssertEqual(peer.cancelledLoadOperationID, peer.loadOperationID)
        XCTAssertEqual(peer.cancelCount, 1)
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
    private func fixture() async throws -> (OmniXPCClient, OmniXPCSortformerModelReference, SortformerOwnershipPeer) {
        let peer = SortformerOwnershipPeer()
        NSXPCConnection.setup = { $0.exportedObject = peer }
        defer { NSXPCConnection.setup = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let properties = ["CFBundleIdentifier": "test.host", "OmniAppGroupIdentifier": "group.test.host",
                          "OmniInferenceServiceIdentifier": "test.service", "OmniHostBundleIdentifier": "test.host", "OmniTeamIdentifier": "TESTTEAM01"]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        let client = try OmniXPCClient(bundle: XCTUnwrap(Bundle(url: directory)))
        let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
        let modelDirectory = container.appendingPathComponent("Models/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelDirectory) }
        let model = try await client.loadSortformer(modelDirectory: modelDirectory)
        return (client, model, peer)
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
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

private nonisolated final class SortformerOwnershipPeer: OmniInferenceXPCProtocol {
    let modelID = UUID()
    let serviceInstanceID = UUID()
    var startCount = 0, pushCount = 0, finishCount = 0, cancelCount = 0, closeCount = 0, otherCancelCount = 0
    var blockStart = false, blockPush = false, blockClose = false, corruptIdentity = false
    var corruptLoadIdentity = false
    var loadOperationID: String?
    var cancelledLoadOperationID: String?
    var startFailure: NSError?
    var closeFailure: NSError?
    var settings: OmniXPCSortformerSettings?
    var lastBatch: OmniXPCSortformerProbabilityBatch?
    private var processedFrames: [String: UInt64] = [:]
    private var startReply: (@Sendable (String?, NSError?) -> Void)?
    private var startingID: String?
    private var closeReply: (@Sendable (NSError?) -> Void)?
    private var closingID: String?
    func releaseStart() { startReply?(startingID, startFailure); startReply = nil }
    func releaseClose() {
        if closeFailure == nil, let closingID { processedFrames.removeValue(forKey: closingID) }
        closeReply?(closeFailure); closeReply = nil
    }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        loadOperationID = operationID
        reply(modelID.uuidString, corruptLoadIdentity ? nil : serviceInstanceID.uuidString, nil)
    }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        reply(processedFrames.isEmpty ? nil : OmniXPCFailure.error(.busy, "Undrained controlled streams"))
    }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) {
        startCount += 1
        self.settings = try! OmniXPCSortformerSettings.decode(settings)
        if let startFailure, startFailure.domain == "Voxt.Omni.XPC",
           [OmniXPCFailure.Code.invalidRequest.rawValue, OmniXPCFailure.Code.busy.rawValue].contains(startFailure.code) {
            reply(nil, startFailure); return
        }
        processedFrames[streamID] = 0
        if blockStart { startReply = reply; startingID = streamID } else { reply(streamID, startFailure) }
    }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        pushCount += 1
        if blockPush { return }
        let frameCount = (1 + audio.count / 4 / 160 + 7) / 8
        let previousFrameCount = processedFrames[streamID]!
        let processedFrameCount = previousFrameCount + UInt64(frameCount)
        processedFrames[streamID] = processedFrameCount
        let durationSeconds = OmniXPCSortformerLimits.frameDurationSeconds
        let startSeconds = Float(previousFrameCount) * Float(durationSeconds)
        let segment = try! OmniXPCSortformerSegment(startSeconds: Double(startSeconds),
            endSeconds: Double(startSeconds + Float(frameCount) * Float(durationSeconds)), speakerIndex: 3)
        let batch = try! OmniXPCSortformerProbabilityBatch(serviceInstanceID: corruptIdentity ? UUID() : serviceInstanceID,
            modelID: self.modelID, streamID: UUID(uuidString: streamID)!, audioSequence: sequence, processedFrameCount: processedFrameCount,
            frameCount: frameCount, speakerCount: 4, frameDurationSeconds: durationSeconds,
            probabilities: (0..<frameCount).flatMap { _ in [Float(0.1), 0.2, 0.3, 0.4] }, segments: [segment])
        lastBatch = batch
        reply(try! batch.encoded(), nil)
    }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        finishCount += 1; processedFrames.removeValue(forKey: streamID); reply(nil)
    }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        cancelCount += 1
        if modelID == nil { cancelledLoadOperationID = requestID }
        reply(nil)
    }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        closeCount += 1; closingID = streamID; closeReply = reply
        if !blockClose { releaseClose() }
    }
    private var unused: NSError { OmniXPCFailure.error(.invalidRequest, "Unused controlled-peer RPC") }
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { reply(0, "", 0, unused) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCancelCount += 1; reply(unused) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { reply(nil, nil, nil, nil, 0, false, unused) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { otherCancelCount += 1; reply(unused) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
}
#endif
