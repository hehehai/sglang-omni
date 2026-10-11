import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCStreamingSessionTests: XCTestCase {
    func testStopDrainsEverySampleBeforeOneFinish() throws {
        let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        defer { buffer.cancel(); withExtendedLifetime(events) {} }
        let sampleCount = OmniXPCProtocolLimits.sampleRate * 3
        let samples = (0..<sampleCount).map { Float($0) / Float(sampleCount) }
        buffer.feedAudio(samples: Array(samples.prefix(100)))
        buffer.feedAudio(samples: Array(samples.dropFirst(100)))
        buffer.stop()
        buffer.stop()
        buffer.feedAudio(samples: [99])
        var received: [Float] = []
        for _ in 0..<2 {
            guard case .audio(let audio) = buffer.nextInput() else { return XCTFail("Audio must precede Finish") }
            XCTAssertLessThanOrEqual(audio.count, OmniXPCProtocolLimits.maximumChunkAudioByteCount)
            received += try OmniXPCRequestValidation.samples(audio: audio, language: nil, context: nil, maximumTokenCount: 1)
        }
        XCTAssertEqual(received, samples)
        XCTAssertEqual(buffer.nextInput(), .finish)
        XCTAssertEqual(buffer.nextInput(), .idle)
    }

    func testPendingAudioOverflowFailsOnceAndDropsInput() async throws {
        let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        let cleanup = OmniXPCStreamingTestGate()
        let worker = Task<Void, Error> {
            defer { buffer.releaseWorker() }
            await cleanup.wait()
            XCTAssertTrue(Task.isCancelled)
            buffer.complete(nil)
        }
        let session = OmniXPCStreamingSession(events: events, buffer: buffer, worker: worker)
        session.feedAudio(samples: [Float](repeating: 0, count: OmniXPCStreamingBuffer.maximumPendingSampleCount))
        session.feedAudio(samples: [0])
        session.feedAudio(samples: [.nan])
        session.stop()
        session.cancel()
        XCTAssertEqual(buffer.nextInput(), .closed)
        let terminalPublished = expectation(description: "No terminal before owner cleanup")
        let streamFinished = expectation(description: "No stream finish before owner cleanup")
        terminalPublished.isInverted = true
        streamFinished.isInverted = true
        let consuming = Task {
            var received: [ASRStreamingEvent] = []
            for await event in events {
                received.append(event)
                terminalPublished.fulfill()
            }
            streamFinished.fulfill()
            return received
        }
        await fulfillment(of: [terminalPublished, streamFinished], timeout: 0.05)
        await cleanup.open()
        try await session.waitUntilClosed()
        buffer.complete(.ended(ASRTranscriptionResult(text: "late")))
        let received = await consuming.value
        XCTAssertEqual(received.count, 1)
        guard case .failed(let failure) = received.first else { return XCTFail("Overflow cannot succeed") }
        XCTAssertTrue(failure.message.contains("four-second budget"))
    }

    func testThirtySecondTotalCapSurvivesQueueDraining() async {
        let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        let samples = [Float](repeating: 0, count: OmniXPCProtocolLimits.sampleRate * 2)
        for _ in 0..<(OmniXPCProtocolLimits.maximumAudioSeconds / 2) {
            buffer.feedAudio(samples: samples)
            guard case .audio = buffer.nextInput() else { return XCTFail("Thirty seconds must be admitted") }
        }
        let display = ASRStreamingEvent.displayUpdate(confirmedText: "", provisionalText: "before shutdown")
        buffer.display(display)
        buffer.feedAudio(samples: [0])
        XCTAssertEqual(buffer.nextInput(), .closed)
        var iterator = events.makeAsyncIterator()
        let beforeCleanup = await iterator.next()
        XCTAssertEqual(beforeCleanup, display)
        buffer.complete(nil)
        let event = await iterator.next()
        guard case .failed(let failure) = event else { return XCTFail("The validation cap must fail") }
        XCTAssertTrue(failure.message.contains("30 seconds"))
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testNonFiniteAudioFailsWithoutAdmission() async throws {
        for sample in [Float.nan, Float.infinity, -Float.infinity] {
            let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
            let display = ASRStreamingEvent.displayUpdate(confirmedText: "", provisionalText: "before shutdown")
            buffer.display(display)
            buffer.feedAudio(samples: [sample])
            buffer.cancel()
            XCTAssertEqual(buffer.nextInput(), .closed)
            var iterator = events.makeAsyncIterator()
            let beforeCleanup = await iterator.next()
            XCTAssertEqual(beforeCleanup, display)
            let cleanup = OmniXPCStreamingTestGate()
            let worker = Task<Void, Error> {
                defer { buffer.releaseWorker() }
                await cleanup.wait()
                XCTAssertTrue(Task.isCancelled, "Shutdown must cancel a worker installed later")
                buffer.complete(.failed(ASRStreamingFailure(message: CancellationError().localizedDescription)))
            }
            let session = OmniXPCStreamingSession(events: events, buffer: buffer, worker: worker)
            await cleanup.open()
            try await session.waitUntilClosed()
            buffer.complete(.failed(ASRStreamingFailure(message: "late failure")))
            let event = await iterator.next()
            guard case .failed(let failure) = event else { return XCTFail("Nonfinite audio must fail") }
            XCTAssertEqual(failure.message, "Realtime XPC audio must contain finite Float32 samples.")
            let end = await iterator.next()
            XCTAssertNil(end)
        }
    }

    func testStalledConsumerKeepsOnlyLatestDisplayAndOneTerminal() async {
        let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        for sequence in 0..<10_000 {
            buffer.display(.displayUpdate(confirmedText: "", provisionalText: String(sequence)))
        }
        var iterator = events.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest, .displayUpdate(confirmedText: "", provisionalText: "9999"))
        let result = ASRTranscriptionResult(text: "done")
        buffer.complete(.ended(result))
        buffer.display(.displayUpdate(confirmedText: "late", provisionalText: ""))
        buffer.complete(.failed(ASRStreamingFailure(message: "late")))
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .ended(result))
        XCTAssertNil(end)
        XCTAssertNil(result.language)
        XCTAssertEqual(result.languageProvenance, .unknown)
        XCTAssertNil(result.generationMetadata)
    }

    func testTerminalReplacesBufferedDisplay() async {
        let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
        buffer.display(.displayUpdate(confirmedText: "", provisionalText: "draft"))
        buffer.complete(.ended(ASRTranscriptionResult(text: "final")))
        var received: [ASRStreamingEvent] = []
        for await event in events { received.append(event) }
        XCTAssertEqual(received, [.ended(ASRTranscriptionResult(text: "final"))])
    }

    func testCancelFinishesWithoutInventingAResult() async throws {
        for cancelBeforeInstall in [true, false] {
            let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
            let cleanup = OmniXPCStreamingTestGate()
            let worker = Task<Void, Error> {
                defer { buffer.releaseWorker() }
                await cleanup.wait()
                XCTAssertTrue(Task.isCancelled)
                buffer.complete(.ended(ASRTranscriptionResult(text: "late")))
            }
            buffer.feedAudio(samples: [0, 1])
            if cancelBeforeInstall { buffer.cancel() }
            let session = OmniXPCStreamingSession(events: events, buffer: buffer, worker: worker)
            session.cancel()
            session.cancel()
            XCTAssertEqual(buffer.nextInput(), .closed)
            for await _ in events { XCTFail("Cancelled input cannot publish a result") }
            let closed = expectation(description: "Stream finish is not owner completion")
            closed.isInverted = true
            let waiting = Task {
                try await session.waitUntilClosed()
                closed.fulfill()
            }
            await fulfillment(of: [closed], timeout: 0.05)
            await cleanup.open()
            try await waiting.value
        }
    }

    func testConsumerCancellationClosesInput() async throws {
        nonisolated enum Exit: CaseIterable, Sendable { case earlyReturn, failure, cancellation, rawBreak, cleanupFailure }
        let consumerFailure = ASRStreamingFailure(message: "consumer failed")
        let cleanupFailure = ASRStreamingFailure(message: "cleanup failed")
        for exit in Exit.allCases {
            let (events, buffer) = OmniXPCStreamingBuffer.makeStream()
            let cleanup = OmniXPCStreamingTestGate()
            let entered = OmniXPCStreamingTestGate()
            let consumerRelease = OmniXPCStreamingTestGate()
            let shutdown = expectation(description: "Consumer exit cancels the owner")
            let worker = Task<Void, Error> {
                defer { buffer.releaseWorker() }
                await withTaskCancellationHandler {
                    await cleanup.wait()
                } onCancel: {
                    shutdown.fulfill()
                }
                if exit == .cleanupFailure { throw cleanupFailure }
                buffer.complete(nil)
            }
            let session = OmniXPCStreamingSession(events: events, buffer: buffer, worker: worker)
            let display = ASRStreamingEvent.displayUpdate(confirmedText: "", provisionalText: "draft")
            buffer.display(display)
            let disposed = expectation(description: "Consumer disposal waits for owner cleanup")
            disposed.isInverted = true
            let consuming = Task {
                defer { disposed.fulfill() }
                if exit == .rawBreak {
                    for await _ in session.events { break }
                    XCTAssertEqual(buffer.nextInput(), .idle, "A retained stream cannot observe break")
                    try await session.closeAndWait()
                } else {
                    let lastEvent = try await session.consumeEvents { _ in
                        await entered.open()
                        if exit == .failure { throw consumerFailure }
                        if exit == .cancellation { await consumerRelease.wait() }
                        return exit == .cancellation
                    }
                    XCTAssertEqual(lastEvent, display)
                }
            }
            if exit == .cancellation {
                await entered.wait()
                consuming.cancel()
            }
            await fulfillment(of: [shutdown], timeout: 1)
            XCTAssertEqual(buffer.nextInput(), .closed)
            await consumerRelease.open()
            await fulfillment(of: [disposed], timeout: 0.05)
            await cleanup.open()
            switch await consuming.result {
            case .success:
                XCTAssertTrue(exit == .earlyReturn || exit == .rawBreak)
            case .failure(let error):
                switch exit {
                case .failure: XCTAssertEqual(error as? ASRStreamingFailure, consumerFailure)
                case .cancellation: XCTAssertTrue(error is CancellationError)
                case .cleanupFailure: XCTAssertEqual(error as? ASRStreamingFailure, cleanupFailure)
                case .earlyReturn, .rawBreak: XCTFail("Unexpected disposal failure: \(error)")
                }
            }
            withExtendedLifetime(session.events) {}
        }
    }

    func testPartialReplacementAndConfirmedJoiningUseExistingAssembler() throws {
        var presentation = OmniXPCStreamingPresentation()
        XCTAssertEqual(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 1, kind: .segment, segmentID: 0, text: "old", isFinal: false
        )), .displayUpdate(confirmedText: "", provisionalText: "old"))
        XCTAssertEqual(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 2, kind: .segment, segmentID: 0, text: "Hello", isFinal: false
        )), .displayUpdate(confirmedText: "", provisionalText: "Hello"))
        XCTAssertEqual(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 3, kind: .segment, segmentID: 0, text: "Hello", isFinal: true
        )), .displayUpdate(confirmedText: "Hello", provisionalText: ""))
        XCTAssertEqual(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 4, kind: .segment, segmentID: 1, text: "world", isFinal: true
        )), .displayUpdate(confirmedText: "Hello world", provisionalText: ""))
        XCTAssertEqual(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 5, kind: .segment, segmentID: 2, text: "你好", isFinal: true
        )), .displayUpdate(confirmedText: "Hello world你好", provisionalText: ""))
    }

    func testTranscriptSegmentCountIsBounded() throws {
        var presentation = OmniXPCStreamingPresentation()
        for segmentID in 0..<OmniXPCStreamingPresentation.maximumSegmentCount {
            _ = try presentation.apply(OmniXPCRealtimeEvent(
                sequence: segmentID + 1, kind: .segment, segmentID: segmentID, text: "", isFinal: true
            ))
        }
        XCTAssertThrowsError(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: OmniXPCStreamingPresentation.maximumSegmentCount + 1, kind: .segment,
            segmentID: OmniXPCStreamingPresentation.maximumSegmentCount, text: "", isFinal: true
        )))
    }

    func testIgnoredPartialCannotHideRetainedFinalBytes() throws {
        var presentation = OmniXPCStreamingPresentation()
        let text = String(repeating: "a", count: OmniXPCProtocolLimits.maximumRealtimeEventStringByteCount)
        for segmentID in 0..<4 {
            _ = try presentation.apply(OmniXPCRealtimeEvent(
                sequence: segmentID + 1, kind: .segment, segmentID: segmentID, text: text, isFinal: true
            ))
        }
        for segmentID in 0..<4 {
            XCTAssertNil(try presentation.apply(OmniXPCRealtimeEvent(
                sequence: segmentID + 5, kind: .segment, segmentID: segmentID, text: "", isFinal: false
            )))
        }
        XCTAssertThrowsError(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 9, kind: .segment, segmentID: 4, text: "a", isFinal: true
        )))
    }

    func testTranscriptBytesAreBoundedButReplacementDoesNotAccumulate() throws {
        var presentation = OmniXPCStreamingPresentation()
        let text = String(repeating: "a", count: OmniXPCProtocolLimits.maximumRealtimeEventStringByteCount)
        for sequence in 1...10 {
            _ = try presentation.apply(OmniXPCRealtimeEvent(
                sequence: sequence, kind: .segment, segmentID: 0, text: text, isFinal: false
            ))
        }
        for segmentID in 1..<4 {
            _ = try presentation.apply(OmniXPCRealtimeEvent(
                sequence: segmentID + 10, kind: .segment, segmentID: segmentID, text: text, isFinal: true
            ))
        }
        XCTAssertThrowsError(try presentation.apply(OmniXPCRealtimeEvent(
            sequence: 14, kind: .segment, segmentID: 4, text: "a", isFinal: true
        )))
    }
}

private actor OmniXPCStreamingTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
