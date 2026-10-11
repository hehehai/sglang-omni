#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSileroOwnershipTests: XCTestCase {
    @MainActor
    func testStructuredReturnAndThrowAwaitClose() async throws {
        for shouldThrow in [false, true] {
            let (client, model, service) = try await fixture()
            service.blockClose = true
            var returned = false
            let operation = Task {
                defer { returned = true }
                return try await client.withSileroVoiceActivityStream(model: model) { stream in
                    let probability = try await stream.probability(samples16k: Array(repeating: 0, count: 512))
                    XCTAssertEqual(probability, 0.25)
                    if shouldThrow { throw OwnershipTestFailure.operation }
                    return 7
                }
            }
            try await wait { service.closeCount == 1 }
            XCTAssertFalse(returned)
            XCTAssertEqual(service.cancelCount, 1)
            service.releaseClose()
            if shouldThrow {
                do { _ = try await operation.value; XCTFail("Operation error must survive successful cleanup") }
                catch OwnershipTestFailure.operation {}
            } else {
                let value = try await operation.value
                XCTAssertEqual(value, 7)
            }
            XCTAssertTrue(client.sileroStreams.isEmpty)
        }
    }

    @MainActor
    func testStructuredCancellationClosesWhileOperationIsSuspendedElsewhere() async throws {
        let (client, model, service) = try await fixture()
        service.blockClose = true
        let gate = OwnershipTestGate()
        let operation = Task {
            try await client.withSileroVoiceActivityStream(model: model) { _ in
                await gate.wait()
            }
        }
        try await wait { service.startCount == 1 }
        operation.cancel()
        try await wait { service.closeCount == 1 }
        XCTAssertEqual(service.cancelCount, 1)
        service.releaseClose()
        try await wait { client.sileroStreams.isEmpty }
        await gate.open()
        do { try await operation.value; XCTFail("Cancelled operation cannot succeed") }
        catch is CancellationError {}
        XCTAssertEqual(service.closeCount, 1)
    }

    @MainActor
    func testRawActorFinishPadsTailAndExplicitCloseIsRequiredOnEarlyReturn() async throws {
        let (client, model, service) = try await fixture()
        let stream = try await OmniXPCVoiceActivityStream.open(client: client, model: model)
        let partial = try await stream.probability(samples16k: [0])
        XCTAssertNil(partial)
        XCTAssertEqual(service.closeCount, 0)
        XCTAssertEqual(client.sileroStreams.count, 1)
        let final = try await stream.finish()
        XCTAssertEqual(final, 0.25)
        try await stream.close()
        XCTAssertEqual(service.finishCount, 1)
        XCTAssertEqual(service.closeCount, 0, "Successful finish is already a native barrier")
        XCTAssertTrue(client.sileroStreams.isEmpty)
    }

    @MainActor
    func testOverlapRejectedAndCloseInterruptsThenAwaitsInFlight() async throws {
        let (client, model, service) = try await fixture()
        service.blockPush = true
        service.blockClose = true
        let stream = try await OmniXPCVoiceActivityStream.open(client: client, model: model)
        let feeding = Task { try await stream.probability(samples16k: Array(repeating: 0, count: 512)) }
        try await wait { service.pushCount == 1 }
        do { _ = try await stream.probability(samples16k: [.nan]); XCTFail("Overlap must fail") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        var closed = false
        let closing = Task { try await stream.close(); closed = true }
        try await wait { service.closeCount == 1 }
        XCTAssertFalse(closed)
        service.releaseClose()
        try await closing.value
        do { _ = try await feeding.value; XCTFail("Abandoned feed cannot succeed") } catch {}
        XCTAssertEqual(service.pushCount, 1)
        XCTAssertTrue(client.sileroStreams.isEmpty)
    }

    @MainActor
    func testStartCancellationAndLateSuccessStillAwaitBarrier() async throws {
        let (client, model, service) = try await fixture()
        service.blockStart = true
        service.blockClose = true
        var returned = false
        let opening = Task {
            defer { returned = true }
            return try await OmniXPCVoiceActivityStream.open(client: client, model: model)
        }
        try await wait { service.startCount == 1 }
        opening.cancel()
        try await wait { service.closeCount == 1 }
        service.releaseStart()
        XCTAssertFalse(returned)
        service.releaseClose()
        do { _ = try await opening.value; XCTFail("Cancelled factory cannot return a raw lease") }
        catch is CancellationError {}
        XCTAssertTrue(client.sileroStreams.isEmpty)
    }

    @MainActor
    func testDeadlineAndMalformedReplyDoNotReplayOrInvalidateConnection() async throws {
        for timedOut in [false, true] {
            let (client, model, service) = try await fixture()
            service.blockPush = timedOut
            service.corruptIdentity = !timedOut
            let reference = try await client.startSileroStream(model: model)
            do {
                _ = try await client.pushSileroAudio(Data(repeating: 0, count: 2048), to: reference, sequence: 1, timeout: .milliseconds(10))
                XCTFail("Invalid or expired reply cannot succeed")
            } catch {
                XCTAssertEqual((error as NSError).code, (timedOut ? OmniXPCFailure.Code.timedOut : .incompatibleService).rawValue)
            }
            XCTAssertEqual(service.pushCount, 1)
            XCTAssertEqual(service.closeCount, 1)
            XCTAssertEqual(client.connectionIdentifier, model.connectionID)
            XCTAssertTrue(client.sileroStreams.isEmpty)
        }
    }

    @MainActor
    func testBarrierFailureIsSurfacedAndRetainsBinding() async throws {
        let (client, model, service) = try await fixture()
        service.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        do {
            try await client.withSileroVoiceActivityStream(model: model) { _ in throw OwnershipTestFailure.operation }
            XCTFail("Failed barrier cannot succeed")
        } catch {
            XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue)
        }
        XCTAssertEqual(client.sileroStreams.count, 1)
        let reference = try XCTUnwrap(client.sileroStreams.values.first?.reference)
        service.closeFailure = nil
        try await client.closeSileroStream(reference)
        XCTAssertTrue(client.sileroStreams.isEmpty)
    }

    @MainActor
    func testSixteenBindingsAndForgedReferencesRejectLocally() async throws {
        let (client, model, service) = try await fixture()
        var references: [OmniXPCSileroStreamReference] = []
        for _ in 0..<16 { references.append(try await client.startSileroStream(model: model)) }
        do { _ = try await client.startSileroStream(model: model); XCTFail("Unbounded streams") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        let forgedModel = OmniXPCSileroModelReference(modelID: model.modelID, serviceInstanceID: UUID(), connectionID: model.connectionID)
        let forged = OmniXPCSileroStreamReference(streamID: references[0].streamID, model: forgedModel)
        do { try await client.closeSileroStream(forged); XCTFail("Forged model accepted") } catch {}
        XCTAssertEqual(service.cancelCount, 0)
        XCTAssertEqual(service.startCount, 16)
        for reference in references { try await client.closeSileroStream(reference) }
    }

    @MainActor
    func testRejectedUnloadedAndStaleStartsDoNotExhaustClientSlots() async throws {
        let (client, unloadedModel, service) = try await fixture()
        try await client.unloadSilero(unloadedModel)
        for _ in 0..<16 {
            do { _ = try await client.startSileroStream(model: unloadedModel); XCTFail("Unloaded model accepted") }
            catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        }
        let replacement = try await client.loadSilero(modelDirectory: "Models/replacement")
        XCTAssertNotEqual(replacement.modelID, unloadedModel.modelID)
        let healthy = try await client.startSileroStream(model: replacement)
        for _ in 0..<16 {
            do { _ = try await client.startSileroStream(model: unloadedModel); XCTFail("Stale model accepted") }
            catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        }
        let batch = try await client.pushSileroAudio(Data(repeating: 0, count: 2048), to: healthy, sequence: 1)
        XCTAssertEqual(batch.probabilities, [0.25])
        XCTAssertEqual(service.startCount, 33)
        XCTAssertEqual(service.cancelCount, 0)
        XCTAssertEqual(service.closeCount, 0)
        XCTAssertEqual(client.connectionIdentifier, unloadedModel.connectionID)
        try await client.closeSileroStream(healthy)
        try await client.unloadSilero(replacement)
    }

    @MainActor
    func testRemoteBusyStartRejectionDoesNotRequireClose() async throws {
        let (client, model, service) = try await fixture()
        service.startFailure = OmniXPCFailure.error(.busy, "Controlled admission rejection")
        let streamID = UUID()
        for _ in 0..<16 {
            do { _ = try await client.startSileroStream(model: model, streamID: streamID); XCTFail("Busy start accepted") }
            catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        }
        XCTAssertEqual(service.startCount, 16)
        XCTAssertEqual(service.closeCount, 0)
        XCTAssertEqual(service.cancelCount, 0)
        service.startFailure = nil
        let reference = try await client.startSileroStream(model: model, streamID: streamID)
        try await client.closeSileroStream(reference)
        XCTAssertEqual(client.connectionIdentifier, model.connectionID)
    }

    @MainActor
    func testAmbiguousStartFailuresRetainOwnershipUntilSuccessfulClose() async throws {
        let failures: [NSError?] = [
            NSError(domain: "test.foreign", code: OmniXPCFailure.Code.invalidRequest.rawValue),
            NSError(domain: "test.foreign", code: OmniXPCFailure.Code.busy.rawValue),
            OmniXPCFailure.error(.nativeFailure, "Controlled creation failure"),
            OmniXPCFailure.error(.cancelled, "Controlled remote cancellation"),
            nil
        ]
        for failure in failures {
            let (client, model, service) = try await fixture()
            service.startFailure = failure
            service.blockStart = failure == nil
            service.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
            let streamID = UUID()
            do {
                _ = try await client.startSileroStream(model: model, streamID: streamID, timeout: .milliseconds(10))
                XCTFail("Failed creation cannot succeed")
            } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
            XCTAssertEqual(service.closeCount, 1)
            XCTAssertEqual(client.sileroStreams.count, 1)
            XCTAssertEqual(client.connectionIdentifier, model.connectionID)
            do { try await client.unloadSilero(model); XCTFail("Failed drain did not free ownership") }
            catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
            service.closeFailure = nil
            try await client.closeSileroStream(OmniXPCSileroStreamReference(streamID: streamID, model: model))
            XCTAssertTrue(client.sileroStreams.isEmpty)
            try await client.unloadSilero(model)
        }
    }

    @MainActor
    func testCancelledStartWithFailedCloseRetainsBinding() async throws {
        let (client, model, service) = try await fixture()
        service.blockStart = true
        service.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        let streamID = UUID()
        let opening = Task { try await client.startSileroStream(model: model, streamID: streamID) }
        try await wait { service.startCount == 1 }
        opening.cancel()
        do { _ = try await opening.value; XCTFail("Failed barrier cannot succeed") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(client.sileroStreams.count, 1)
        service.releaseStart()
        service.closeFailure = nil
        try await client.closeSileroStream(OmniXPCSileroStreamReference(streamID: streamID, model: model))
        try await client.unloadSilero(model)
    }

    @MainActor
    func testActorRetriesFailedCloseWhileTerminalAndCoalescesActualBarrier() async throws {
        let (client, model, service) = try await fixture()
        let stream = try await OmniXPCVoiceActivityStream.open(client: client, model: model)
        service.closeFailure = OmniXPCFailure.error(.nativeFailure, "Controlled drain failure")
        do { try await stream.close(); XCTFail("Failed barrier cannot succeed") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.nativeFailure.rawValue) }
        XCTAssertEqual(service.closeCount, 1)
        XCTAssertEqual(client.sileroStreams.count, 1)
        do { try await client.unloadSilero(model); XCTFail("Failed drain must keep unload busy") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue) }
        do { _ = try await stream.probability(samples16k: [0]); XCTFail("Failed close reopened actor") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        do { _ = try await stream.finish(); XCTFail("Failed close reopened actor") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        service.closeFailure = nil
        service.blockClose = true
        var completedCloseCount = 0
        let first = Task { try await stream.close(); completedCloseCount += 1 }
        let second = Task { try await stream.close(); completedCloseCount += 1 }
        await stream.requestClose()
        try await wait { service.closeCount == 2 }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(completedCloseCount, 0)
        XCTAssertEqual(service.closeCount, 2)
        XCTAssertEqual(client.sileroStreams.count, 1)
        service.releaseClose()
        try await first.value
        try await second.value
        try await stream.close()
        XCTAssertEqual(service.closeCount, 2)
        XCTAssertTrue(client.sileroStreams.isEmpty)
        try await client.unloadSilero(model)
    }

    @MainActor
    func testCloseFirstAfterBothClientStreamsFinishIsIdempotent() async throws {
        let (client, model, service) = try await fixture()
        let first = try await client.startSileroStream(model: model)
        let second = try await client.startSileroStream(model: model)
        _ = try await client.finishSileroStream(first)
        _ = try await client.finishSileroStream(second)
        try await client.closeSileroStream(first)
        try await client.closeSileroStream(second)
        try await client.unloadSilero(model)
        let replacement = try await client.loadSilero(modelDirectory: "Models/replacement")
        let healthy = try await client.startSileroStream(model: replacement)
        try await client.closeSileroStream(first)
        let forged = OmniXPCSileroStreamReference(streamID: first.streamID, model: replacement)
        do { try await client.closeSileroStream(forged); XCTFail("Forged retired reference accepted") } catch {}
        let batch = try await client.pushSileroAudio(Data(repeating: 0, count: 2048), to: healthy, sequence: 1)
        XCTAssertEqual(batch.probabilities, [0.25])
        XCTAssertEqual(service.closeCount, 0)
        XCTAssertEqual(client.connectionIdentifier, model.connectionID)
        try await client.closeSileroStream(healthy)
        try await client.unloadSilero(replacement)
    }

    @MainActor
    private func fixture() async throws -> (OmniXPCClient, OmniXPCSileroModelReference, OwnershipTestService) {
        let service = OwnershipTestService()
        NSXPCConnection.setup = { $0.exportedObject = service }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let properties = ["CFBundleIdentifier": "test.host", "OmniAppGroupIdentifier": "group.test.host",
                          "OmniInferenceServiceIdentifier": "test.service", "OmniHostBundleIdentifier": "test.host",
                          "OmniTeamIdentifier": "TESTTEAM01"]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let client = try OmniXPCClient(bundle: XCTUnwrap(Bundle(url: directory)))
        let model = try await client.loadSilero(modelDirectory: "Models/silero")
        return (client, model, service)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OwnershipTestFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum OwnershipTestFailure: Error { case operation, deadline }

private actor OwnershipTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

private nonisolated final class OwnershipTestService: OmniInferenceXPCProtocol {
    var modelID = UUID()
    let serviceInstanceID = UUID()
    private var isModelLoaded = false
    var startCount = 0
    var pushCount = 0
    var finishCount = 0
    var cancelCount = 0
    var closeCount = 0
    var blockStart = false
    var blockPush = false
    var blockClose = false
    var corruptIdentity = false
    var closeFailure: NSError?
    var startFailure: NSError?
    private var receivedSamples: [String: UInt64] = [:]
    private var sequences: [String: Int] = [:]
    private var startReply: (@Sendable (String?, NSError?) -> Void)?
    private var startingID: String?
    private var closeReply: (@Sendable (NSError?) -> Void)?
    private var closingID: String?

    func releaseStart() { startReply?(startingID, startFailure); startReply = nil }
    func releaseClose() {
        if closeFailure == nil, let closingID {
            receivedSamples.removeValue(forKey: closingID)
            sequences.removeValue(forKey: closingID)
        }
        closeReply?(closeFailure)
        closeReply = nil
    }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        if !isModelLoaded { modelID = UUID(); isModelLoaded = true }
        reply(modelID.uuidString, serviceInstanceID.uuidString, nil)
    }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        guard isModelLoaded, modelID == self.modelID.uuidString else { reply(unused); return }
        guard receivedSamples.isEmpty else { reply(OmniXPCFailure.error(.busy, "Undrained test streams")); return }
        isModelLoaded = false
        reply(nil)
    }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) {
        startCount += 1
        guard isModelLoaded, modelID == self.modelID.uuidString else { reply(nil, unused); return }
        if let startFailure, startFailure.domain == "Voxt.Omni.XPC",
           [OmniXPCFailure.Code.invalidRequest.rawValue, OmniXPCFailure.Code.busy.rawValue].contains(startFailure.code) {
            reply(nil, startFailure)
            return
        }
        receivedSamples[streamID] = 0
        sequences[streamID] = 0
        if blockStart { startReply = reply; startingID = streamID } else { reply(streamID, startFailure) }
    }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        pushCount += 1
        if blockPush { return }
        let previous = receivedSamples[streamID]!
        let received = previous + UInt64(audio.count / 4)
        receivedSamples[streamID] = received
        sequences[streamID] = sequence
        let batch = OmniXPCSileroProbabilityBatch(serviceInstanceID: corruptIdentity ? UUID() : serviceInstanceID,
            modelID: self.modelID, streamID: UUID(uuidString: streamID)!, audioSequence: sequence,
            processedSampleCount: received / 512 * 512,
            probabilities: Array(repeating: 0.25, count: Int(received / 512 - previous / 512)), isFinal: false)
        reply(try! batch.encoded(), nil)
    }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        finishCount += 1
        let received = receivedSamples[streamID]!
        let batch = OmniXPCSileroProbabilityBatch(serviceInstanceID: serviceInstanceID, modelID: self.modelID,
            streamID: UUID(uuidString: streamID)!, audioSequence: sequences[streamID]!, processedSampleCount: (received + 511) / 512 * 512,
            probabilities: received % 512 == 0 ? [] : [0.25], isFinal: true)
        receivedSamples.removeValue(forKey: streamID)
        sequences.removeValue(forKey: streamID)
        reply(try! batch.encoded(), nil)
    }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        cancelCount += 1; reply(nil)
    }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        closeCount += 1
        guard isModelLoaded, modelID == self.modelID.uuidString else { reply(unused); return }
        closingID = streamID
        closeReply = reply
        if !blockClose { releaseClose() }
    }

    nonisolated private var unused: NSError { OmniXPCFailure.error(.invalidRequest, "Unused portable test RPC") }
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { reply(0, "", 0, unused) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { reply(nil, nil, unused) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { reply(nil, nil, nil, nil, 0, false, unused) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { reply(nil, unused) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { reply(0, unused) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { reply(nil, unused) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { reply(unused) }
}
#endif
