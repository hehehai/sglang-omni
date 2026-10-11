/// Opt-in validation client; production model routing is unchanged.
import Foundation

#if os(macOS)
nonisolated struct OmniXPCProbeResult: Equatable, Sendable {
    let abiVersion: Int
    let groupContainer: URL
    let serviceProcessIdentifier: Int32
}

@MainActor
final class OmniXPCClient {
    private struct Connection {
        let id: UUID
        let transport: NSXPCConnection
    }

    private struct Pending {
        let connectionID: UUID
        let timeout: Task<Void, Never>
        let fail: @MainActor (Error) -> Void
        let disconnectedSuccessfully: (@MainActor () -> Void)?
    }

    let configuration: OmniXPCConfiguration
    private var connection: Connection?
    private var pending: [UUID: Pending] = [:]

    init(bundle: Bundle = .main) throws {
        configuration = try OmniXPCConfiguration(bundle: bundle)
        guard bundle.bundleIdentifier == configuration.hostBundleIdentifier else {
            throw OmniXPCFailure.error(.configuration, "The validation host bundle identifier does not match its signing configuration.")
        }
    }

    func probe(timeout: Duration = .seconds(30)) async throws -> OmniXPCProbeResult {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let proxy = try begin(id: id, timeout: timeout, fail: { continuation.resume(throwing: $0) })
                    proxy.probe { [weak self] version, path, processIdentifier, error in
                        Task { @MainActor in
                            guard let self, self.take(id) != nil else { return }
                            do {
                                if let error { throw error }
                                guard version == OmniXPCProtocolLimits.abiVersion,
                                      processIdentifier > 0,
                                      processIdentifier != ProcessInfo.processInfo.processIdentifier,
                                      let expected = FileManager.default.containerURL(
                                        forSecurityApplicationGroupIdentifier: self.configuration.appGroupIdentifier
                                      ),
                                      expected.resolvingSymlinksInPath().standardizedFileURL.path
                                        == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path else {
                                    throw OmniXPCFailure.error(.incompatibleService, "The XPC service ABI, process or shared container is incompatible.")
                                }
                                continuation.resume(returning: OmniXPCProbeResult(
                                    abiVersion: version,
                                    groupContainer: expected,
                                    serviceProcessIdentifier: processIdentifier
                                ))
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                } catch {
                    fail(id, error: error, fallback: { continuation.resume(throwing: $0) })
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func transcribeQwen(
        modelDirectory: String,
        audio: Data,
        language: String?,
        context: String? = nil,
        maximumTokenCount: Int,
        timeout: Duration = .seconds(240)
    ) async throws -> ASRTranscriptionResult {
        try Task.checkCancellation()
        _ = try OmniXPCRequestValidation.samples(
            audio: audio, language: language, context: context, maximumTokenCount: maximumTokenCount
        )
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let proxy = try begin(id: id, timeout: timeout, fail: { continuation.resume(throwing: $0) })
                    proxy.transcribeQwen(
                        modelDirectory: modelDirectory, audio: audio, language: language,
                        context: context, maximumTokenCount: maximumTokenCount
                    ) { [weak self] text, resolvedLanguage, generatedTokenCount, hitLengthLimit, error in
                        Task { @MainActor in
                            guard let self, self.take(id) != nil else { return }
                            if let error {
                                continuation.resume(throwing: error)
                            } else if let text, generatedTokenCount >= 0, generatedTokenCount <= maximumTokenCount {
                                continuation.resume(returning: ASRTranscriptionResult(
                                    text: text,
                                    language: resolvedLanguage,
                                    languageProvenance: language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                        ? .requested : (resolvedLanguage == nil ? .unknown : .detected),
                                    generationMetadata: ASRGenerationMetadata(
                                        generatedTokenCount: generatedTokenCount, hitLengthLimit: hitLengthLimit
                                    )
                                ))
                            } else {
                                continuation.resume(throwing: OmniXPCFailure.error(.incompatibleService, "The XPC service returned an invalid transcription result."))
                            }
                        }
                    }
                } catch {
                    fail(id, error: error, fallback: { continuation.resume(throwing: $0) })
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    /// Completes only after the service disconnects, not after its diagnostic ACK.
    func terminateForValidation(timeout: Duration = .seconds(30)) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    let proxy = try begin(
                        id: id, timeout: timeout,
                        fail: { continuation.resume(throwing: $0) },
                        disconnectedSuccessfully: { continuation.resume() }
                    )
                    proxy.terminateForValidation { [weak self] error in
                        if let error {
                            Task { @MainActor in self?.fail(id, error: error) }
                        }
                    }
                } catch {
                    fail(id, error: error, fallback: { continuation.resume(throwing: $0) })
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func invalidate() {
        let transport = connection?.transport
        connection = nil
        let calls = Array(pending.values)
        pending.removeAll()
        transport?.invalidate()
        for call in calls {
            call.timeout.cancel()
            call.fail(OmniXPCFailure.error(.cancelled, "The XPC connection was closed."))
        }
    }

    private func connected() throws -> Connection {
        if let connection { return connection }
        let transport = NSXPCConnection(serviceName: configuration.serviceIdentifier)
        transport.remoteObjectInterface = NSXPCInterface(with: OmniInferenceXPCProtocol.self)
        transport.setCodeSigningRequirement(try configuration.signingRequirement(for: configuration.serviceIdentifier))
        let id = UUID()
        transport.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.disconnected(id) }
        }
        transport.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.disconnected(id) }
        }
        let state = Connection(id: id, transport: transport)
        connection = state
        transport.resume()
        return state
    }

    private func begin(
        id: UUID,
        timeout: Duration,
        fail: @escaping @MainActor (Error) -> Void,
        disconnectedSuccessfully: (@MainActor () -> Void)? = nil
    ) throws -> any OmniInferenceXPCProtocol {
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The XPC request timeout must be positive.")
        }
        let state = try connected()
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.pending[id] != nil else { return }
            self.fail(id, error: OmniXPCFailure.error(.timedOut, "The XPC request timed out."))
            self.invalidate()
        }
        pending[id] = Pending(
            connectionID: state.id, timeout: timer,
            fail: fail, disconnectedSuccessfully: disconnectedSuccessfully
        )
        guard let proxy = state.transport.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in
                guard let self, self.pending[id] != nil else { return }
                self.fail(id, error: error)
                self.disconnected(state.id)
            }
        }) as? any OmniInferenceXPCProtocol else {
            throw OmniXPCFailure.error(.incompatibleService, "The XPC service proxy is unavailable.")
        }
        return proxy
    }

    private func take(_ id: UUID) -> Pending? {
        let call = pending.removeValue(forKey: id)
        call?.timeout.cancel()
        return call
    }

    private func fail(_ id: UUID, error: Error, fallback: (@MainActor (Error) -> Void)? = nil) {
        if let call = take(id) {
            call.fail(error)
        } else {
            fallback?(error)
        }
    }

    private func cancel(_ id: UUID) {
        guard pending[id] != nil else { return }
        fail(id, error: CancellationError())
        invalidate()
    }

    private func disconnected(_ id: UUID) {
        guard connection?.id == id else { return }
        let transport = connection?.transport
        connection = nil
        transport?.invalidate()
        let ids = pending.filter { $0.value.connectionID == id }.map(\.key)
        for requestID in ids {
            guard let call = take(requestID) else { continue }
            if let success = call.disconnectedSuccessfully {
                success()
            } else {
                call.fail(OmniXPCFailure.error(.disconnected, "The XPC service disconnected."))
            }
        }
    }

    isolated deinit {
        connection?.transport.invalidate()
        for call in pending.values {
            call.timeout.cancel()
            call.fail(OmniXPCFailure.error(.cancelled, "The XPC client was released."))
        }
    }
}
#endif
