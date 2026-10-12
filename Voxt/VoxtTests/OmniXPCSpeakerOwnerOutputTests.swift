#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerOwnerOutputTests: XCTestCase {
    @MainActor
    func testWholeTypedBatchPreservesDoubleMetadataAbsentPreviewAndEmptyFinal() async throws {
        let fixture = try OmniXPCSpeakerFixture(kind: .nemotron)
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .nemotron(language: "de", chunkMilliseconds: 80.5))
        let session = try XCTUnwrap(fixture.peer.session)
        let segment = try OmniXPCBatchSegment(startSeconds: 0.123456789012345, endSeconds: 1.98765432109876,
            text: "Hallo", speaker: "speaker_2", language: "de", emotion: "calm", event: "speech")
        let preview = try OmniXPCSpeakerEvent(session: session, eventSequence: 1,
            kind: .segment, segmentID: 0, text: "Hal", isFinal: false)
        let final = try OmniXPCSpeakerEvent(session: session, eventSequence: 2,
            kind: .segment, segmentID: 0, text: "Hallo", isFinal: true, segments: [segment])
        let completed = try OmniXPCSpeakerEvent(session: session, eventSequence: 3,
            kind: .completed, text: "Hallo", segments: [])
        fixture.peer.events = [preview, final, completed]
        let batch = try await fixture.owner.poll()
        XCTAssertEqual(batch.events, [preview, final, completed])
        XCTAssertEqual(batch.events[1].segments?.first?.startSeconds, segment.startSeconds)
        XCTAssertEqual(batch.events[1].segments?.first?.endSeconds, segment.endSeconds)
        XCTAssertEqual(fixture.peer.pollAcknowledgements, [0])
        fixture.peer.events = []
        let empty = try await fixture.owner.poll()
        XCTAssertFalse(empty.isDrained)
        XCTAssertEqual(fixture.peer.pollAcknowledgements, [0, 3])
        XCTAssertTrue(fixture.owner.hasSession)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: true)
        try await fixture.owner.closeSession()
        try fixture.assertReader(pinned: true)
        try await fixture.owner.close()
    }

    @MainActor
    func testMalformedPollWaitsForOriginalModelBarrierInsteadOfPublishingPartialBatch() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        fixture.peer.pollBytes = Data("{\"events\":[{}]}".utf8)
        var published = false
        let polling = Task { _ = try await fixture.owner.poll(); published = true }
        try await speakerWait { !fixture.peer.drainOperations.isEmpty }
        let probe = try await fixture.blockedProbe()
        XCTAssertTrue(fixture.peer.controlledWorkActive)
        XCTAssertFalse(published)
        XCTAssertEqual(fixture.peer.acknowledgedDrains, 0)
        try fixture.assertReader(pinned: true)
        fixture.peer.completeControlledWork()
        await speakerFailure { try await polling.value }
        try await probe.value
        XCTAssertEqual(fixture.peer.pollAcknowledgements, [0])
        XCTAssertEqual(fixture.peer.audioChunks.count, 1)
        XCTAssertEqual(fixture.peer.drainOperations, fixture.peer.loadOperations)
        try await fixture.owner.close()
    }

    @MainActor
    func testPollCancellationKeepsWorkerAndCacheAliveUntilCheckedDrain() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        _ = try await fixture.owner.push(audio: fixture.audio)
        fixture.peer.holdPollReply = true
        let polling = Task { try await fixture.owner.poll() }
        try await speakerWait { fixture.peer.pollAcknowledgements.count == 1 }
        polling.cancel()
        try await speakerWait { !fixture.peer.cancellations.isEmpty && !fixture.peer.drainOperations.isEmpty }
        XCTAssertEqual(fixture.peer.cancellations.last?.requestID, fixture.peer.session?.sessionID.uuidString)
        XCTAssertEqual(fixture.peer.cancellations.last?.modelID, fixture.peer.model?.modelID.uuidString)
        let probe = try await fixture.blockedProbe()
        fixture.peer.deliverPoll()
        XCTAssertFalse(fixture.probeRan)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        try fixture.assertReader(pinned: true)
        fixture.peer.completeControlledWork()
        await speakerFailure { _ = try await polling.value }
        try await probe.value
        try await fixture.owner.close()
    }

    @MainActor
    func testTotalThirtySecondLimitRejectsOverflowWithoutAutomaticChunkingOrReplay() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        try await fixture.owner.startSession(settings: .moss())
        let chunk = Data(repeating: 0, count: 32_000 * 4)
        for sequence: UInt64 in 1...15 {
            let acknowledgement = try await fixture.owner.push(audio: chunk)
            XCTAssertEqual(acknowledgement.audioSequence, sequence)
        }
        await speakerFailure { _ = try await fixture.owner.push(audio: fixture.audio) }
        XCTAssertEqual(fixture.peer.audioSequences, Array(UInt64(1)...UInt64(15)))
        XCTAssertEqual(fixture.peer.audioChunks.reduce(0) { $0 + $1.count / 4 }, 480_000)
        XCTAssertEqual(fixture.hooks.beginCount, 2)
        XCTAssertEqual(fixture.hooks.restoreCount, 1)
        fixture.peer.completeControlledWork()
        try await fixture.owner.close()
    }
}
#endif
