/// Connection-scoped XPC entry points and shared admission for the Native validation host.
import Foundation
import OmniXPCContracts
import OmniModelArtifacts

#if os(macOS)
import Darwin

nonisolated enum OmniServiceIdentity {
    static let instanceID = UUID()

    static func modelDirectoryLease(relativePath: String, configuration: OmniXPCConfiguration) throws -> OmniModelDirectoryLease {
        let container = try groupContainer(configuration: configuration)
        let directory = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        let lease = try OmniModelDirectoryLease.acquire(for: directory, mode: .sharedRead)
        let checked = try OmniXPCRequestValidation.modelDirectory(relativePath: relativePath, container: container)
        guard checked.resolvingSymlinksInPath().standardizedFileURL.path == lease.directory.path else {
            throw OmniXPCFailure.error(.invalidRequest, "The shared model directory changed during lease acquisition.")
        }
        return lease
    }

    static func groupContainer(configuration: OmniXPCConfiguration) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            throw OmniXPCFailure.error(.configuration, "The XPC service cannot access its configured App Group.")
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }
}

nonisolated final class OmniServiceAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var isTerminating = false

    // note (assistant): Lock order is service admission -> engine -> model token; engines never acquire this lock.
    func admitLoad(_ admission: () throws -> Void) throws {
        try lock.withLock {
            guard !isTerminating else {
                throw OmniXPCFailure.error(.disconnected, "The XPC service is terminating.")
            }
            try admission()
        }
    }

    func reserveValidationTermination(
        engine: OmniFinalSessionEngine, lifetime: OmniConnectionLifetime,
        sileroEngine: OmniSileroInferenceEngine, sileroLifetime: OmniSileroInferenceEngine.ConnectionLifetime,
        sortformerEngine: OmniSortformerInferenceEngine, sortformerLifetime: OmniSortformerInferenceEngine.ConnectionLifetime,
        batchEngine: OmniBatchInferenceEngine? = nil
    ) throws {
        try lock.withLock {
            guard !isTerminating else {
                throw OmniXPCFailure.error(.disconnected, "The XPC service is terminating.")
            }
            try batchEngine?.requireValidationIdle()
            try sileroEngine.requireValidationIdle(lifetime: sileroLifetime)
            try sortformerEngine.requireValidationIdle(lifetime: sortformerLifetime)
            try engine.reserveValidationTermination(lifetime: lifetime)
            isTerminating = true
        }
    }
}

nonisolated final class OmniConnectionLifetime: @unchecked Sendable {
    enum OperationState {
        case active
        case cancelled
        case completed
    }

    let id = UUID()
    // note (assistant): The engine lock protects connection state and its bounded operation history.
    var isActive = true
    var operations: [UUID: OperationState] = [:]
    private var operationOrder: [UUID] = []

    func recordOperation(_ operationID: UUID) throws {
        guard operations[operationID] == nil else {
            throw OmniXPCFailure.error(.invalidRequest, "The operation ID has already been used.")
        }
        operationOrder.append(operationID)
        operations[operationID] = .active
        guard operationOrder.count > OmniXPCProtocolLimits.maximumRequestsPerModel else { return }
        let oldest = operationOrder.removeFirst()
        precondition(operations[oldest] != .active)
        operations.removeValue(forKey: oldest)
    }
}

nonisolated final class OmniInferenceSession: NSObject, OmniInferenceXPCProtocol {
    private let engine: OmniFinalSessionEngine
    private let lifetime: OmniConnectionLifetime
    private let sileroEngine: OmniSileroInferenceEngine
    private let sileroLifetime: OmniSileroInferenceEngine.ConnectionLifetime
    let sortformerEngine: OmniSortformerInferenceEngine
    let sortformerLifetime: OmniSortformerInferenceEngine.ConnectionLifetime
    let admission: OmniServiceAdmission
    let batchEngine: OmniBatchInferenceEngine
    let batchLifetime: OmniBatchInferenceEngine.ConnectionLifetime

    init(
        engine: OmniFinalSessionEngine, lifetime: OmniConnectionLifetime,
        sileroEngine: OmniSileroInferenceEngine, sileroLifetime: OmniSileroInferenceEngine.ConnectionLifetime,
        sortformerEngine: OmniSortformerInferenceEngine, sortformerLifetime: OmniSortformerInferenceEngine.ConnectionLifetime,
        admission: OmniServiceAdmission,
        batchEngine: OmniBatchInferenceEngine? = nil,
        batchLifetime: OmniBatchInferenceEngine.ConnectionLifetime = .init()
    ) {
        self.engine = engine
        self.lifetime = lifetime
        self.sileroEngine = sileroEngine
        self.sileroLifetime = sileroLifetime
        self.sortformerEngine = sortformerEngine
        self.sortformerLifetime = sortformerLifetime
        self.admission = admission
        self.batchEngine = batchEngine ?? OmniBatchInferenceEngine(configuration: engine.configuration)
        self.batchLifetime = batchLifetime
    }

    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void) {
        do {
            let version = Int(omni_core_abi_version())
            guard version == OmniXPCProtocolLimits.abiVersion else {
                throw OmniXPCFailure.error(.incompatibleService, "The Native Core ABI is incompatible.")
            }
            reply(version, try engine.groupContainer().path, ProcessInfo.processInfo.processIdentifier, nil)
        } catch {
            reply(0, "", ProcessInfo.processInfo.processIdentifier, error as NSError)
        }
    }

    func loadQwen(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) {
        do {
            try admission.admitLoad {
                try engine.admitLoad(
                    operationID: operationID, modelDirectory: modelDirectory, lifetime: lifetime, reply: reply
                )
            }
        } catch {
            reply(nil, nil, error as NSError)
        }
    }

    func loadSilero(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) {
        do {
            try admission.admitLoad {
                try sileroEngine.admitLoad(
                    operationID: operationID, modelDirectory: modelDirectory, lifetime: sileroLifetime, reply: reply
                )
            }
        } catch {
            reply(nil, nil, error as NSError)
        }
    }

    func unloadSilero(
        operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        sileroEngine.unload(operationID: operationID, modelID: modelID, lifetime: sileroLifetime, reply: reply)
    }

    func sileroSpeechTimestamps(
        requestID: String, modelID: String, audio: Data, settings: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        sileroEngine.speechTimestamps(
            requestID: requestID, modelID: modelID, audio: audio, settings: settings, lifetime: sileroLifetime, reply: reply
        )
    }

    func startSileroStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        sileroEngine.startStream(streamID: streamID, modelID: modelID, lifetime: sileroLifetime, reply: reply)
    }

    func pushSileroAudio(
        streamID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        sileroEngine.pushStream(
            streamID: streamID, modelID: modelID, sequence: sequence, audio: audio, lifetime: sileroLifetime, reply: reply
        )
    }

    func finishSileroStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        sileroEngine.finishStream(streamID: streamID, modelID: modelID, lifetime: sileroLifetime, reply: reply)
    }

    func closeSileroStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        sileroEngine.closeStream(streamID: streamID, modelID: modelID, lifetime: sileroLifetime, reply: reply)
    }

    func cancelSileroRequest(
        requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            try sileroEngine.cancel(requestID: requestID, modelID: modelID, lifetime: sileroLifetime)
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func unloadQwen(
        operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        engine.unload(operationID: operationID, modelID: modelID, lifetime: lifetime, reply: reply)
    }

    func startFinalSession(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        do {
            try engine.start(
                sessionID: sessionID, modelID: modelID, language: language, context: context,
                maximumTokenCount: maximumTokenCount, lifetime: lifetime
            )
            reply(OmniServiceIdentity.instanceID.uuidString, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func pushFinalAudio(
        sessionID: String, modelID: String, sequence: Int, audio: Data, withReply reply: @escaping @Sendable (Int, NSError?) -> Void
    ) {
        engine.push(
            sessionID: sessionID, modelID: modelID, sequence: sequence, audio: audio, lifetime: lifetime, reply: reply
        )
    }

    func finishFinalSession(
        sessionID: String, modelID: String,
        withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void
    ) {
        engine.finish(sessionID: sessionID, modelID: modelID, lifetime: lifetime, reply: reply)
    }

    func startRealtimeSession(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int,
        withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        engine.startRealtime(
            sessionID: sessionID, modelID: modelID, language: language, context: context,
            maximumTokenCount: maximumTokenCount, decodeIntervalSamples: decodeIntervalSamples,
            firstDecodeSamples: firstDecodeSamples, maximumSegmentSamples: maximumSegmentSamples,
            lifetime: lifetime, reply: reply
        )
    }

    func pushRealtimeAudio(
        sessionID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Int, NSError?) -> Void
    ) {
        engine.pushRealtime(
            sessionID: sessionID, modelID: modelID, sequence: sequence, audio: audio, lifetime: lifetime, reply: reply
        )
    }

    func finishRealtimeSession(
        sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        engine.finishRealtime(sessionID: sessionID, modelID: modelID, lifetime: lifetime, reply: reply)
    }

    func pollRealtimeEvents(
        sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        engine.pollRealtime(
            sessionID: sessionID, modelID: modelID, acknowledgedEventSequence: acknowledgedEventSequence,
            maximumEventCount: maximumEventCount, lifetime: lifetime, reply: reply
        )
    }

    func closeRealtimeSession(
        sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        engine.closeRealtime(sessionID: sessionID, modelID: modelID, lifetime: lifetime, reply: reply)
    }

    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try engine.cancel(requestID: requestID, modelID: modelID, lifetime: lifetime)
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }

    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) {
#if VOXT_OMNI_XPC_VALIDATION
        do {
            try admission.reserveValidationTermination(
                engine: engine, lifetime: lifetime, sileroEngine: sileroEngine, sileroLifetime: sileroLifetime,
                sortformerEngine: sortformerEngine, sortformerLifetime: sortformerLifetime, batchEngine: batchEngine
            )
            reply(nil)
            let replyDeliveryDelaySeconds = 0.1
            DispatchQueue.global().asyncAfter(deadline: .now() + replyDeliveryDelaySeconds) { exit(86) }
        } catch {
            reply(error as NSError)
        }
#else
        reply(OmniXPCFailure.error(.configuration, "The diagnostic endpoint is disabled."))
#endif
    }
}

nonisolated final class OmniInferenceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: OmniFinalSessionEngine
    private let sileroEngine: OmniSileroInferenceEngine
    private let sortformerEngine: OmniSortformerInferenceEngine
    private let batchEngine: OmniBatchInferenceEngine
    private let admission = OmniServiceAdmission()

    init(configuration: OmniXPCConfiguration) {
        engine = OmniFinalSessionEngine(configuration: configuration)
        sileroEngine = OmniSileroInferenceEngine(configuration: configuration)
        sortformerEngine = OmniSortformerInferenceEngine(configuration: configuration)
        batchEngine = OmniBatchInferenceEngine(configuration: configuration)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            connection.setCodeSigningRequirement(try engine.configuration.signingRequirement(
                for: engine.configuration.hostBundleIdentifier
            ))
            let lifetime = OmniConnectionLifetime()
            let sileroLifetime = OmniSileroInferenceEngine.ConnectionLifetime()
            let sortformerLifetime = OmniSortformerInferenceEngine.ConnectionLifetime()
            let batchLifetime = OmniBatchInferenceEngine.ConnectionLifetime()
            connection.exportedInterface = NSXPCInterface(with: OmniInferenceXPCProtocol.self)
            connection.exportedObject = OmniInferenceSession(
                engine: engine, lifetime: lifetime, sileroEngine: sileroEngine,
                sileroLifetime: sileroLifetime, sortformerEngine: sortformerEngine,
                sortformerLifetime: sortformerLifetime, admission: admission,
                batchEngine: batchEngine, batchLifetime: batchLifetime
            )
            connection.interruptionHandler = { [engine, sileroEngine, sortformerEngine, batchEngine] in
                batchEngine.disconnect(lifetime: batchLifetime)
                sortformerEngine.disconnect(lifetime: sortformerLifetime)
                sileroEngine.disconnect(lifetime: sileroLifetime)
                engine.disconnect(lifetime: lifetime)
            }
            connection.invalidationHandler = { [engine, sileroEngine, sortformerEngine, batchEngine] in
                batchEngine.disconnect(lifetime: batchLifetime)
                sortformerEngine.disconnect(lifetime: sortformerLifetime)
                sileroEngine.disconnect(lifetime: sileroLifetime)
                engine.disconnect(lifetime: lifetime)
            }
            connection.resume()
            return true
        } catch {
            return false
        }
    }
}
#endif
