/// Connection-scoped XPC entry points for the persistent Native Qwen validation host.
import Foundation
import OmniXPCContracts

#if os(macOS)
import Darwin

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

nonisolated private final class OmniInferenceSession: NSObject, OmniInferenceXPCProtocol {
    private let engine: OmniFinalSessionEngine
    private let lifetime: OmniConnectionLifetime

    init(engine: OmniFinalSessionEngine, lifetime: OmniConnectionLifetime) {
        self.engine = engine
        self.lifetime = lifetime
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
        engine.load(operationID: operationID, modelDirectory: modelDirectory, lifetime: lifetime, reply: reply)
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
            reply(OmniFinalSessionEngine.serviceInstanceID.uuidString, nil)
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
            try engine.reserveValidationTermination(lifetime: lifetime)
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

    init(configuration: OmniXPCConfiguration) {
        engine = OmniFinalSessionEngine(configuration: configuration)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            connection.setCodeSigningRequirement(try engine.configuration.signingRequirement(
                for: engine.configuration.hostBundleIdentifier
            ))
            let lifetime = OmniConnectionLifetime()
            connection.exportedInterface = NSXPCInterface(with: OmniInferenceXPCProtocol.self)
            connection.exportedObject = OmniInferenceSession(engine: engine, lifetime: lifetime)
            connection.interruptionHandler = { [engine] in engine.disconnect(lifetime: lifetime) }
            connection.invalidationHandler = { [engine] in engine.disconnect(lifetime: lifetime) }
            connection.resume()
            return true
        } catch {
            return false
        }
    }
}
#endif
