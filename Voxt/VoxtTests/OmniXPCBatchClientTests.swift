#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

@MainActor
final class OmniXPCBatchClientTests: XCTestCase {
    private let audio = [Float(0.25).bitPattern.littleEndian].withUnsafeBytes { Data($0) }

    private func fails(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected failure") } catch {}
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Fixture operation did not arrive")
    }

    func testSixFamilyFinalRoundTripAndExplicitUnload() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        for kind in OmniXPCBatchKind.allCases {
            let model = try await client.loadBatch(kind: kind, modelDirectory: directory)
            let settings = OmniXPCBatchSettings.defaults(for: kind)
            let result = try await client.transcribeBatch(model, audio: audio, settings: settings)
            XCTAssertEqual(result.kind, kind)
            XCTAssertEqual(result.text, "fixture")
            XCTAssertEqual(peer.lastSettings, settings)
            XCTAssertEqual(peer.lastAudio, audio)
            XCTAssertEqual(model.loadOperationID.uuidString, peer.loadOperationID)
            try await client.unloadBatch(model)
            try await client.closeBatchModel(model)
        }
        XCTAssertEqual(peer.loadCount, 6)
        XCTAssertEqual(peer.unloadCount, 6)
        XCTAssertEqual(peer.drainCount, 0)
        XCTAssertEqual(peer.otherCallCount, 0)
    }

    func testRequestTimeoutRetainsOriginalScopeAndDoesNotReplay() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        let model = try await client.loadBatch(kind: .whisper, modelDirectory: directory)
        peer.blockRequest = true
        await fails { _ = try await client.transcribeBatch(model, audio: audio, settings: .whisper(), timeout: .milliseconds(20)) }
        XCTAssertEqual(peer.cancelCount, 1)
        XCTAssertEqual(peer.cancellationModelID, model.modelID.uuidString)
        XCTAssertNotNil(client.batchModel)
        await fails { _ = try await client.transcribeBatch(model, audio: audio, settings: .whisper()) }
        await fails { _ = try await client.loadBatch(kind: .whisper, modelDirectory: directory) }
        XCTAssertEqual(peer.requestCount, 1)
        XCTAssertEqual(peer.loadCount, 1)
        peer.drainFailure = OmniXPCBatchFailure.error(.busy)
        await fails { try await client.closeBatchModel(model) }
        XCTAssertNotNil(client.batchModel)
        XCTAssertEqual(peer.drainedOperationID, model.loadOperationID.uuidString)
        peer.drainFailure = nil
        try await client.closeBatchModel(model)
        XCTAssertNil(client.batchModel)
        XCTAssertEqual(client.closedBatchModels[model.modelID], model)
        XCTAssertEqual(peer.otherCallCount, 0)
    }

    func testFailedLoadRetainsTicketUntilOriginalDrainRetry() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        peer.corruptLoad = true
        peer.drainFailure = OmniXPCBatchFailure.error(.failed)
        let operation = UUID()
        await fails { _ = try await client.loadBatch(kind: .moss, modelDirectory: directory, operationID: operation) }
        XCTAssertEqual(client.pendingBatchLoad?.operationID, operation)
        XCTAssertEqual(peer.drainedOperationID, operation.uuidString)
        await fails { try await client.closePendingBatchLoad(requiredOperationID: UUID()) }
        XCTAssertEqual(peer.drainCount, 1)
        await fails { _ = try await client.loadBatch(kind: .moss, modelDirectory: directory) }
        peer.drainFailure = nil
        try await client.closePendingBatchLoad(requiredOperationID: operation)
        XCTAssertNil(client.pendingBatchLoad)
        XCTAssertEqual(peer.drainCount, 2)
        await fails { _ = try await client.loadBatch(kind: .moss, modelDirectory: directory, operationID: operation) }
    }

    func testDroppedLoadReplyUsesOriginalTicketAndNeverSubstitutesModel() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        let operation = UUID()
        peer.blockLoad = true
        peer.blockDrain = true
        await fails { _ = try await client.loadBatch(kind: .nemotron, modelDirectory: directory,
                                                    timeout: .milliseconds(15), cleanupTimeout: .milliseconds(15), operationID: operation) }
        XCTAssertEqual(peer.cancelledRequestID, operation.uuidString)
        XCTAssertNil(peer.cancellationModelID)
        XCTAssertEqual(client.pendingBatchLoad?.operationID, operation)
        peer.releaseLoad()
        XCTAssertNil(client.batchModel)
        peer.blockDrain = false
        try await client.closePendingBatchLoad(requiredOperationID: operation)
        XCTAssertNil(client.pendingBatchLoad)
        XCTAssertEqual(peer.loadCount, 1)
        XCTAssertEqual(peer.drainedOperationID, operation.uuidString)
    }

    func testCloseIsUncancelledCoalescedAndStaleTaskCannotRetireReplacement() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        let original = try await client.loadBatch(kind: .parakeet, modelDirectory: directory)
        peer.blockDrain = true
        let first = Task { try await client.closeBatchModel(original) }
        try await waitFor { peer.drainCount == 1 }
        let second = Task { try await client.closeBatchModel(original) }
        first.cancel()
        await Task.yield()
        XCTAssertEqual(peer.drainCount, 1)
        peer.releaseDrain()
        try await first.value
        try await second.value
        peer.blockDrain = false
        let replacement = try await client.loadBatch(kind: .sensevoice, modelDirectory: directory)
        try await client.closeBatchModel(original)
        XCTAssertEqual(client.batchModel?.reference, replacement)
        XCTAssertNil(client.batchModel?.closeTask)
        XCTAssertEqual(peer.drainCount, 1)
        try await client.closeBatchModel(replacement)
        XCTAssertEqual(peer.drainCount, 2)
    }

    func testTimedOutUnloadUsesLoadDrainNotFreshUnloadReplay() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        let model = try await client.loadBatch(kind: .cohere, modelDirectory: directory)
        peer.blockUnload = true
        await fails { try await client.unloadBatch(model, timeout: .milliseconds(20)) }
        XCTAssertNotNil(client.batchModel)
        await fails { try await client.unloadBatch(model) }
        try await client.closeBatchModel(model)
        peer.releaseUnload()
        XCTAssertEqual(peer.unloadCount, 1)
        XCTAssertEqual(peer.drainedOperationID, model.loadOperationID.uuidString)
        XCTAssertNil(client.batchModel)
    }

    func testDisconnectKeepsSuccessfulAndFailedOwnershipTickets() async throws {
        for failedLoad in [false, true] {
            let (client, directory, peer) = try makeBatchFixture()
            defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
            var transport: NSXPCConnection?
            NSXPCConnection.setup = { connection in transport = connection; connection.exportedObject = peer }
            if failedLoad {
                peer.corruptLoad = true
                peer.drainFailure = OmniXPCBatchFailure.error(.failed)
                await fails { _ = try await client.loadBatch(kind: .whisper, modelDirectory: directory) }
            } else {
                _ = try await client.loadBatch(kind: .whisper, modelDirectory: directory)
            }
            let model = client.batchModel?.reference
            let operation = client.pendingBatchLoad?.operationID
            transport?.invalidate()
            try await waitFor { client.connectionIdentifier == nil }
            await fails { _ = try await client.loadBatch(kind: .whisper, modelDirectory: directory) }
            if let model {
                await fails { try await client.closeBatchModel(model) }
                XCTAssertEqual(client.batchModel?.reference, model)
            } else {
                await fails { try await client.closePendingBatchLoad(requiredOperationID: operation) }
                XCTAssertEqual(client.pendingBatchLoad?.operationID, operation)
            }
            XCTAssertEqual(peer.loadCount, 1)
        }
    }

    func testExactReferenceIdentityAndWireResultValidation() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        let model = try await client.loadBatch(kind: .whisper, modelDirectory: directory)
        let forged = OmniXPCBatchModelReference(kind: model.kind, modelID: model.modelID,
            serviceInstanceID: model.serviceInstanceID, connectionID: model.connectionID, loadOperationID: UUID())
        await fails { try await client.closeBatchModel(forged) }
        await fails { try await client.closePendingBatchLoad(requiredOperationID: model.loadOperationID) }
        await fails { try await client.closePendingBatchLoad(requiredOperationID: UUID()) }
        XCTAssertEqual(peer.drainCount, 0)
        await fails { _ = try await client.transcribeBatch(model, audio: audio, settings: .moss()) }
        XCTAssertEqual(peer.requestCount, 0)
        peer.corruptResult = true
        await fails { _ = try await client.transcribeBatch(model, audio: audio, settings: .whisper()) }
        XCTAssertNotNil(client.batchModel)
        try await client.closeBatchModel(model)
        try await client.closePendingBatchLoad(requiredOperationID: model.loadOperationID)
        await fails { try await client.closePendingBatchLoad(requiredOperationID: UUID()) }
        await fails { try await client.closeBatchModel(forged) }
        XCTAssertEqual(peer.drainCount, 1)
    }

    func testPendingCloseTaskRetiresInsideCompletionAndCancellationDoesNotCancelBarrier() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        peer.corruptLoad = true
        peer.drainFailure = OmniXPCBatchFailure.error(.failed)
        await fails { _ = try await client.loadBatch(kind: .whisper, modelDirectory: directory) }
        peer.drainFailure = nil
        peer.blockDrain = true
        let first = Task { try await client.closePendingBatchLoad() }
        try await waitFor { peer.drainCount == 2 }
        let second = Task { try await client.closePendingBatchLoad() }
        first.cancel()
        await Task.yield()
        peer.releaseDrain()
        try await first.value
        try await second.value
        XCTAssertNil(client.pendingBatchLoad)
        XCTAssertEqual(peer.drainCount, 2)
        peer.corruptLoad = false
        let replacement = try await client.loadBatch(kind: .whisper, modelDirectory: directory)
        XCTAssertNil(client.batchModel?.closeTask)
        peer.blockDrain = false
        try await client.closeBatchModel(replacement)
    }

    func testStableHistoryIsBoundedAndNeverEvictsExactReferences() async throws {
        let (client, directory, peer) = try makeBatchFixture()
        defer { client.invalidate(); NSXPCConnection.setup = nil; try? FileManager.default.removeItem(at: directory) }
        var oldest: OmniXPCBatchModelReference?
        for _ in 0..<256 {
            let model = try await client.loadBatch(kind: .whisper, modelDirectory: directory)
            if oldest == nil { oldest = model }
            try await client.closeBatchModel(model)
        }
        XCTAssertEqual(client.closedBatchModels.count, 256)
        XCTAssertEqual(client.closedBatchLoadIDs.count, 256)
        try await client.closeBatchModel(oldest!)
        XCTAssertEqual(peer.drainCount, 256)
        await fails { _ = try await client.loadBatch(kind: .whisper, modelDirectory: directory) }
        XCTAssertEqual(peer.loadCount, 256)
    }
}
#endif
