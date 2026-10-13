#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerStreamingSessionTests: XCTestCase {
    @MainActor
    func testFinishWaitsForOriginalModelBarrierAndPreservesAllSegmentMetadata() async throws {
        for kind in OmniXPCSpeakerKind.allCases {
            let fixture = try OmniXPCSpeakerFixture(kind: kind)
            defer { fixture.dispose() }
            fixture.peer.removesAcknowledgedEvents = true
            fixture.peer.completionText = "final 世界"
            let segment = try OmniXPCBatchSegment(startSeconds: 0.123456789, endSeconds: 1.234567891, text: "世界",
                speaker: "", language: "zh", emotion: "", event: "speech")
            fixture.peer.completionSegments = [segment]
            try await fixture.owner.prepare()
            let stream = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .defaults(for: kind))
            let session: any ASRStreamingSession = stream
            session.feedAudio(samples: [0.25, -0.5])
            session.stop()
            try await speakerWait { fixture.peer.drainOperations.count == 1 }
            XCTAssertEqual(fixture.peer.commitCount, 1)
            XCTAssertEqual(fixture.peer.finishCount, 1)
            let probe = try await fixture.blockedProbe()
            try fixture.assertReader(pinned: true)
            let captured = StreamingEventCapture()
            let consumer = Task { try await stream.consumeEvents { captured.events.append($0); return true } }
            await Task.yield()
            XCTAssertTrue(captured.events.isEmpty, "Native completed was published before checked model retirement")
            fixture.peer.completeControlledWork()
            _ = try await consumer.value
            try await probe.value
            XCTAssertEqual(captured.events, [.ended(ASRTranscriptionResult(text: "final 世界", segments: [
                ASRTranscriptSegment(text: segment.text, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds,
                    speakerID: "", language: "zh", emotion: "", event: "speech")
            ]))])
            XCTAssertTrue(fixture.owner.isClosed)
            try fixture.assertReader(pinned: false)
        }
    }

    @MainActor
    func testStopSplitsOnlyTransportChunksWithoutReplayAndKeepsFloatBitPatterns() async throws {
        let fixture = try OmniXPCSpeakerFixture(kind: .nemotron)
        defer { fixture.dispose() }
        fixture.peer.removesAcknowledgedEvents = true
        fixture.peer.completionText = ""
        try await fixture.owner.prepare()
        let stream = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .nemotron())
        let samples = (0..<32001).map { Float($0 % 13) / 16 }
        stream.feedAudio(samples: samples)
        stream.stop()
        try await speakerWait { fixture.peer.drainOperations.count == 1 }
        XCTAssertEqual(fixture.peer.audioSequences, [1, 2])
        XCTAssertEqual(fixture.peer.audioChunks.map(\.count), [32000 * 4, 4])
        let actual = fixture.peer.audioChunks.reduce(into: Data()) { $0.append($1) }
        let expected = samples.flatMap { [Float($0).bitPattern.littleEndian].withUnsafeBytes { Array($0) } }
        XCTAssertEqual(actual, Data(expected))
        fixture.peer.completeControlledWork()
        try await stream.waitUntilClosed()
        XCTAssertEqual(fixture.peer.audioSequences.count, 2)
        XCTAssertEqual(fixture.peer.finishCount, 1)
    }

    @MainActor
    func testFailedCloseRetainsOriginalReaderAndLaneAndCoalescesExplicitRetry() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        fixture.peer.removesAcknowledgedEvents = true
        try await fixture.owner.prepare()
        let stream = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .moss())
        stream.feedAudio(samples: [0.25])
        try await speakerWait { fixture.peer.audioSequences.count == 1 }
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled checked retirement failure")
        stream.cancel()
        await speakerFailure { try await stream.waitUntilClosed() }
        try fixture.assertReader(pinned: true)
        let probe = try await fixture.blockedProbe()
        XCTAssertTrue(fixture.owner.hasPendingCleanup)
        fixture.peer.drainFailure = nil
        let first = Task { try await stream.closeAndWait() }
        let second = Task { try await stream.closeAndWait() }
        try await speakerWait { fixture.peer.drainOperations.count >= 2 }
        first.cancel(); second.cancel()
        fixture.peer.completeControlledWork()
        try await first.value
        try await second.value
        try await probe.value
        XCTAssertEqual(Set(fixture.peer.drainOperations), Set(fixture.peer.loadOperations))
        XCTAssertEqual(fixture.peer.acknowledgedDrains, 1)
        try fixture.assertReader(pinned: false)
    }

    @MainActor
    func testEarlyBreakConsumerClosesOriginalScopeWithoutCallingFinish() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        fixture.peer.removesAcknowledgedEvents = true
        try await fixture.owner.prepare()
        let stream = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .moss())
        fixture.peer.events = [try OmniXPCSpeakerEvent(session: fixture.peer.session!, eventSequence: 1,
            kind: .segment, segmentID: 0, text: "partial", isFinal: false)]
        fixture.peer.holdDrain = true
        let captured = StreamingEventCapture()
        let consumer = Task { try await stream.consumeEvents { captured.events.append($0); return false } }
        try await speakerWait { fixture.peer.drainOperations.count == 1 }
        XCTAssertEqual(captured.events, [.displayUpdate(confirmedText: "", provisionalText: "partial")])
        XCTAssertEqual(fixture.peer.finishCount, 0)
        try fixture.assertReader(pinned: true)
        fixture.peer.holdDrain = false
        fixture.peer.releaseBarriers()
        _ = try await consumer.value
        XCTAssertTrue(fixture.owner.isClosed)
    }

    @MainActor
    func testCompletedBeforeStopFailsAndStillAwaitsCheckedRetirement() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        let stream = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .moss())
        fixture.peer.events = [try OmniXPCSpeakerEvent(session: fixture.peer.session!, eventSequence: 1,
            kind: .completed, text: "unsolicited", segments: [])]
        fixture.peer.holdDrain = true
        try await speakerWait { fixture.peer.drainOperations.count == 1 }
        try fixture.assertReader(pinned: true)
        fixture.peer.holdDrain = false
        fixture.peer.releaseBarriers()
        await speakerFailure { try await stream.waitUntilClosed() }
        var events: [ASRStreamingEvent] = []
        for await event in stream.events { events.append(event) }
        XCTAssertEqual(events.count, 1)
        guard case .failed = events.first else { return XCTFail("Unsolicited completion was accepted") }
        XCTAssertTrue(fixture.owner.isClosed)
    }

    @MainActor
    func testOverflowRejectsWholeInputAndDoesNotInventCompletedText() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        let stream = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .moss())
        stream.feedAudio(samples: Array(repeating: 0, count: 480001))
        await speakerFailure { try await stream.waitUntilClosed() }
        XCTAssertTrue(fixture.peer.audioChunks.isEmpty)
        var events: [ASRStreamingEvent] = []
        for await event in stream.events { events.append(event) }
        XCTAssertEqual(events.count, 1)
        guard case .failed(let failure) = events.first else { return XCTFail("Oversize input was silently accepted") }
        XCTAssertTrue(failure.message.contains("30 seconds"))
        XCTAssertTrue(fixture.owner.isClosed)
    }

    @MainActor
    func testInvalidDeadlinesRejectBeforeSessionAdmission() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        await speakerFailure {
            _ = try await OmniXPCSpeakerStreamingSession.open(owner: fixture.owner, settings: .moss(), requestTimeout: .zero)
        }
        XCTAssertTrue(fixture.peer.startSessions.isEmpty)
        try fixture.assertReader(pinned: true)
        try await fixture.owner.close()
    }

    @MainActor
    func testExternalOwnerRetryReleasesAbandonedAdapterOnlyAfterCheckedRetirement() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        try await fixture.owner.prepare()
        var stream: OmniXPCSpeakerStreamingSession? = try await .open(owner: fixture.owner, settings: .moss())
        weak let retained = stream
        fixture.peer.drainFailure = OmniXPCFailure.error(.nativeFailure, "Controlled unknown cleanup")
        stream?.cancel()
        await speakerFailure { try await stream?.waitUntilClosed() }
        stream = nil
        XCTAssertNotNil(retained)
        try fixture.assertReader(pinned: true)
        fixture.peer.drainFailure = nil
        try await fixture.owner.close()
        XCTAssertTrue(fixture.owner.isClosed)
        try fixture.assertReader(pinned: false)
        try await speakerWait { retained == nil }
    }

    @MainActor
    func testFamilyPresentationMatchesExistingJoiningAndRejectsUnrepresentableSequence() throws {
        let model = try OmniXPCSpeakerModelReference(kind: .moss, modelID: UUID(), serviceInstanceID: UUID(),
            connectionID: UUID(), loadOperationID: UUID())
        let session = try OmniXPCSpeakerSessionReference(sessionID: UUID(), model: model)
        for joining in [OmniLiveTranscriptAssembler.Joining.lines, .scriptAware] {
            var presentation = OmniXPCStreamingPresentation(joining: joining)
            var assembler = OmniLiveTranscriptAssembler(joining: joining)
            for sequence in 1...3 {
                let text = [" hello ", "世界", "pending"][sequence - 1]
                let event = try OmniXPCSpeakerEvent(session: session, eventSequence: UInt64(sequence), kind: .segment,
                    segmentID: Int32(sequence), text: text, isFinal: sequence < 3, segments: sequence < 3 ? [] : nil)
                let expected = assembler.apply(eventIndex: sequence, segmentID: sequence, text: text, isFinal: sequence < 3)
                guard case .display(let confirmed, let provisional) = expected else { return XCTFail("Missing display") }
                XCTAssertEqual(try presentation.apply(event), .displayUpdate(confirmedText: confirmed, provisionalText: provisional))
            }
            let overflow = try OmniXPCSpeakerEvent(session: session, eventSequence: UInt64.max,
                kind: .segment, segmentID: 1, text: "x", isFinal: false)
            XCTAssertThrowsError(try presentation.apply(overflow))
        }
    }
}

@MainActor private final class StreamingEventCapture { var events: [ASRStreamingEvent] = [] }
#endif
