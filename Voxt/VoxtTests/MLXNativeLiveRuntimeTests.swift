import XCTest
@testable import Voxt

@MainActor
final class MLXNativeLiveRuntimeTests: XCTestCase {
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

    func testNativeRetirementDoesNotReleaseModelBeforeCloseBarrier() async throws {
        let runtime = MLXNativeLiveRuntime()
        let session = RetiringRuntimeTestSession()
        let entered = expectation(description: "Native close entered")
        var barrier: CheckedContinuation<Void, Never>?
        var releases = 0
        session.closeOperation = {
            await withCheckedContinuation { continuation in
                barrier = continuation
                entered.fulfill()
            }
        }
        runtime.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                        onEvent: { _ in }, releaseModel: { releases += 1 })
        runtime.release(cancelSession: true)
        let waiting = Task { try await runtime.waitForCheckedRetirement() }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(runtime.hasPendingWork)
        XCTAssertEqual(releases, 0)
        barrier?.resume()
        try await waiting.value
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testFailedNativeRetirementRetainsOriginalScopeForExplicitRetry() async throws {
        let runtime = MLXNativeLiveRuntime()
        let session = RetiringRuntimeTestSession()
        var releases = 0
        session.shouldFailClose = true
        runtime.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                        onEvent: { _ in }, releaseModel: { releases += 1 })
        runtime.release(cancelSession: false)
        do {
            try await runtime.waitForCheckedRetirement()
            XCTFail("Unknown Native cleanup was accepted")
        } catch RetiringRuntimeTestSession.Failure.retained {}
        XCTAssertTrue(runtime.hasPendingWork)
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(session.closeAttempts, 1)
        do {
            try await runtime.waitForCheckedRetirement()
            XCTFail("A second wait hid unknown cleanup")
        } catch RetiringRuntimeTestSession.Failure.retained {}
        XCTAssertEqual(session.closeAttempts, 1)
        session.shouldFailClose = false
        try await runtime.retryRetirement()
        XCTAssertEqual(session.closeAttempts, 2)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(runtime.hasPendingWork)
    }

    func testAbandonedNativeRuntimeRemainsOwnedUntilExplicitSuccessfulClose() async throws {
        var runtime: MLXNativeLiveRuntime? = MLXNativeLiveRuntime()
        weak var retainedRuntime = runtime
        let session = RetiringRuntimeTestSession()
        var releases = 0
        runtime?.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                         onEvent: { _ in }, releaseModel: { releases += 1 })
        runtime = nil
        XCTAssertNotNil(retainedRuntime)
        XCTAssertEqual(session.closeAttempts, 0)
        XCTAssertEqual(releases, 0)
        retainedRuntime?.release(cancelSession: true)
        try await retainedRuntime?.waitForCheckedRetirement()
        XCTAssertEqual(session.closeAttempts, 1)
        XCTAssertEqual(releases, 1)
        XCTAssertNil(retainedRuntime)
    }

    func testProvenNativeCloseReleasesAbandonedRuntimeAndModelUse() async {
        var runtime: MLXNativeLiveRuntime? = MLXNativeLiveRuntime()
        weak var retainedRuntime = runtime
        let session = RetiringRuntimeTestSession()
        let released = expectation(description: "proven Native close released model use")
        runtime?.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                         onEvent: { _ in }, releaseModel: { released.fulfill() })
        runtime = nil
        XCTAssertNotNil(retainedRuntime)
        session.completeNativeClose()
        await fulfillment(of: [released], timeout: 1)
        XCTAssertNil(retainedRuntime)
        XCTAssertEqual(session.closeAttempts, 1)
    }

    func testExternalProvenNativeCloseRetiresAbandonedFailedScope() async throws {
        var runtime: MLXNativeLiveRuntime? = MLXNativeLiveRuntime()
        weak var retainedRuntime = runtime
        let session = RetiringRuntimeTestSession()
        session.shouldFailClose = true
        let released = expectation(description: "original scope released after external Native close")
        runtime?.install(session, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                         onEvent: { _ in }, releaseModel: { released.fulfill() })
        runtime?.release(cancelSession: true)
        do {
            try await runtime?.waitForCheckedRetirement()
            XCTFail("Unknown Native cleanup was accepted")
        } catch RetiringRuntimeTestSession.Failure.retained {}
        runtime = nil
        XCTAssertNotNil(retainedRuntime)
        session.shouldFailClose = false
        session.completeNativeClose()
        await fulfillment(of: [released], timeout: 1)
        XCTAssertNil(retainedRuntime)
        XCTAssertEqual(session.closeAttempts, 2)
    }

    func testNativeCleanupFailureDoesNotReleaseReplacementScope() async throws {
        let runtime = MLXNativeLiveRuntime()
        let original = RetiringRuntimeTestSession()
        let replacement = RetiringRuntimeTestSession()
        original.shouldFailClose = true
        var releases: [String] = []
        runtime.install(original, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                        onEvent: { _ in }, releaseModel: { releases.append("original") })
        runtime.install(replacement, pollInterval: .seconds(60), nextSamples: { [] }, shouldContinue: { false },
                        onEvent: { _ in }, releaseModel: { releases.append("replacement") })
        do {
            try await runtime.waitForCheckedRetirement()
            XCTFail("Unknown original cleanup was accepted")
        } catch RetiringRuntimeTestSession.Failure.retained {}
        XCTAssertTrue(runtime.session === replacement)
        XCTAssertEqual(releases, [])
        original.shouldFailClose = false
        try await runtime.retryRetirement()
        XCTAssertEqual(releases, ["original"])
        XCTAssertTrue(runtime.session === replacement)
        runtime.release(cancelSession: true)
        try await runtime.waitForCheckedRetirement()
        XCTAssertEqual(releases, ["original", "replacement"])
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

@MainActor
private final class RetiringRuntimeTestSession: ASRRetiringStreamingSession {
    enum Failure: Error { case retained }
    nonisolated let events: AsyncStream<ASRStreamingEvent>
    private nonisolated let continuation: AsyncStream<ASRStreamingEvent>.Continuation
    var closeAttempts = 0
    var shouldFailClose = false
    var closeOperation: (@MainActor () async -> Void)?
    private var permanentCloseObserver: (@MainActor () -> Void)?

    func notifyWhenPermanentlyClosed(_ observer: @escaping @MainActor () -> Void) {
        permanentCloseObserver = observer
    }

    func completeNativeClose() {
        continuation.finish()
        let observer = permanentCloseObserver
        permanentCloseObserver = nil
        observer?()
    }

    init() {
        let stream = AsyncStream<ASRStreamingEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    nonisolated func feedAudio(samples: [Float]) {}
    nonisolated func stop() { continuation.finish() }
    nonisolated func cancel() { continuation.finish() }

    func closeAndWait() async throws {
        closeAttempts += 1
        await closeOperation?()
        if shouldFailClose { throw Failure.retained }
        completeNativeClose()
    }
}
