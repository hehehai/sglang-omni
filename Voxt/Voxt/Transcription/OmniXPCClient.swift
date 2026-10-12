/// Opt-in validation client; production model routing is unchanged.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated struct OmniXPCProbeResult: Equatable, Sendable {
    let abiVersion: Int
    let groupContainer: URL
    let serviceProcessIdentifier: Int32
}

@MainActor
final class OmniXPCClient {
    enum CancellationTarget { case qwen, silero, sortformer, batch }

    private struct Connection {
        let id: UUID
        let transport: NSXPCConnection
    }

    private struct Pending {
        let connectionID: UUID
        let nativeRequestID: String?
        let cancellationModelID: String?
        let cancellationTarget: CancellationTarget
        let resetConnectionOnCancel: Bool
        let timeout: Task<Void, Never>
        let fail: @MainActor (Error) -> Void
        let disconnectedSuccessfully: (@MainActor () -> Void)?
    }

    let configuration: OmniXPCConfiguration
    private var connection: Connection?
    private var pending: [UUID: Pending] = [:]
    var realtimeSession: OmniXPCRealtimeClientState?
    var sileroStreams: [UUID: OmniXPCSileroStreamState] = [:]
    var closedSileroStreams: [UUID: OmniXPCSileroStreamReference] = [:]
    var sortformerStreams: [UUID: OmniXPCSortformerStreamState] = [:]
    var closedSortformerStreams: [UUID: OmniXPCSortformerStreamReference] = [:]
    var sortformerModel: OmniXPCSortformerModelState?
    var closedSortformerModels: [UUID: OmniXPCSortformerModelReference] = [:]
    var pendingSortformerLoad: OmniXPCSortformerLoadState?
    var sortformerLoadCleanup: OmniXPCSortformerLoadCleanup?
    var batchModel: OmniXPCBatchLoadState?
    var pendingBatchLoad: OmniXPCBatchLoadState?
    var closedBatchModels: [UUID: OmniXPCBatchModelReference] = [:]
    var batchLoadIDs: Set<UUID> = []
    var closedBatchLoadIDs: Set<UUID> = []
    var connectionIdentifier: UUID? { connection?.id }

    func requireConnection(_ id: UUID) throws {
        guard connection?.id == id else {
            throw OmniXPCFailure.error(.invalidRequest, "The model reference belongs to a previous connection.")
        }
    }


    init(bundle: Bundle = .main) throws {
        configuration = try OmniXPCConfiguration(bundle: bundle)
        guard bundle.bundleIdentifier == configuration.hostBundleIdentifier else {
            throw OmniXPCFailure.error(.configuration, "The validation host bundle identifier does not match its signing configuration.")
        }
    }

    func probe(timeout: Duration = .seconds(30)) async throws -> OmniXPCProbeResult {
        try await perform(timeout: timeout) { proxy, resolve in
            proxy.probe { [configuration] version, path, processIdentifier, error in
                if let error {
                    resolve(.failure(error))
                } else if version == OmniXPCProtocolLimits.abiVersion,
                          processIdentifier > 0, processIdentifier != ProcessInfo.processInfo.processIdentifier,
                          let expected = FileManager.default.containerURL(
                            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
                          ),
                          expected.resolvingSymlinksInPath().standardizedFileURL.path
                            == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path {
                    resolve(.success(OmniXPCProbeResult(
                        abiVersion: version, groupContainer: expected, serviceProcessIdentifier: processIdentifier
                    )))
                } else {
                    resolve(.failure(OmniXPCFailure.error(.incompatibleService, "The XPC service ABI, process or shared container is incompatible.")))
                }
            }
        }
    }

    func perform<Value: Sendable>(
        timeout: Duration,
        requiredConnectionID: UUID? = nil,
        nativeRequestID: String? = nil,
        cancellationModelID: String? = nil,
        cancellationTarget: CancellationTarget = .qwen,
        resetConnectionOnCancel: Bool = false,
        invoke: @MainActor (any OmniInferenceXPCProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let proxy = try begin(
                        id: id, timeout: timeout, requiredConnectionID: requiredConnectionID, nativeRequestID: nativeRequestID,
                        cancellationModelID: cancellationModelID, resetConnectionOnCancel: resetConnectionOnCancel,
                        cancellationTarget: cancellationTarget, fail: { continuation.resume(throwing: $0) }
                    )
                    invoke(proxy) { [weak self] outcome in
                        Task { @MainActor in
                            guard let self, let call = self.take(id) else { return }
                            do {
                                try self.requireConnection(call.connectionID)
                                continuation.resume(with: outcome)
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

    /// Completes only after the service disconnects, not after its diagnostic ACK.
    func terminateForValidation(timeout: Duration = .seconds(30)) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    let proxy = try begin(
                        id: id, timeout: timeout, nativeRequestID: nil, cancellationModelID: nil, resetConnectionOnCancel: true,
                        fail: { continuation.resume(throwing: $0) },
                        disconnectedSuccessfully: { continuation.resume() }
                    )
                    proxy.terminateForValidation { [weak self] error in
                        if let error { Task { @MainActor in self?.fail(id, error: error) } }
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
        realtimeSession = nil
        sileroStreams.removeAll()
        closedSileroStreams.removeAll()
        sortformerStreams.removeAll()
        closedSortformerStreams.removeAll()
        sortformerModel = nil
        closedSortformerModels.removeAll()
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
        transport.interruptionHandler = { [weak self] in Task { @MainActor in self?.disconnected(id) } }
        transport.invalidationHandler = { [weak self] in Task { @MainActor in self?.disconnected(id) } }
        let state = Connection(id: id, transport: transport)
        connection = state
        transport.resume()
        return state
    }

    private func begin(
        id: UUID, timeout: Duration, requiredConnectionID: UUID? = nil,
        nativeRequestID: String?, cancellationModelID: String?, resetConnectionOnCancel: Bool,
        cancellationTarget: CancellationTarget = .qwen,
        fail: @escaping @MainActor (Error) -> Void,
        disconnectedSuccessfully: (@MainActor () -> Void)? = nil
    ) throws -> any OmniInferenceXPCProtocol {
        guard timeout > .zero else {
            throw OmniXPCFailure.error(.invalidRequest, "The XPC request timeout must be positive.")
        }
        if let requiredConnectionID { try requireConnection(requiredConnectionID) }
        let state = try connected()
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, let call = self.pending[id] else { return }
            let error = OmniXPCFailure.error(.timedOut, "The XPC request timed out.")
            if call.cancellationTarget != .qwen {
                self.cancel(id, error: error)
            } else {
                self.fail(id, error: error)
                self.invalidate()
            }
        }
        pending[id] = Pending(
            connectionID: state.id, nativeRequestID: nativeRequestID, cancellationModelID: cancellationModelID,
            cancellationTarget: cancellationTarget, resetConnectionOnCancel: resetConnectionOnCancel, timeout: timer,
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
        if let call = take(id) { call.fail(error) } else { fallback?(error) }
    }

    private func cancel(_ id: UUID, error: Error = CancellationError()) {
        guard let call = pending[id] else { return }
        if call.resetConnectionOnCancel {
            fail(id, error: error)
            invalidate()
            return
        }
        if let requestID = call.nativeRequestID, let state = connection, state.id == call.connectionID,
           let proxy = state.transport.remoteObjectProxyWithErrorHandler({ [weak self] _ in
               Task { @MainActor in self?.disconnected(call.connectionID) }
           }) as? any OmniInferenceXPCProtocol {
            switch call.cancellationTarget {
            case .qwen:
                proxy.cancelRequest(requestID: requestID, modelID: call.cancellationModelID) { _ in }
            case .silero:
                proxy.cancelSileroRequest(requestID: requestID, modelID: call.cancellationModelID) { _ in }
            case .sortformer:
                proxy.cancelSortformerRequest(requestID: requestID, modelID: call.cancellationModelID) { _ in }
            case .batch:
                proxy.cancelBatchRequest(requestID: requestID, modelID: call.cancellationModelID) { _ in }
            }
            fail(id, error: error)
        } else {
            fail(id, error: error)
        }
    }

    private func disconnected(_ id: UUID) {
        guard connection?.id == id else { return }
        let transport = connection?.transport
        connection = nil
        realtimeSession = nil
        sileroStreams.removeAll()
        closedSileroStreams.removeAll()
        transport?.invalidate()
        sortformerStreams.removeAll()
        closedSortformerStreams.removeAll()
        sortformerModel = nil
        closedSortformerModels.removeAll()
        let ids = pending.filter { $0.value.connectionID == id }.map(\.key)
        for requestID in ids {
            guard let call = take(requestID) else { continue }
            if let success = call.disconnectedSuccessfully { success() } else {
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
