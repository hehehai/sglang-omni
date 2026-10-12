import XCTest
@testable import Voxt

final class MeetingLocalInferenceOwnedPermitTests: XCTestCase {
    func testOwnedFileRetainsLaneAndCacheAfterCallerFailureOrCancellation() async throws {
        for shouldCancel in [false, true] {
            let hooks = MeetingInferenceHooks()
            let coordinator = hooks.makeCoordinator()
            let gate = MeetingInferenceGate()
            let caller = Task {
                let permit = try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
                await gate.wait()
                throw MeetingOwnedWorkFailure(permit: permit, wasCancelled: Task.isCancelled)
            }
            await gate.waitUntilStarted()
            if shouldCancel { caller.cancel() }
            await gate.open()
            let permit: MeetingLocalInferenceOwnedPermit
            do {
                try await caller.value
                return XCTFail("Expected the resource owner's failure")
            } catch let failure as MeetingOwnedWorkFailure {
                XCTAssertEqual(failure.wasCancelled, shouldCancel)
                permit = failure.permit
            }
            XCTAssertEqual(hooks.events, [.trim(false), .begin])
            let beforeCompletion = await coordinator.currentStatistics()
            XCTAssertEqual(beforeCompletion.completedCount, 0)

            let probe = Task {
                try await coordinator.withPermit(.liveASRFeed) { hooks.record(.probe) }
            }
            let queued = await waitForQueuedInferenceWork(1, coordinator: coordinator)
            XCTAssertTrue(queued)
            XCTAssertEqual(hooks.events, [.trim(false), .begin])
            try await coordinator.completeOwnedPermit(permit)
            try await probe.value
            XCTAssertEqual(hooks.events, [.trim(false), .begin, .trim(false), .restore, .probe])
            await assertInvalidPermit(permit, coordinator: coordinator)
            let afterCompletion = await coordinator.currentStatistics()
            XCTAssertEqual(afterCompletion.completedCount, 2)
            XCTAssertEqual(hooks.events, [.trim(false), .begin, .trim(false), .restore, .probe])
        }
    }

    func testBorrowedForeignAndStaleTokensCannotReleaseActiveOwnedWork() async throws {
        let firstHooks = MeetingInferenceHooks()
        let secondHooks = MeetingInferenceHooks()
        let first = firstHooks.makeCoordinator()
        let second = secondHooks.makeCoordinator()
        let firstPermit = try await first.reserveOwnedPermit(.fileSpeakerAnalysis)
        let borrowedPermit = firstPermit
        let secondPermit = try await second.reserveOwnedPermit(.fileASR)
        await assertInvalidPermit(borrowedPermit, coordinator: second)
        await assertInvalidPermit(secondPermit, coordinator: first)
        XCTAssertEqual(firstHooks.events, [.trim(false), .begin])
        XCTAssertEqual(secondHooks.events, [.trim(false), .begin])
        try await first.completeOwnedPermit(borrowedPermit)
        let replacement = try await first.reserveOwnedPermit(.fileSpeakerAnalysis)
        await assertInvalidPermit(firstPermit, coordinator: first)
        XCTAssertEqual(firstHooks.events, [.trim(false), .begin, .trim(false), .restore, .trim(false), .begin])
        try await first.completeOwnedPermit(replacement)
        try await second.completeOwnedPermit(secondPermit)
        let firstStatistics = await first.currentStatistics()
        let secondStatistics = await second.currentStatistics()
        XCTAssertEqual(firstStatistics.completedCount, 2)
        XCTAssertEqual(secondStatistics.completedCount, 1)
    }

    func testRepeatedCompletionDoesNotReleaseAnOrdinaryPermit() async throws {
        let coordinator = MeetingLocalInferenceCoordinator(readThermalState: { .nominal })
        let permit = try await coordinator.reserveOwnedPermit(.modelCleanup)
        try await coordinator.completeOwnedPermit(permit)
        let gate = MeetingInferenceGate()
        let order = MeetingInferenceOrderRecorder()
        let active = Task { try await coordinator.withPermit(.liveASRFinal) { await gate.wait() } }
        await gate.waitUntilStarted()
        let probe = Task { try await coordinator.withPermit(.liveASRFeed) { await order.append("probe") } }
        let queued = await waitForQueuedInferenceWork(1, coordinator: coordinator)
        XCTAssertTrue(queued)
        await assertInvalidPermit(permit, coordinator: coordinator)
        let beforeRelease = await order.values()
        XCTAssertTrue(beforeRelease.isEmpty)
        await gate.open()
        _ = try await (active.value, probe.value)
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 3)
    }

    func testQueuedOwnedReservationCancellationDoesNotReleaseActiveLane() async throws {
        let hooks = MeetingInferenceHooks()
        let coordinator = hooks.makeCoordinator()
        let active = try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
        let waiting = Task { try await coordinator.reserveOwnedPermit(.modelCleanup) }
        let queued = await waitForQueuedInferenceWork(1, coordinator: coordinator)
        XCTAssertTrue(queued)
        let probe = Task { try await coordinator.withPermit(.liveASRFeed) { hooks.record(.probe) } }
        let bothQueued = await waitForQueuedInferenceWork(2, coordinator: coordinator)
        XCTAssertTrue(bothQueued)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(hooks.events, [.trim(false), .begin])
        try await coordinator.completeOwnedPermit(active)
        try await probe.value
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.cancelledCount, 1)
        XCTAssertEqual(statistics.completedCount, 2)
        XCTAssertEqual(hooks.events, [.trim(false), .begin, .trim(false), .restore, .probe])
    }

    func testOwnedFileWaitsForRecordingMemoryAndThermalRecovery() async throws {
        let constraints: [(recording: Bool, memory: Bool, thermal: ProcessInfo.ThermalState)] = [
            (true, false, .nominal), (false, true, .nominal), (false, false, .critical)
        ]
        for constraint in constraints {
            let hooks = MeetingInferenceHooks()
            hooks.memoryConstrained = constraint.memory
            hooks.thermalState = constraint.thermal
            let coordinator = hooks.makeCoordinator()
            await coordinator.setRecordingActive(constraint.recording)
            await coordinator.setMemoryPressureConstrained(constraint.memory)
            let taskID = UUID()
            let resourceWait = expectation(forNotification: .voxtMeetingFileResourceWaitDidChange, object: nil) {
                $0.userInfo?["taskID"] as? String == taskID.uuidString && $0.userInfo?["isWaiting"] as? Bool == true
            }
            let waiting = Task {
                try await MeetingFileTaskContext.$taskID.withValue(taskID) {
                    try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
                }
            }
            await fulfillment(of: [resourceWait], timeout: 2)
            XCTAssertFalse(hooks.events.contains(.begin))
            await coordinator.setRecordingActive(false)
            await coordinator.setMemoryPressureConstrained(false)
            hooks.memoryConstrained = false
            hooks.thermalState = .nominal
            let permit = try await waiting.value
            XCTAssertEqual(hooks.events.filter { $0 == .begin }.count, 1)
            try await coordinator.completeOwnedPermit(permit)
            XCTAssertEqual(hooks.events.suffix(2), [.trim(false), .restore])
        }
    }

    func testWaitingOwnedFileRechecksPressureAndCancellationDoesNotInstallCacheScope() async throws {
        let hooks = MeetingInferenceHooks()
        let coordinator = hooks.makeCoordinator()
        let active = try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
        let waiting = Task { try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis) }
        let submitted = await waitForInferenceCondition { await coordinator.currentStatistics().submittedCount == 2 }
        XCTAssertTrue(submitted)
        XCTAssertEqual(hooks.events, [.trim(false), .begin])
        hooks.memoryConstrained = true
        try await coordinator.completeOwnedPermit(active)
        let waitedForPressure = await waitForInferenceCondition { hooks.events.filter { $0 == .trim(true) }.count >= 2 }
        XCTAssertTrue(waitedForPressure)
        XCTAssertEqual(hooks.events.filter { $0 == .begin }.count, 1)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(hooks.events.filter { $0 == .restore }.count, 1)
        let cleanup = try await coordinator.reserveOwnedPermit(.modelCleanup)
        try await coordinator.completeOwnedPermit(cleanup)
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 2)
    }

    func testCleanupBypassesConstraintsButStaysSerialAndOutranksLiveWork() async throws {
        XCTAssertEqual(MeetingLocalInferenceWorkClass.modelCleanup.priority, 110)
        let hooks = MeetingInferenceHooks()
        hooks.memoryConstrained = true
        hooks.thermalState = .critical
        let coordinator = hooks.makeCoordinator()
        await coordinator.setRecordingActive(true)
        await coordinator.setMemoryPressureConstrained(true)
        let active = try await coordinator.reserveOwnedPermit(.liveASRFinal)
        let live = Task { try await coordinator.withPermit(.liveASRFeed) { hooks.record(.probe) } }
        let liveQueued = await waitForQueuedInferenceWork(1, coordinator: coordinator)
        XCTAssertTrue(liveQueued)
        let cleanup = Task { try await coordinator.reserveOwnedPermit(.modelCleanup) }
        let bothQueued = await waitForQueuedInferenceWork(2, coordinator: coordinator)
        XCTAssertTrue(bothQueued)
        var statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 0)
        try await coordinator.completeOwnedPermit(active)
        let cleanupPermit = try await cleanup.value
        XCTAssertTrue(hooks.events.isEmpty)
        try await coordinator.completeOwnedPermit(cleanupPermit)
        try await live.value
        XCTAssertEqual(hooks.events, [.probe])
        statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 3)
        XCTAssertEqual(statistics.thermalDeferralCount, 0)
        XCTAssertEqual(statistics.memoryDeferralCount, 0)
    }

    func testPostAcquireCancellationReleasesLaneWithoutBeginningOwnedCacheScope() async throws {
        let hooks = MeetingInferenceHooks()
        hooks.thermalReadAction = { withUnsafeCurrentTask { $0?.cancel() } }
        let coordinator = hooks.makeCoordinator()
        let reservation = Task { try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis) }
        do { _ = try await reservation.value; XCTFail("Expected cancellation before transfer") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(hooks.events, [.trim(false)], "Only ordinary admission maintenance may run")
        hooks.thermalReadAction = nil
        try await coordinator.withPermit(.liveASRFeed) { hooks.record(.probe) }
        XCTAssertEqual(hooks.events, [.trim(false), .probe])
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 1)
    }

    func testAlreadyCancelledReservationDoesNotSubmitOrTouchCacheHooks() async throws {
        let hooks = MeetingInferenceHooks()
        let coordinator = hooks.makeCoordinator()
        let reservation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
        }
        do { _ = try await reservation.value; XCTFail("Expected cancellation before admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics, MeetingLocalInferenceStatistics())
        XCTAssertTrue(hooks.events.isEmpty)
        let permit = try await coordinator.reserveOwnedPermit(.modelCleanup)
        try await coordinator.completeOwnedPermit(permit)
    }

    func testOwnedReservationsKeepTheExistingQueueBound() async throws {
        let coordinator = MeetingLocalInferenceCoordinator(readThermalState: { .nominal })
        let active = try await coordinator.reserveOwnedPermit(.modelCleanup)
        let queuedReservations = (0..<32).map { _ in
            Task { try await coordinator.reserveOwnedPermit(.modelCleanup) }
        }
        let queueFull = await waitForQueuedInferenceWork(32, coordinator: coordinator)
        XCTAssertTrue(queueFull)
        do {
            _ = try await coordinator.reserveOwnedPermit(.modelCleanup)
            XCTFail("Expected the existing queue safety limit")
        } catch {
            guard let coordinatorError = error as? MeetingLocalInferenceCoordinatorError,
                  case .overloaded = coordinatorError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        for reservation in queuedReservations { reservation.cancel() }
        for reservation in queuedReservations {
            do { _ = try await reservation.value; XCTFail("Expected queued cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        try await coordinator.completeOwnedPermit(active)
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.peakQueuedCount, 32)
        XCTAssertEqual(statistics.overloadedCount, 1)
        XCTAssertEqual(statistics.cancelledCount, 32)
        XCTAssertEqual(statistics.completedCount, 1)
    }

    func testNonFileThermalDeferralRemainsAnErrorForBothPermitAPIs() async throws {
        let coordinator = MeetingLocalInferenceCoordinator(readThermalState: { .serious })
        do {
            _ = try await coordinator.reserveOwnedPermit(.summary)
            XCTFail("Expected thermal rejection")
        } catch {
            guard let coordinatorError = error as? MeetingLocalInferenceCoordinatorError,
                  case .thermallyConstrained = coordinatorError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        do {
            try await coordinator.withPermit(.summary) { XCTFail("Rejected operation must not run") }
            XCTFail("Expected thermal rejection")
        } catch {
            guard let coordinatorError = error as? MeetingLocalInferenceCoordinatorError,
                  case .thermallyConstrained = coordinatorError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.thermalDeferralCount, 2)
        XCTAssertEqual(statistics.completedCount, 0)
    }

    func testMatchingCompletionStillRunsFromCancelledTask() async throws {
        let hooks = MeetingInferenceHooks()
        let coordinator = hooks.makeCoordinator()
        let permit = try await coordinator.reserveOwnedPermit(.fileSpeakerAnalysis)
        let completion = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await coordinator.completeOwnedPermit(permit)
        }
        try await completion.value
        XCTAssertEqual(hooks.events, [.trim(false), .begin, .trim(false), .restore])
        try await coordinator.withPermit(.liveASRFeed) { hooks.record(.probe) }
        let statistics = await coordinator.currentStatistics()
        XCTAssertEqual(statistics.completedCount, 2)
    }

    private func assertInvalidPermit(
        _ permit: MeetingLocalInferenceOwnedPermit,
        coordinator: MeetingLocalInferenceCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await coordinator.completeOwnedPermit(permit)
            XCTFail("Expected invalid permit", file: file, line: line)
        } catch {
            guard let coordinatorError = error as? MeetingLocalInferenceCoordinatorError,
                  case .invalidPermit = coordinatorError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

}
