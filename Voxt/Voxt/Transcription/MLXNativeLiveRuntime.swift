import Foundation

nonisolated protocol ASRStreamingSession: AnyObject, Sendable {
    var events: AsyncStream<ASRStreamingEvent> { get }
    func feedAudio(samples: [Float])
    func stop()
    func cancel()
}

nonisolated protocol ASRRetiringStreamingSession: ASRStreamingSession {
    @MainActor func closeAndWait() async throws
    @MainActor func notifyWhenPermanentlyClosed(_ observer: @escaping @MainActor () -> Void)
}

nonisolated struct MLXMeetingNativeStreamingConfiguration: Sendable {
    let session: any ASRStreamingSession
    let liveMode: MLXLiveMode
    let qwenUsesAutomaticLanguageProtocol: Bool
    let mossVisibleOutputMode: MossASROutputMode?
}

/// Owns the installed stream, its two consumer/feed tasks and the transferred
/// model-use release. A retiring stream cannot clear its replacement's state.
/// Retiring sessions additionally require their explicit Native close barrier.
/// Other sessions retain the historical task-only transport retirement behavior.
@MainActor
final class MLXNativeLiveRuntime {
    private struct Active {
        let id: UUID
        let session: any ASRStreamingSession
        let eventTask: Task<Void, Never>
        let feedTask: Task<Void, Never>
        let releaseModel: @MainActor () -> Void
    }

    private var active: Active?
    private var retirementTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRetirements: [UUID: Active] = [:]
    private var retirementFailures: [UUID: Error] = [:]
    private var retainedUntilRetired: MLXNativeLiveRuntime?
    var session: (any ASRStreamingSession)? { active?.session }
    var hasPendingWork: Bool { active != nil || !pendingRetirements.isEmpty }

    func install(
        _ session: any ASRStreamingSession,
        pollInterval: Duration,
        nextSamples: @escaping @MainActor () -> [Float],
        shouldContinue: @escaping @MainActor () -> Bool,
        onEvent: @escaping @MainActor (ASRStreamingEvent) -> Void,
        releaseModel: @escaping @MainActor () -> Void
    ) {
        release(cancelSession: true)
        let id = UUID()
        let events = Task { @MainActor [weak self, session] in
            for await event in session.events {
                guard !Task.isCancelled, self?.active?.id == id else { return }
                onEvent(event)
            }
        }
        let feed = Task { @MainActor [weak self, session] in
            while !Task.isCancelled, self?.active?.id == id {
                let samples = nextSamples()
                if !samples.isEmpty { session.feedAudio(samples: samples) }
                guard shouldContinue() else { return }
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
        active = Active(id: id, session: session, eventTask: events, feedTask: feed, releaseModel: releaseModel)
        refreshNativeRetention()
        if let owned = session as? any ASRRetiringStreamingSession, let installed = active {
            owned.notifyWhenPermanentlyClosed { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await installed.eventTask.value
                    if self.active?.id == installed.id {
                        self.release(cancelSession: false)
                    } else if self.pendingRetirements[installed.id] != nil, self.retirementTasks[installed.id] == nil {
                        self.startRetirement(installed)
                    }
                }
            }
        }
    }

    func stopFeeding() {
        active?.feedTask.cancel()
    }

    func release(cancelSession: Bool) {
        guard let retired = active else { return }
        active = nil
        retired.feedTask.cancel()
        retired.eventTask.cancel()
        if cancelSession { retired.session.cancel() }
        pendingRetirements[retired.id] = retired
        startRetirement(retired)
    }

    func waitForRetirement() async {
        while !retirementTasks.isEmpty {
            for task in Array(retirementTasks.values) { await task.value }
        }
    }

    func waitForCheckedRetirement() async throws {
        await waitForRetirement()
        if let failure = retirementFailures.values.first { throw failure }
    }

    func retryRetirement() async throws {
        for retired in Array(pendingRetirements.values) where retirementTasks[retired.id] == nil {
            startRetirement(retired)
        }
        try await waitForCheckedRetirement()
    }

    private func startRetirement(_ retired: Active) {
        retirementFailures[retired.id] = nil
        retirementTasks[retired.id] = Task { @MainActor [self] in
            defer { retirementTasks[retired.id] = nil }
            await retired.feedTask.value
            await retired.eventTask.value
            do {
                if let owned = retired.session as? any ASRRetiringStreamingSession {
                    try await owned.closeAndWait()
                }
                retired.releaseModel()
                pendingRetirements[retired.id] = nil
                refreshNativeRetention()
            } catch {
                retirementFailures[retired.id] = error
            }
        }
    }

    private func refreshNativeRetention() {
        let hasNativeOwner = active?.session is any ASRRetiringStreamingSession
            || pendingRetirements.values.contains { $0.session is any ASRRetiringStreamingSession }
        retainedUntilRetired = hasNativeOwner ? self : nil
    }

    isolated deinit {
        guard let retired = active else { return }
        retired.feedTask.cancel()
        retired.eventTask.cancel()
        retired.session.cancel()
        // Capture the entry, never self: an abandoned transcriber must not leak
        // its stream or model use even if explicit shutdown was not called.
        Task { @MainActor in
            await retired.feedTask.value
            await retired.eventTask.value
            retired.releaseModel()
        }
    }
}
