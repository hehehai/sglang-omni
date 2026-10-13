#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

@MainActor
final class BatchOwnerFixture {
    static var unprovenOwners: [BatchOwnerFixture] = []
    let client: OmniXPCClient
    let directory: URL
    let peer: BatchOwnerPeer
    let hooks = BatchOwnerCacheHooks()
    let coordinator: MeetingLocalInferenceCoordinator
    let owner: OmniXPCBatchModelOwner
    var probeRan = false
    let audio = [Float(0.25).bitPattern.littleEndian].withUnsafeBytes { Data($0) }

    init(kind: OmniXPCBatchKind = .whisper, workClass: MeetingLocalInferenceWorkClass = .fileASR) throws {
        let (client, directory, base) = try makeBatchFixture()
        self.client = client
        self.directory = directory
        peer = BatchOwnerPeer(base: base)
        NSXPCConnection.setup = { [peer] in $0.exportedObject = peer }
        coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { [hooks] in hooks.begin() },
            readThermalState: { [hooks] in hooks.thermalState })
        owner = OmniXPCBatchModelOwner(client: client, kind: kind, modelDirectory: directory,
            coordinator: coordinator, workClass: workClass)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        let header = Data(#"{"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var weights = [UInt64(header.count).littleEndian].withUnsafeBytes { Data($0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 4))
        try weights.write(to: directory.appendingPathComponent("model.safetensors"))
    }

    func dispose() {
        NSXPCConnection.setup = nil
        if !owner.isClosed {
            XCTAssertTrue(owner.hasPendingCleanup, "An owner must be closed or explicitly quarantined with unproven cleanup")
            Self.unprovenOwners.append(self)
        } else {
            client.invalidate()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func assertReader(pinned: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            let writer = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
            XCTAssertFalse(pinned, "Reader must survive until scoped drain", file: file, line: line)
            withExtendedLifetime(writer) {}
        } catch OmniModelStorageError.busy {
            XCTAssertTrue(pinned, "Reader survived confirmed retirement", file: file, line: line)
        }
    }

    func blockedProbe() async throws -> Task<Void, Error> {
        let submitted = await coordinator.currentStatistics().submittedCount
        probeRan = false
        let probe = Task {
            try await self.coordinator.withPermit(.liveASRFinal) {
                await MainActor.run { self.probeRan = true }
            }
        }
        try await batchOwnerWait { await self.coordinator.currentStatistics().submittedCount == submitted + 1 }
        XCTAssertFalse(probeRan)
        return probe
    }

    func request(timeout: Duration = .seconds(5), cleanupTimeout: Duration = .seconds(5)) async throws -> OmniXPCBatchResult {
        try await owner.transcribe(audio: audio, settings: .defaults(for: owner.kind), timeout: timeout, cleanupTimeout: cleanupTimeout)
    }
}

nonisolated final class BatchOwnerCacheHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0, restores = 0
    private var restoreAction: (@Sendable () -> Void)?
    private var critical = false
    var beginCount: Int { lock.withLock { begins } }
    var restoreCount: Int { lock.withLock { restores } }
    var thermalState: ProcessInfo.ThermalState { lock.withLock { critical ? .critical : .nominal } }
    func constrainThermalState() { lock.withLock { critical = true } }
    func setRestoreAction(_ action: @escaping @Sendable () -> Void) { lock.withLock { restoreAction = action } }
    func begin() -> @Sendable () -> Void {
        lock.withLock { begins += 1 }
        return {
            let action = self.lock.withLock { self.restores += 1; return self.restoreAction }
            action?()
        }
    }
}

@MainActor
func batchOwnerWait(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw BatchOwnerWaitFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum BatchOwnerWaitFailure: Error { case deadline }

@MainActor
func batchOwnerFailure(code: OmniXPCFailure.Code? = nil, file: StaticString = #filePath, line: UInt = #line,
                       _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected owner operation to fail", file: file, line: line) }
    catch {
        if let code {
            XCTAssertEqual((error as NSError).domain, OmniXPCFailure.error(code, "").domain, file: file, line: line)
            XCTAssertEqual((error as NSError).code, code.rawValue, file: file, line: line)
        }
    }
}

nonisolated final class BatchOwnerPeer: OmniInferenceXPCProtocol {
    enum RequestOutcome { case success, nativeFailure, malformed, wrongIdentity }
    let base: OmniXPCBatchTestPeer
    var holdLoadWork = false, holdRequestWork = false, holdDrain = false
    var requestOutcome = RequestOutcome.success
    var drainFailure: NSError?
    private(set) var drainOperations: [String] = []
    private(set) var acknowledgedDrains = 0
    private(set) var nativeLoadActive = false, nativeRequestActive = false
    private var requestReply: (@Sendable (Data?, NSError?) -> Void)?
    private var requestID: UUID?
    private var drainReplies: [@Sendable (NSError?) -> Void] = []

    init(base: OmniXPCBatchTestPeer) { self.base = base }

    func loadBatch(operationID: String, kind: Int, modelDirectory: String,
                   withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        base.blockLoad = true
        nativeLoadActive = true
        base.loadBatch(operationID: operationID, kind: kind, modelDirectory: modelDirectory, withReply: reply)
        if !holdLoadWork { finishLoadWork() }
    }

    func finishLoadWork() {
        nativeLoadActive = false
        base.releaseLoad()
        releaseDrain()
    }

    func transcribeBatch(requestID: String, modelID: String, audio: Data, settings: Data,
                         withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        base.blockRequest = true
        base.transcribeBatch(requestID: requestID, modelID: modelID, audio: audio, settings: settings, withReply: reply)
        self.requestID = UUID(uuidString: requestID)
        requestReply = reply
        nativeRequestActive = true
        if !holdRequestWork { finishRequestWork() }
    }

    func finishRequestWork() {
        nativeRequestActive = false
        guard let reply = requestReply else { return }
        requestReply = nil
        switch requestOutcome {
        case .nativeFailure:
            reply(nil, OmniXPCFailure.error(.nativeFailure, "Controlled inference failure"))
        case .malformed:
            reply(Data("{}".utf8), nil)
        case .success, .wrongIdentity:
            let result = try! OmniXPCBatchResult(serviceInstanceID: base.serviceInstanceID, modelID: base.modelID,
                requestID: requestOutcome == .wrongIdentity ? UUID() : requestID!, kind: base.lastKind!, text: "fixture",
                language: "", generatedTokenCount: 1, finishReason: .stop, segments: [])
            reply(try! result.encoded(), nil)
        }
        releaseDrain()
    }

    func drainBatchLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        drainOperations.append(operationID)
        guard operationID == base.loadOperationID else {
            return reply(OmniXPCFailure.error(.invalidRequest, "Drain must target original operation"))
        }
        if let drainFailure { reply(drainFailure) }
        else { drainReplies.append(reply); releaseDrain() }
    }

    func releaseDrain() {
        // note (assistant): Cancellation acknowledgement is not synthetic native retirement; active work must exit first.
        guard !nativeLoadActive, !nativeRequestActive, !holdDrain else { return }
        let replies = drainReplies
        drainReplies.removeAll()
        acknowledgedDrains += replies.count
        for reply in replies { reply(nil) }
    }

    func cancelBatchRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        base.cancelBatchRequest(requestID: requestID, modelID: modelID, withReply: reply)
    }

    func unloadBatch(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        base.unloadBatch(operationID: operationID, modelID: modelID, withReply: reply)
    }
}

@MainActor
func verifyBatchOwnerArtifactRejections() async throws {
    for invalidArtifact in 0..<4 {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        var writer: OmniModelDirectoryLease?
        switch invalidArtifact {
        case 0: try Data("not JSON".utf8).write(to: fixture.directory.appendingPathComponent("config.json"))
        case 1: try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("model.safetensors"))
        case 2: try Data([0]).write(to: fixture.directory.appendingPathComponent("model.safetensors"))
        default: writer = try OmniModelDirectoryLease.acquire(for: fixture.directory, mode: .exclusiveMutation)
        }
        await batchOwnerFailure { try await fixture.owner.prepare() }
        withExtendedLifetime(writer) {}
        writer = nil
        try fixture.assertReader(pinned: false)
        XCTAssertEqual(fixture.peer.base.loadCount, 0)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try await fixture.owner.close()
    }
    let fixture = try BatchOwnerFixture()
    defer { fixture.dispose() }
    for directory in [FileManager.default.temporaryDirectory, URL(string: "https://example.invalid/model")!] {
        let owner = OmniXPCBatchModelOwner(client: fixture.client, kind: .whisper, modelDirectory: directory, coordinator: fixture.coordinator)
        await batchOwnerFailure { try await owner.prepare() }
        try await owner.close()
    }
    XCTAssertEqual(fixture.peer.base.loadCount, 0)
    XCTAssertTrue(fixture.peer.drainOperations.isEmpty)
    try await fixture.owner.close()
}

@MainActor
func verifyBatchOwnerRequestCancellation() async throws {
    for queued in [false, true] {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        let incumbent = queued ? try await fixture.coordinator.reserveOwnedPermit(.liveASRFinal) : nil
        fixture.peer.holdRequestWork = true
        let request = Task { try await fixture.request() }
        try await batchOwnerWait { await fixture.coordinator.currentStatistics().submittedCount == (queued ? 3 : 2) }
        if !queued { try await batchOwnerWait { fixture.peer.nativeRequestActive } }
        await batchOwnerFailure { try await fixture.owner.prepare() }
        await batchOwnerFailure { _ = try await fixture.request() }
        request.cancel()
        if !queued {
            try await batchOwnerWait { !fixture.peer.drainOperations.isEmpty }
            try fixture.assertReader(pinned: true)
            let probe = try await fixture.blockedProbe()
            XCTAssertEqual(fixture.hooks.restoreCount, 1)
            fixture.peer.finishRequestWork()
            await batchOwnerFailure { _ = try await request.value }
            try await probe.value
        } else {
            await batchOwnerFailure { _ = try await request.value }
            XCTAssertEqual(fixture.peer.base.requestCount, 0)
            let probe = try await fixture.blockedProbe()
            try await fixture.coordinator.completeOwnedPermit(incumbent!)
            try await probe.value
        }
        try await fixture.owner.close()
        try fixture.assertReader(pinned: false)
    }
}

@MainActor
func verifyBatchOwnerCloseDeadlineRetry() async throws {
    let fixture = try BatchOwnerFixture()
    defer { fixture.dispose() }
    try await fixture.owner.prepare()
    fixture.peer.holdDrain = true
    await batchOwnerFailure(code: .timedOut) { try await fixture.owner.close(timeout: .milliseconds(20)) }
    XCTAssertTrue(fixture.owner.hasPendingCleanup)
    try fixture.assertReader(pinned: true)
    let probe = try await fixture.blockedProbe()
    let submitted = await fixture.coordinator.currentStatistics().submittedCount
    let first = Task { try await fixture.owner.close() }
    try await batchOwnerWait { fixture.peer.drainOperations.count == 2 }
    let second = Task { try await fixture.owner.close() }
    first.cancel()
    second.cancel()
    fixture.peer.holdDrain = false
    fixture.peer.releaseDrain()
    try await first.value
    try await second.value
    try await probe.value
    let after = await fixture.coordinator.currentStatistics().submittedCount
    XCTAssertEqual(after, submitted)
    XCTAssertEqual(fixture.peer.drainOperations, Array(repeating: fixture.peer.base.loadOperationID!, count: 2))
    try fixture.assertReader(pinned: false)
}

@MainActor
func verifyBatchOwnerActiveDisconnect() async throws {
    for loading in [false, true] {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        if !loading { try await fixture.owner.prepare() }
        fixture.peer.holdLoadWork = loading
        fixture.peer.holdRequestWork = !loading
        let work = Task { if loading { try await fixture.owner.prepare() } else { _ = try await fixture.request() } }
        try await batchOwnerWait { fixture.peer.nativeLoadActive || fixture.peer.nativeRequestActive }
        fixture.client.invalidate()
        await batchOwnerFailure { try await work.value }
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        await batchOwnerFailure { try await fixture.owner.prepare() }
        await batchOwnerFailure { try await fixture.owner.close() }
        if loading { fixture.peer.finishLoadWork() } else { fixture.peer.finishRequestWork() }
        await batchOwnerFailure { try await fixture.owner.close() }
        XCTAssertEqual(fixture.peer.base.loadCount, 1)
        XCTAssertEqual(fixture.peer.acknowledgedDrains, 0)
        XCTAssertEqual(fixture.hooks.restoreCount, loading ? 0 : 1)
        XCTAssertFalse(fixture.probeRan)
        probe.cancel()
        await batchOwnerFailure { try await probe.value }
    }
}

@MainActor
func verifyBatchOwnerLateCallerCancellation() async throws {
    for transcribing in [false, true] {
        let fixture = try BatchOwnerFixture()
        defer { fixture.dispose() }
        if transcribing { try await fixture.owner.prepare() }
        let work = Task {
            if transcribing { _ = try await fixture.request() }
            else { try await fixture.owner.prepare() }
        }
        fixture.hooks.setRestoreAction { work.cancel() }
        await batchOwnerFailure { try await work.value }
        XCTAssertTrue(fixture.owner.isClosed)
        XCTAssertEqual(fixture.peer.drainOperations, [fixture.peer.base.loadOperationID!])
        XCTAssertEqual(fixture.hooks.restoreCount, transcribing ? 2 : 1)
        try fixture.assertReader(pinned: false)
    }
}

@MainActor
func verifyBatchOwnerBorrowedClientWork() async throws {
    let fixture = try BatchOwnerFixture()
    defer { fixture.dispose() }
    try await fixture.owner.prepare()
    let model = try XCTUnwrap(fixture.client.batchModel?.reference)
    fixture.peer.holdRequestWork = true
    let request = Task { try await fixture.client.transcribeBatch(model, audio: fixture.audio, settings: .whisper()) }
    try await batchOwnerWait { fixture.peer.nativeRequestActive }
    await batchOwnerFailure { try await fixture.owner.prepare() }
    fixture.peer.finishRequestWork()
    _ = try await request.value
    fixture.peer.holdDrain = true
    let closing = Task { try await fixture.client.closeBatchModel(model) }
    try await batchOwnerWait { !fixture.peer.drainOperations.isEmpty }
    await batchOwnerFailure { try await fixture.owner.prepare() }
    fixture.peer.holdDrain = false
    fixture.peer.releaseDrain()
    try await closing.value
    try await fixture.owner.close()
    XCTAssertEqual(fixture.hooks.beginCount, 1)
    XCTAssertEqual(fixture.peer.base.loadCount, 1)
}

nonisolated extension BatchOwnerPeer {
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) { base.probe(withReply: reply) }
    func loadQwen(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadQwen(operationID: operationID, modelDirectory: modelDirectory, withReply: reply) }
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadQwen(operationID: operationID, modelID: modelID, withReply: reply) }
    func loadSilero(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadSilero(operationID: operationID, modelDirectory: modelDirectory, withReply: reply) }
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadSilero(operationID: operationID, modelID: modelID, withReply: reply) }
    func drainSileroLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.drainSileroLoad(operationID: operationID, withReply: reply) }
    func sileroSpeechTimestamps(requestID: String, modelID: String, audio: Data, settings: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.sileroSpeechTimestamps(requestID: requestID, modelID: modelID, audio: audio, settings: settings, withReply: reply) }
    func startSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startSileroStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func pushSileroAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.pushSileroAudio(streamID: streamID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.finishSileroStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func closeSileroStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.closeSileroStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelSileroRequest(requestID: requestID, modelID: modelID, withReply: reply) }
    func loadSortformer(operationID: String, modelDirectory: String, withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) { base.loadSortformer(operationID: operationID, modelDirectory: modelDirectory, withReply: reply) }
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.unloadSortformer(operationID: operationID, modelID: modelID, withReply: reply) }
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.drainSortformerLoad(operationID: operationID, withReply: reply) }
    func startSortformerStream(streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startSortformerStream(streamID: streamID, modelID: modelID, settings: settings, withReply: reply) }
    func pushSortformerAudio(streamID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.pushSortformerAudio(streamID: streamID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.finishSortformerStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func closeSortformerStream(streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.closeSortformerStream(streamID: streamID, modelID: modelID, withReply: reply) }
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelSortformerRequest(requestID: requestID, modelID: modelID, withReply: reply) }
    func startFinalSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startFinalSession(sessionID: sessionID, modelID: modelID, language: language, context: context, maximumTokenCount: maximumTokenCount, withReply: reply) }
    func pushFinalAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { base.pushFinalAudio(sessionID: sessionID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishFinalSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void) { base.finishFinalSession(sessionID: sessionID, modelID: modelID, withReply: reply) }
    func startRealtimeSession(sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int, decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int, withReply reply: @escaping @Sendable (String?, NSError?) -> Void) { base.startRealtimeSession(sessionID: sessionID, modelID: modelID, language: language, context: context, maximumTokenCount: maximumTokenCount, decodeIntervalSamples: decodeIntervalSamples, firstDecodeSamples: firstDecodeSamples, maximumSegmentSamples: maximumSegmentSamples, withReply: reply) }
    func pushRealtimeAudio(sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void) { base.pushRealtimeAudio(sessionID: sessionID, modelID: modelID, sequence: sequence, audio: audio, withReply: reply) }
    func finishRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.finishRealtimeSession(sessionID: sessionID, modelID: modelID, withReply: reply) }
    func pollRealtimeEvents(sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) { base.pollRealtimeEvents(sessionID: sessionID, modelID: modelID, acknowledgedEventSequence: acknowledgedEventSequence, maximumEventCount: maximumEventCount, withReply: reply) }
    func closeRealtimeSession(sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.closeRealtimeSession(sessionID: sessionID, modelID: modelID, withReply: reply) }
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) { base.cancelRequest(requestID: requestID, modelID: modelID, withReply: reply) }
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) { base.terminateForValidation(withReply: reply) }
}
#endif
