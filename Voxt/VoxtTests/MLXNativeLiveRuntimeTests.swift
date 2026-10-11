import XCTest
import MLXAudioSTT
@testable import Voxt

@MainActor
final class MLXNativeLiveRuntimeTests: XCTestCase {
    func testCompatibilityResultPreservesSegmentMetadataAndLanguageProvenance() {
        let provenances: [STTLanguageProvenance] = [.detected, .requested, .outputTarget, .modelDefault, .unknown]
        for provenance in provenances {
            let raw = STTOutput(
                text: "hello",
                segments: [STTTranscriptSegment(
                    text: "hello", startTime: 1.25, endTime: 2.5, speakerID: "speaker-1",
                    language: "en", confidence: 0.9, emotion: "neutral", event: "speech"
                )],
                language: "en", languageProvenance: provenance, generationTokens: 32
            )
            let result = ASRTranscriptionResult(mlxOutput: raw)
            XCTAssertEqual(result.text, raw.text)
            XCTAssertEqual(result.language, "en")
            XCTAssertEqual(result.languageProvenance.rawValue, provenance.rawValue)
            XCTAssertEqual(result.segments, [ASRTranscriptSegment(
                text: "hello", startSeconds: 1.25, endSeconds: 2.5, speakerID: "speaker-1",
                language: "en", confidence: 0.9, emotion: "neutral", event: "speech"
            )])
            XCTAssertEqual(result.generationMetadata?.generatedTokenCount, 32)
            XCTAssertNil(result.generationMetadata?.hitLengthLimit)
        }
        let empty = ASRTranscriptionResult(mlxOutput: STTOutput(text: ""))
        XCTAssertEqual(empty.segments, [])
        XCTAssertNil(empty.language)
        XCTAssertEqual(empty.languageProvenance, .unknown)
        XCTAssertNil(empty.generationMetadata)
    }

    func testCompatibilityStreamOnlyForwardsDisplayAndTerminalEvents() {
        XCTAssertEqual(
            ASRStreamingEvent(mlxEvent: .displayUpdate(confirmedText: "hello", provisionalText: " world")),
            .displayUpdate(confirmedText: "hello", provisionalText: " world")
        )
        XCTAssertEqual(
            ASRStreamingEvent(mlxEvent: .ended(STTOutput(text: "done"))),
            .ended(ASRTranscriptionResult(text: "done"))
        )
        XCTAssertEqual(
            ASRStreamingEvent(mlxEvent: .failed(StreamingFailure(message: "decode failed"))),
            .failed(ASRStreamingFailure(message: "decode failed"))
        )
        XCTAssertNil(ASRStreamingEvent(mlxEvent: .confirmed(text: "hello")))
        XCTAssertNil(ASRStreamingEvent(mlxEvent: .provisional(text: "world")))
        XCTAssertNil(ASRStreamingEvent(mlxEvent: .stats(StreamingStats())))
    }

    func testCompatibilityGenerationOptionsPreserveDecodingControls() {
        let options = ASRGenerationOptions(
            maximumTokenCount: 321, temperature: 0.25, topProbabilityThreshold: 0.8,
            topTokenCount: 12, verbose: true, language: "zh", usePunctuation: false,
            chunkDurationSeconds: 90, minimumChunkDurationSeconds: 2.5,
            kvCacheBitWidth: 8, kvCacheGroupSize: 32, kvCacheQuantizedStartTokenCount: 128
        )
        let parameters = options.mlxParameters
        XCTAssertEqual(parameters.maxTokens, 321)
        XCTAssertEqual(parameters.temperature, Float(0.25))
        XCTAssertEqual(parameters.topP, Float(0.8))
        XCTAssertEqual(parameters.topK, 12)
        XCTAssertTrue(parameters.verbose)
        XCTAssertEqual(parameters.language, "zh")
        XCTAssertEqual(parameters.usePunctuation, false)
        XCTAssertEqual(parameters.chunkDuration, 90)
        XCTAssertEqual(parameters.minChunkDuration, 2.5)
        XCTAssertEqual(parameters.kvBits, 8)
        XCTAssertEqual(parameters.kvGroupSize, 32)
        XCTAssertEqual(parameters.quantizedKVStart, 128)
    }

    func testReleaseKeepsModelUseUntilOwnedTasksHaveExited() async {
        let runtime = MLXNativeLiveRuntime()
        let session = RuntimeTestStreamingSession()
        var releases = 0
        install(session, in: runtime, release: { releases += 1 })
        runtime.release(cancelSession: true)
        XCTAssertNil(runtime.session)
        XCTAssertTrue(runtime.hasPendingWork)
        XCTAssertEqual(releases, 0)
        await runtime.waitForRetirement()
        XCTAssertFalse(runtime.hasPendingWork)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(releases, 1)
        runtime.release(cancelSession: true)
        await runtime.waitForRetirement()
        XCTAssertEqual(releases, 1)
    }

    func testReplacingSessionDoesNotReleaseReplacementModelUse() async {
        let runtime = MLXNativeLiveRuntime()
        let old = RuntimeTestStreamingSession()
        let current = RuntimeTestStreamingSession()
        var releases: [String] = []
        install(old, in: runtime, release: { releases.append("old") })
        install(current, in: runtime, release: { releases.append("current") })
        await runtime.waitForRetirement()
        XCTAssertTrue(runtime.session === current)
        XCTAssertEqual(releases, ["old"])
        XCTAssertEqual(current.cancelCount, 0)
        runtime.release(cancelSession: true)
        await runtime.waitForRetirement()
        XCTAssertEqual(releases, ["old", "current"])
    }

    func testQueuedOldEventsAreRejectedAfterReplacement() async {
        let runtime = MLXNativeLiveRuntime()
        let old = RuntimeTestStreamingSession()
        let current = RuntimeTestStreamingSession()
        let delivered = expectation(description: "current event")
        var texts: [String] = []
        runtime.install(old, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false }, onEvent: { _ in
            XCTFail("Old session delivered an event")
        }, releaseModel: {})
        old.emit("old")
        runtime.install(current, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false }, onEvent: { event in
            if case .displayUpdate(let text, _) = event {
                texts.append(text)
                delivered.fulfill()
            }
        }, releaseModel: {})
        current.emit("current")
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(texts, ["current"])
        runtime.release(cancelSession: true)
        await runtime.waitForRetirement()
    }

    func testReleaseFromEventCallbackDoesNotDeadlockOrReleaseTwice() async {
        let runtime = MLXNativeLiveRuntime()
        let session = RuntimeTestStreamingSession()
        let delivered = expectation(description: "event released stream")
        var releases = 0
        runtime.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false }, onEvent: { _ in
            runtime.release(cancelSession: false)
            delivered.fulfill()
        }, releaseModel: { releases += 1 })
        session.emit("terminal")
        await fulfillment(of: [delivered], timeout: 1)
        await runtime.waitForRetirement()
        XCTAssertEqual(session.cancelCount, 0)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testStopFeedingBeforeTaskRunsDoesNotSubmitAudio() async {
        let runtime = MLXNativeLiveRuntime()
        let session = RuntimeTestStreamingSession()
        var samplesRequested = 0
        runtime.install(session, pollInterval: .seconds(60), nextSamples: {
            samplesRequested += 1
            return [0.1]
        }, shouldContinue: { true }, onEvent: { _ in }, releaseModel: {})
        runtime.stopFeeding()
        runtime.release(cancelSession: true)
        await runtime.waitForRetirement()
        XCTAssertEqual(samplesRequested, 0)
        XCTAssertEqual(session.feedCount, 0)
    }

    func testAbandonedRuntimeCancelsStreamAndReleasesModelUse() async {
        var runtime: MLXNativeLiveRuntime? = MLXNativeLiveRuntime()
        weak var weakRuntime = runtime
        let session = RuntimeTestStreamingSession()
        let released = expectation(description: "abandoned model use released")
        install(session, in: runtime!, release: { released.fulfill() })
        runtime = nil
        XCTAssertNil(weakRuntime)
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(session.cancelCount, 1)
    }

    func testNormalDrainRetirementDoesNotCancelSessionAgain() async {
        let runtime = MLXNativeLiveRuntime()
        let session = RuntimeTestStreamingSession()
        install(session, in: runtime, release: {})
        runtime.stopFeeding()
        runtime.session?.stop()
        runtime.release(cancelSession: false)
        await runtime.waitForRetirement()
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(session.cancelCount, 0)
    }

    private func install(_ session: RuntimeTestStreamingSession, in runtime: MLXNativeLiveRuntime, release: @escaping @MainActor () -> Void) {
        runtime.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false }, onEvent: { _ in }, releaseModel: release)
    }
}

/// Counters are lock protected because the production session contract is nonisolated.
nonisolated private final class RuntimeTestStreamingSession: ASRStreamingSession, @unchecked Sendable {
    let events: AsyncStream<ASRStreamingEvent>
    private let continuation: AsyncStream<ASRStreamingEvent>.Continuation
    private let lock = NSLock()
    private var cancellations = 0
    private var feeds = 0
    private var stops = 0

    init() {
        let pair = AsyncStream<ASRStreamingEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    var feedCount: Int { lock.lock(); defer { lock.unlock() }; return feeds }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func feedAudio(samples: [Float]) { lock.lock(); feeds += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock(); continuation.finish() }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock(); continuation.finish() }
    func emit(_ text: String) { continuation.yield(.displayUpdate(confirmedText: text, provisionalText: "")) }
}
