import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
/// Retain this explicit owner and await close; failed retirement keeps its reader and inference lane.
@MainActor
final class OmniXPCSpeakerModelOwner {
    private enum CommandResult: Sendable {
        case complete
        case acknowledgement(OmniXPCSpeakerAudioAcknowledgement)
        case batch(OmniXPCSpeakerBatch)
    }

    private static let maximumPollEventCount = 16
    let kind: OmniXPCSpeakerKind
    private let client: OmniXPCClient
    private let modelDirectory: URL
    private let coordinator: MeetingLocalInferenceCoordinator
    private let workClass: MeetingLocalInferenceWorkClass
    private var model: OmniXPCSpeakerModelReference?
    private var session: OmniXPCSpeakerSessionReference?
    private var directoryLease: OmniModelDirectoryLease?
    private var loadOperationID: UUID?
    private var loadOwnership: OmniXPCSpeakerLoadOwnership?
    private var ownedPermit: MeetingLocalInferenceOwnedPermit?
    private var activeCommand: (id: UUID, task: Task<CommandResult, Error>)?
    private var closing: (id: UUID, task: Task<Void, Error>)?
    private var sessionClosing: (id: UUID, task: Task<Void, Error>)?
    private var retiring: (id: UUID, task: Task<Void, Error>)?
    private var sessionMayExist = false
    private var acceptedSampleCount = 0
    private var cleanupRequired = false
    private var permanentCloseObserver: (@MainActor () -> Void)?
    private(set) var isClosing = false
    private(set) var isClosed = false
    var hasSession: Bool { session != nil || sessionMayExist }
    var hasPendingCleanup: Bool {
        cleanupRequired || isClosing || hasSession || ownedPermit != nil || activeCommand != nil
            || closing != nil || sessionClosing != nil || retiring != nil
            || (loadOperationID != nil && model == nil)
    }

    init(client: OmniXPCClient, kind: OmniXPCSpeakerKind, modelDirectory: URL,
         coordinator: MeetingLocalInferenceCoordinator = .shared,
         workClass: MeetingLocalInferenceWorkClass = .fileASR) {
        self.client = client
        self.kind = kind
        self.modelDirectory = modelDirectory
        self.coordinator = coordinator
        self.workClass = workClass
    }

    func notifyWhenPermanentlyClosed(_ observer: @escaping @MainActor () -> Void) {
        if isClosed {
            observer()
        } else {
            precondition(permanentCloseObserver == nil, "A speaker owner can be entrusted to only one streaming consumer.")
            permanentCloseObserver = observer
        }
    }

    func prepare(timeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60)) async throws {
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        guard !hasSession, ownedPermit == nil else {
            throw OmniXPCFailure.error(.busy, "Close the speaker session before preparing a model.")
        }
        _ = try await runCommand(cleanupTimeout: cleanupTimeout, releaseOnSuccess: true) {
            if let model = self.model {
                do { try self.requireLiveModel(model) } catch {
                    self.cleanupRequired = true
                    throw error
                }
                return .complete
            } else {
                self.ownedPermit = try await self.coordinator.reserveOwnedPermit(self.workClass)
                try Task.checkCancellation()
                let authorized = try self.client.authorizedSpeakerModelDirectory(self.modelDirectory)
                let reader = try await ModelDiskOperations.perform {
                    let reader = try OmniModelDirectoryLease.acquire(for: authorized.directory, mode: .sharedRead)
                    let reauthorized = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: authorized.relativePath, container: authorized.container
                    )
                    guard reader.directory.path == reauthorized.path else {
                        throw OmniXPCFailure.error(.invalidRequest, "The speaker directory changed during authorization.")
                    }
                    try OmniModelArtifactValidation.validateSafetensorsDirectory(at: reader.directory)
                    return reader
                }
                self.directoryLease = reader
                try Task.checkCancellation()
                let operationID = UUID()
                self.loadOperationID = operationID
                let ownership = OmniXPCSpeakerLoadOwnership(operationID: operationID, kind: self.kind)
                self.loadOwnership = ownership
                self.model = try await self.client.loadSpeaker(
                    kind: self.kind, modelDirectory: reader.directory, timeout: timeout,
                    cleanupTimeout: cleanupTimeout, operationID: operationID, ownership: ownership
                )
                return .complete
            }
        }
    }

    func startSession(settings: OmniXPCSpeakerSettings, timeout: Duration = .seconds(300),
                      cleanupTimeout: Duration = .seconds(60)) async throws {
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        guard let model, !hasSession, ownedPermit == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "Explicitly prepare a speaker model and close its previous session first.")
        }
        try settings.validate(for: model)
        _ = try settings.encoded()
        _ = try await runCommand(cleanupTimeout: cleanupTimeout) {
            // note (assistant): Native workers outlive push ACKs, so this permit spans the entire session.
            self.ownedPermit = try await self.coordinator.reserveOwnedPermit(self.workClass)
            try Task.checkCancellation()
            try self.requireLiveModel(model)
            self.sessionMayExist = true
            self.session = try await self.client.startSpeakerSession(
                model, settings: settings, sessionID: UUID(), timeout: timeout, cleanupTimeout: cleanupTimeout
            )
            return .complete
        }
    }

    func push(audio: Data, timeout: Duration = .seconds(300),
              cleanupTimeout: Duration = .seconds(60)) async throws -> OmniXPCSpeakerAudioAcknowledgement {
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        let session = try requireSession()
        let sampleCount = try OmniXPCRequestValidation.audioSamples(
            audio: audio, maximumSampleCount: OmniXPCSpeakerLimits.maximumChunkSampleCount
        ).count
        guard sampleCount <= OmniXPCSpeakerLimits.maximumSessionSampleCount - acceptedSampleCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The speaker session exceeds its audio limit.")
        }
        let result = try await runCommand(cleanupTimeout: cleanupTimeout) {
            let acknowledgement = try await self.client.pushSpeakerAudio(session, audio: audio, timeout: timeout)
            self.acceptedSampleCount += sampleCount
            return .acknowledgement(acknowledgement)
        }
        guard case let .acknowledgement(acknowledgement) = result else { preconditionFailure("Unexpected speaker command result.") }
        return acknowledgement
    }

    func commit(timeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60)) async throws {
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        let session = try requireSession()
        _ = try await runCommand(cleanupTimeout: cleanupTimeout) {
            try await self.client.commitSpeakerSession(session, timeout: timeout)
            return .complete
        }
    }

    func finish(timeout: Duration = .seconds(300), cleanupTimeout: Duration = .seconds(60)) async throws {
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        let session = try requireSession()
        _ = try await runCommand(cleanupTimeout: cleanupTimeout) {
            try await self.client.finishSpeakerSession(session, timeout: timeout)
            return .complete
        }
    }

    func poll(maximumEventCount: Int = OmniXPCSpeakerModelOwner.maximumPollEventCount, timeout: Duration = .seconds(300),
              cleanupTimeout: Duration = .seconds(60)) async throws -> OmniXPCSpeakerBatch {
        try requireAdmission(timeout: timeout, cleanupTimeout: cleanupTimeout)
        let session = try requireSession()
        guard (1...Self.maximumPollEventCount).contains(maximumEventCount) else {
            throw OmniXPCFailure.error(.invalidRequest, "A speaker poll requires between one and sixteen events.")
        }
        let result = try await runCommand(cleanupTimeout: cleanupTimeout) {
            .batch(try await self.client.pollSpeakerEvents(session, maximumEventCount: maximumEventCount, timeout: timeout))
        }
        guard case let .batch(batch) = result else { preconditionFailure("Unexpected speaker command result.") }
        return batch
    }

    func closeSession(timeout: Duration = .seconds(60)) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if isClosed { return } else if isClosing {
            return try await close(timeout: timeout)
        } else if let sessionClosing {
            return try await sessionClosing.task.value
        } else { }
        let identity = UUID()
        let task = Task { @MainActor in
            defer {
                if self.sessionClosing?.id == identity { self.sessionClosing = nil } else { }
            }
            if let command = self.activeCommand {
                command.task.cancel()
                _ = await command.task.result
            } else { }
            if self.cleanupRequired || (self.sessionMayExist && self.session == nil) {
                try await self.retireScope(timeout: timeout)
            } else if let session = self.session {
                do {
                    try await self.client.closeSpeakerSession(session, timeout: timeout)
                    self.session = nil
                    self.sessionMayExist = false
                    self.acceptedSampleCount = 0
                    try await self.releasePermit()
                } catch {
                    self.cleanupRequired = true
                    try await self.retireScope(timeout: timeout)
                    throw error
                }
            } else { }
        }
        sessionClosing = (identity, task)
        try await task.value
    }

    func close(timeout: Duration = .seconds(60)) async throws {
        guard timeout > .zero else { throw OmniXPCFailure.error(.invalidRequest, "The speaker cleanup timeout must be positive.") }
        if isClosed { return } else if let closing {
            return try await closing.task.value
        } else { }
        isClosing = true
        let identity = UUID()
        let task = Task { @MainActor in
            defer {
                if self.closing?.id == identity { self.closing = nil } else { }
            }
            if let command = self.activeCommand {
                command.task.cancel()
                _ = await command.task.result
            } else { }
            if let sessionClosing = self.sessionClosing {
                _ = await sessionClosing.task.result
            } else { }
            try await self.retireScope(timeout: timeout)
            self.isClosed = true
            self.isClosing = false
            let observer = self.permanentCloseObserver
            self.permanentCloseObserver = nil
            observer?()
        }
        closing = (identity, task)
        try await task.value
    }

    private func runCommand(cleanupTimeout: Duration, releaseOnSuccess: Bool = false,
                            operation: @escaping @MainActor () async throws -> CommandResult) async throws -> CommandResult {
        let identity = UUID()
        let task = Task { @MainActor in
            defer {
                if self.activeCommand?.id == identity { self.activeCommand = nil } else { }
            }
            do {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                if releaseOnSuccess {
                    try await self.releasePermit()
                    if Task.isCancelled, self.model != nil { self.cleanupRequired = true } else { }
                } else { }
                try Task.checkCancellation()
                return result
            } catch {
                if self.ownedPermit != nil || self.cleanupRequired {
                    self.cleanupRequired = true
                    // note (assistant): Public close may already be waiting for this command, so retire the scope directly.
                    try await self.retireScope(timeout: cleanupTimeout)
                } else { }
                throw error
            }
        }
        activeCommand = (identity, task)
        return try await withTaskCancellationHandler {
            let result = try await task.value
            if Task.isCancelled {
                try await self.retireScope(timeout: cleanupTimeout)
                throw CancellationError()
            } else { }
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func retireScope(timeout: Duration) async throws {
        if let retiring { return try await retiring.task.value } else { }
        cleanupRequired = true
        let identity = UUID()
        let task = Task { @MainActor in
            defer {
                if self.retiring?.id == identity { self.retiring = nil } else { }
            }
            if self.model != nil || self.loadOwnership?.phase == .submitted {
                if self.ownedPermit == nil {
                    self.ownedPermit = try await self.coordinator.reserveOwnedPermit(.modelCleanup)
                } else { }
                if let model = self.model {
                    try await self.client.closeSpeakerModel(model, timeout: timeout)
                } else if let operationID = self.loadOperationID {
                    try await self.client.closePendingSpeakerLoad(timeout: timeout, requiredOperationID: operationID)
                } else { preconditionFailure("Missing speaker cleanup identity.") }
            } else { }
            self.session = nil
            self.sessionMayExist = false
            self.acceptedSampleCount = 0
            self.model = nil
            self.loadOperationID = nil
            self.loadOwnership = nil
            self.directoryLease = nil
            try await self.releasePermit()
            self.cleanupRequired = false
        }
        retiring = (identity, task)
        try await task.value
    }

    private func releasePermit() async throws {
        if let permit = ownedPermit {
            try await coordinator.completeOwnedPermit(permit)
            ownedPermit = nil
        } else { }
    }

    private func requireLiveModel(_ model: OmniXPCSpeakerModelReference) throws {
        let state = try client.requireSpeakerModel(model)
        guard !state.closing, !state.isLoading, state.session == nil else {
            throw OmniXPCFailure.error(.busy, "The speaker model is not idle and prepared.")
        }
    }

    private func requireSession() throws -> OmniXPCSpeakerSessionReference {
        guard let session, ownedPermit != nil else {
            throw OmniXPCFailure.error(.invalidRequest, "Explicitly start the prepared speaker session first.")
        }
        return session
    }

    private func requireAdmission(timeout: Duration, cleanupTimeout: Duration) throws {
        try Task.checkCancellation()
        guard workClass == .fileASR || workClass == .finalASR, timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "Speaker ownership requires final/file ASR and positive timeouts.")
        }
        guard !isClosing, !isClosed, !cleanupRequired, activeCommand == nil,
              closing == nil, sessionClosing == nil, retiring == nil else {
            throw OmniXPCFailure.error(.busy, "The speaker owner has active work or pending cleanup.")
        }
    }
}
#endif
