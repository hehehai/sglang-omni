#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCASRVoiceActivityConsumerTests: XCTestCase {
    @MainActor
    func testRequiresExplicitPreparedOwnerWithoutLoading() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: MeetingLocalInferenceCoordinator())
        XCTAssertThrowsError(try OmniXPCASRVoiceActivityConsumer(owner: owner))
        XCTAssertEqual(peer.loadCount, 0)
        _ = try await owner.prepare()
        let consumer = try OmniXPCASRVoiceActivityConsumer(owner: owner)
        XCTAssertEqual(peer.loadCount, 1)
        try await consumer.close()
        XCTAssertThrowsError(try OmniXPCASRVoiceActivityConsumer(owner: owner))
    }

    @MainActor
    func testExactFloat32SplittingAndIndependentStreamSequences() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: MeetingLocalInferenceCoordinator())
        _ = try await owner.prepare()
        let consumer = try OmniXPCASRVoiceActivityConsumer(owner: owner)
        let first = try await consumer.openStream()
        let second = try await consumer.openStream()
        let initial = try await consumer.probability(samples16k: [Float(bitPattern: 0x80000000)], to: first)
        XCTAssertNil(initial)
        let samples = (0..<64_001).map { Float(bitPattern: UInt32(0x3e000000 + $0)) }
        let firstProbability = try await consumer.probability(samples16k: samples, to: first)
        XCTAssertEqual(firstProbability, SileroOwnerTestPeer.probability(frameIndex: 124))
        let firstMessages = peer.receivedAudio.filter { $0.streamID == first.streamID.uuidString }
        XCTAssertEqual(firstMessages.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(firstMessages.map { $0.bytes.count / 4 }, [1, 32_000, 32_000, 1])
        let expectedSamples = [Float(bitPattern: 0x80000000)] + samples
        let receivedBytes = firstMessages.reduce(into: Data()) { $0.append($1.bytes) }
        let expectedBytes = expectedSamples.reduce(into: Data()) { bytes, sample in
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        XCTAssertEqual(receivedBytes, expectedBytes)
        let secondInitial = try await consumer.probability(samples16k: [0], to: second)
        XCTAssertNil(secondInitial)
        let secondProbability = try await consumer.probability(samples16k: Array(repeating: 0, count: 511), to: second)
        XCTAssertEqual(secondProbability, 1.0 / 16)
        let secondMessages = peer.receivedAudio.filter { $0.streamID == second.streamID.uuidString }
        XCTAssertEqual(secondMessages.map(\.sequence), [1, 2])
        let secondLast = try await consumer.probability(samples16k: [0], to: second)
        XCTAssertNil(secondLast)
        let firstLast = try await consumer.probability(samples16k: [0], to: first)
        XCTAssertNil(firstLast)
        let firstFinal = try await consumer.finishStream(first)
        XCTAssertEqual(firstFinal, SileroOwnerTestPeer.probability(frameIndex: 125))
        let secondFinal = try await consumer.finishStream(second)
        XCTAssertEqual(secondFinal, 2.0 / 16)
        try await consumer.close()
    }

    @MainActor
    func testLiveStreamHasNoThirtySecondSessionTotalLimit() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: MeetingLocalInferenceCoordinator())
        _ = try await owner.prepare()
        let consumer = try OmniXPCASRVoiceActivityConsumer(owner: owner)
        let stream = try await consumer.openStream()
        let probability = try await consumer.probability(samples16k: Array(repeating: 0, count: 480_001), to: stream)
        XCTAssertEqual(probability, SileroOwnerTestPeer.probability(frameIndex: 936))
        XCTAssertEqual(peer.receivedAudio.map(\.sequence), Array(1...16))
        XCTAssertEqual(peer.receivedAudio.reduce(0) { $0 + $1.bytes.count / 4 }, 480_001)
        let final = try await consumer.finishStream(stream)
        XCTAssertEqual(final, SileroOwnerTestPeer.probability(frameIndex: 937))
        try await consumer.close()
    }

    @MainActor
    func testCloseInterruptsPendingProbabilityAndCoalescesUncancelledOwnerDrain() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = MeetingLocalInferenceCoordinator()
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: coordinator)
        _ = try await owner.prepare()
        let consumer = try OmniXPCASRVoiceActivityConsumer(owner: owner)
        let stream = try await consumer.openStream()
        peer.blockPush = true
        peer.blockDrain = true
        let feeding = Task { try await consumer.probability(samples16k: Array(repeating: 0, count: 512), to: stream) }
        try await awaitSileroCondition { peer.pushCount == 1 }
        var closedCount = 0
        let first = Task { try await consumer.close(); closedCount += 1 }
        let second = Task { try await consumer.close(); closedCount += 1 }
        first.cancel()
        try await awaitSileroCondition { peer.drainedOperationIDs.count == 1 }
        try assertSileroReaderBusy(directory)
        try await assertSileroLaneBlocked(coordinator)
        XCTAssertEqual(closedCount, 0)
        peer.releasePush()
        peer.releaseDrain()
        do { _ = try await feeding.value; XCTFail("Abandoned probability succeeded") } catch is CancellationError {}
        try await first.value
        try await second.value
        XCTAssertEqual(closedCount, 2)
        XCTAssertEqual(peer.drainedOperationIDs.count, 1)
        do { _ = try await consumer.openStream(); XCTFail("Closed consumer reopened") } catch {}
    }

    @MainActor
    func testRejectsNonfiniteInputBeforeAnyChunkAndOfflineOverThirtySecondsWithoutSplitting() async throws {
        let (client, peer, directory) = try makeSileroOwnerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = OmniXPCSileroModelOwner(client: client, modelDirectory: directory, coordinator: MeetingLocalInferenceCoordinator())
        _ = try await owner.prepare()
        let consumer = try OmniXPCASRVoiceActivityConsumer(owner: owner)
        let stream = try await consumer.openStream()
        let nonfinite = Array(repeating: Float(0), count: 32_000) + [.infinity]
        do { _ = try await consumer.probability(samples16k: nonfinite, to: stream); XCTFail("Nonfinite input partly submitted") }
        catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(peer.pushCount, 0)
        do {
            _ = try await consumer.speechTimestamps(samples16k: Array(repeating: 0, count: 480_001), settings: sileroOwnerSettings)
            XCTFail("Overlong offline input was split or admitted")
        } catch { XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.invalidRequest.rawValue) }
        XCTAssertEqual(peer.offlineCount, 0)
        let ranges = try await consumer.speechTimestamps(samples16k: Array(repeating: 0, count: 480_000), settings: sileroOwnerSettings)
        XCTAssertEqual(ranges, [0..<480_000])
        XCTAssertEqual(peer.offlineCount, 1)
        try await consumer.closeStream(stream)
        try await consumer.close()
    }
}
#endif
