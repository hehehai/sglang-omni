import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
/// Retain this explicit, opt-in ASR owner and await successful close, including after failed retirement.
@MainActor
final class OmniXPCSileroModelOwner {
    private struct Command {
        let identity: UUID
        let cancel: () -> Void
        let settled: Task<Void, Never>
    }

    private let client: OmniXPCClient
    private let modelDirectory: URL
    private let coordinator: MeetingLocalInferenceCoordinator
    private var directoryLease: OmniModelDirectoryLease?
    private var model: OmniXPCSileroModelReference?
    private(set) var loadOwnership: OmniXPCSileroLoadOwnership?
    private var ownedPermit: MeetingLocalInferenceOwnedPermit?
    private var preparation: Task<OmniXPCSileroModelReference, Error>?
    private var command: Command?
    private var closing: Task<Void, Error>?
    private var streams: [UUID: OmniXPCSileroStreamReference] = [:]
    private var streamClosures: [UUID: Task<Void, Error>] = [:]
    private(set) var isClosing = false
    private(set) var isClosed = false

    init(client: OmniXPCClient, modelDirectory: URL, coordinator: MeetingLocalInferenceCoordinator = .shared) {
        self.client = client
        self.modelDirectory = modelDirectory
        self.coordinator = coordinator
    }

    func requirePreparedModel() throws -> OmniXPCSileroModelReference {
        guard !isClosing, !isClosed, preparation == nil, let model,
              loadOwnership?.phase == .submitted(connectionID: model.connectionID) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero owner must already be prepared and entrusted to this caller.")
        }
        let state = try client.requireSileroModel(model)
        guard !state.closing, !state.unloading else {
            throw OmniXPCFailure.error(.busy, "The Silero model is retiring.")
        }
        return model
    }

    func prepare(
        timeout: Duration = .seconds(240), cleanupTimeout: Duration = .seconds(60)
    ) async throws -> OmniXPCSileroModelReference {
        try Task.checkCancellation()
        guard timeout > .zero, cleanupTimeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "Silero preparation and cleanup timeouts must be positive.")
        }
        guard !isClosing, !isClosed, preparation == nil, command == nil, ownedPermit == nil else {
            throw OmniXPCFailure.error(.busy, "Complete this Silero owner's pending work or cleanup before preparation.")
        }
        if model != nil { return try requirePreparedModel() }
        let ticket = OmniXPCSileroLoadOwnership(client: client)
        loadOwnership = ticket
        let preparation = Task { @MainActor in
            defer { self.preparation = nil }
            do {
                self.ownedPermit = try await self.coordinator.reserveOwnedPermit(.fileASR)
                let authorized = try self.client.authorizedSileroModelDirectory(self.modelDirectory)
                let lease = try await ModelDiskOperations.perform {
                    let lease = try OmniModelDirectoryLease.acquire(for: authorized.directory, mode: .sharedRead)
                    let canonical = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: authorized.relativePath, container: authorized.container
                    )
                    guard canonical.path == lease.directory.path else {
                        throw OmniXPCFailure.error(.invalidRequest, "The Silero directory changed during reader acquisition.")
                    }
                    try OmniModelArtifactValidation.validateSafetensorsDirectory(at: lease.directory)
                    let validated = try OmniXPCRequestValidation.modelDirectory(
                        relativePath: authorized.relativePath, container: authorized.container
                    )
                    guard validated.path == lease.directory.path else {
                        throw OmniXPCFailure.error(.invalidRequest, "The Silero directory changed during structural validation.")
                    }
                    return lease
                }
                self.directoryLease = lease
                try Task.checkCancellation()
                let model = try await self.client.loadSilero(
                    modelDirectory: authorized.relativePath, timeout: timeout, cleanupTimeout: cleanupTimeout,
                    operationID: ticket.operationID, ownership: ticket
                )
                self.model = model
                try Task.checkCancellation()
                guard !self.isClosing else { throw CancellationError() }
                try await self.releaseOwnedPermit()
                return model
            } catch {
                let cleanup = Task { @MainActor in try await self.retireResources(timeout: cleanupTimeout) }
                try await cleanup.value
                throw error
            }
        }
        self.preparation = preparation
        return try await withTaskCancellationHandler {
            let model = try await preparation.value
            if Task.isCancelled || isClosing {
                try await close(timeout: cleanupTimeout)
                throw CancellationError()
            }
            return model
        } onCancel: {
            preparation.cancel()
        }
    }

    func speechTimestamps(
        samples16k: [Float], settings: OmniXPCSileroSettings, timeout: Duration = .seconds(240)
    ) async throws -> [Range<Int>] {
        let model = try requirePreparedModel()
        try settings.validate()
        guard !samples16k.isEmpty, samples16k.count <= OmniXPCProtocolLimits.maximumSampleCount,
              samples16k.allSatisfy(\.isFinite) else {
            throw OmniXPCFailure.error(.invalidRequest, "Silero offline audio requires at most 30 seconds of finite mono 16 kHz samples.")
        }
        return try await performOwnedCommand(.fileASR, timeout: timeout) {
            try await self.client.sileroSpeechTimestamps(samples16k: samples16k, settings: settings, model: model, timeout: timeout)
        }
    }

    func openStream(timeout: Duration = .seconds(30)) async throws -> OmniXPCSileroStreamReference {
        let model = try requirePreparedModel()
        guard streams.count < OmniXPCSileroLimits.maximumStreamCount else {
            throw OmniXPCFailure.error(.busy, "The Silero owner already has sixteen streams.")
        }
        return try await performOwnedCommand(.liveASRFeed, timeout: timeout) {
            let reference = try await self.client.startSileroStream(model: model, timeout: timeout)
            self.streams[reference.streamID] = reference
            return reference
        }
    }

    func pushAudio(
        _ audio: Data, to reference: OmniXPCSileroStreamReference, sequence: Int, timeout: Duration = .seconds(30)
    ) async throws -> OmniXPCSileroProbabilityBatch {
        try requireStream(reference)
        guard let stream = client.sileroStreams[reference.streamID], stream.reference == reference else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream has no matching command scope.")
        }
        _ = try stream.validateAudio(audio: audio, sequence: sequence)
        return try await performOwnedCommand(.liveASRFeed, timeout: timeout) {
            try await self.client.pushSileroAudio(audio, to: reference, sequence: sequence, timeout: timeout)
        }
    }

    func finishStream(
        _ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(60)
    ) async throws -> OmniXPCSileroProbabilityBatch {
        try requireStream(reference)
        return try await performOwnedCommand(.liveASRFeed, timeout: timeout) {
            let batch = try await self.client.finishSileroStream(reference, timeout: timeout)
            self.streams.removeValue(forKey: reference.streamID)
            return batch
        }
    }

    func closeStream(_ reference: OmniXPCSileroStreamReference, timeout: Duration = .seconds(60)) async throws {
        if let cleanup = streamClosures[reference.streamID], streams[reference.streamID] == reference {
            return try await cleanup.value
        }
        try requireStream(reference)
        // Note (assistant): caller cancellation must not cancel an entrusted stream's retirement barrier.
        let cleanup = Task { @MainActor in
            defer { self.streamClosures.removeValue(forKey: reference.streamID) }
            if self.isClosing {
                try await self.close(timeout: timeout)
            } else {
                try await self.performOwnedCommand(.modelCleanup, timeout: timeout) {
                    try await self.client.closeSileroStream(reference, timeout: timeout)
                    self.streams.removeValue(forKey: reference.streamID)
                }
            }
        }
        streamClosures[reference.streamID] = cleanup
        try await cleanup.value
    }

    /// Permanent terminal state; failed barriers retain all claims for an explicit same-scope retry.
    func close(timeout: Duration = .seconds(60)) async throws {
        if isClosed { return }
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero cleanup timeout must be positive.")
        }
        if let closing { return try await closing.value }
        isClosing = true
        let closing = Task { @MainActor in
            defer { self.closing = nil }
            if let preparation = self.preparation {
                preparation.cancel()
                _ = await preparation.result
            }
            if let command = self.command {
                command.cancel()
                await command.settled.value
            }
            if let ticket = self.loadOwnership, case .submitted = ticket.phase, self.ownedPermit == nil {
                self.ownedPermit = try await self.coordinator.reserveOwnedPermit(.modelCleanup)
            }
            try await self.retireResources(timeout: timeout)
            self.isClosed = true
        }
        self.closing = closing
        try await closing.value
    }

    private func requireStream(_ reference: OmniXPCSileroStreamReference) throws {
        let model = try requirePreparedModel()
        guard reference.model == model, streams[reference.streamID] == reference else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream is not entrusted to this owner.")
        }
    }

    private func performOwnedCommand<Value: Sendable>(
        _ workClass: MeetingLocalInferenceWorkClass, timeout: Duration,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero command timeout must be positive.")
        }
        guard command == nil, preparation == nil, ownedPermit == nil, !isClosing, !isClosed else {
            throw OmniXPCFailure.error(.busy, "The Silero owner has a pending command or retirement.")
        }
        let identity = UUID()
        let exchange = Task { @MainActor in
            self.ownedPermit = try await self.coordinator.reserveOwnedPermit(workClass)
            do {
                try Task.checkCancellation()
                guard !self.isClosing else { throw CancellationError() }
                let value = try await operation()
                try Task.checkCancellation()
                guard !self.isClosing else { throw CancellationError() }
                try await self.releaseOwnedPermit()
                return value
            } catch {
                // Note (assistant): ambiguous synchronous work keeps its lane until original-load drain succeeds.
                let cleanup = Task { @MainActor in try await self.retireResources(timeout: timeout) }
                do {
                    try await cleanup.value
                } catch {
                    self.isClosing = true
                    throw error
                }
                self.isClosing = true
                throw error
            }
        }
        let settled = Task { @MainActor in
            _ = await exchange.result
            if self.command?.identity == identity { self.command = nil }
        }
        command = Command(identity: identity, cancel: { exchange.cancel() }, settled: settled)
        return try await withTaskCancellationHandler {
            let outcome = await exchange.result
            await settled.value
            let value = try outcome.get()
            if Task.isCancelled || isClosing || isClosed {
                try await close(timeout: timeout)
                throw CancellationError()
            }
            return value
        } onCancel: {
            exchange.cancel()
        }
    }

    private func retireResources(timeout: Duration) async throws {
        if let ticket = loadOwnership {
            try await client.retireSileroLoad(ticket, timeout: timeout)
            guard ticket.phase == .notSubmitted || ticket.phase == .drained else {
                throw OmniXPCFailure.error(.nativeFailure, "Silero retirement is unknown.")
            }
        }
        model = nil
        streams.removeAll()
        directoryLease = nil
        try await releaseOwnedPermit()
    }

    private func releaseOwnedPermit() async throws {
        if let ownedPermit {
            try await coordinator.completeOwnedPermit(ownedPermit)
            self.ownedPermit = nil
        }
    }
}
#endif
