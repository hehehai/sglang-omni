/// Single-flight Qwen validation host backed directly by the Native C ABI.
import Foundation

#if os(macOS)
import Darwin

private struct QwenReply: Sendable {
    let text: String
    let language: String?
    let generatedTokenCount: Int
    let hitLengthLimit: Bool
}

private final class QwenCoreModel {
    private(set) var handle: OpaquePointer?

    init(directory: URL) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        handle = omni_qwen_create(directory.path, &errorMessage)
        defer { omni_string_free(errorMessage) }
        guard handle != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Qwen model could not be loaded.")
        }
    }

    func transcribe(samples: [Float], language: String?, context: String?, maximumTokenCount: Int) throws -> QwenReply {
        guard let handle else { throw OmniXPCFailure.error(.cancelled, "The Native Qwen model is closed.") }
        var result = OmniQwenResult()
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            omni_qwen_result_free(&result)
            omni_string_free(errorMessage)
        }
        let success = withOptionalCString(language) { languagePointer in
            withOptionalCString(context) { contextPointer in
                samples.withUnsafeBufferPointer { buffer in
                    omni_qwen_transcribe(
                        handle, buffer.baseAddress, buffer.count,
                        languagePointer, contextPointer, Int32(maximumTokenCount), &result, &errorMessage
                    )
                }
            }
        }
        guard success == 1, let textPointer = result.text,
              result.generated_token_count >= 0, Int(result.generated_token_count) <= maximumTokenCount,
              result.hit_length_limit == 0 || result.hit_length_limit == 1 else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Qwen transcription failed.")
        }
        return QwenReply(
            text: String(cString: textPointer),
            language: result.language.map { String(cString: $0) },
            generatedTokenCount: Int(result.generated_token_count),
            hitLengthLimit: result.hit_length_limit == 1
        )
    }

    private func withOptionalCString(_ value: String?, operation: (UnsafePointer<CChar>?) -> Int32) -> Int32 {
        if let value {
            return value.withCString(operation)
        } else {
            return operation(nil)
        }
    }

    func close() {
        if let handle {
            self.handle = nil
            omni_qwen_destroy(handle)
        }
    }

    deinit { close() }
}

private final class ConnectionLifetime: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var active = true

    var isActive: Bool { lock.withLock { active } }
    func invalidate() { lock.withLock { active = false } }
}

private final class OmniInferenceEngine: @unchecked Sendable {
    let configuration: OmniXPCConfiguration
    private let queue = DispatchQueue(label: "Voxt.Omni.XPC.inference")
    private let lock = NSLock()
    private var activeOwner: UUID?
    private var activeHandle: OpaquePointer?

    init(configuration: OmniXPCConfiguration) { self.configuration = configuration }

    func groupContainer() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            throw OmniXPCFailure.error(.configuration, "The XPC service cannot access its configured App Group.")
        }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    var isBusy: Bool { lock.withLock { activeOwner != nil } }

    func cancel(owner: UUID) {
        lock.withLock {
            if activeOwner == owner, let activeHandle { omni_qwen_cancel(activeHandle) }
        }
    }

    func transcribe(
        modelDirectory: String, audio: Data, language: String?, context: String?, maximumTokenCount: Int,
        lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (String?, String?, Int, Bool, NSError?) -> Void
    ) {
        let accepted = lock.withLock {
            if activeOwner == nil, lifetime.isActive {
                activeOwner = lifetime.id
                return true
            } else {
                return false
            }
        }
        guard accepted else {
            reply(nil, nil, 0, false, OmniXPCFailure.error(.busy, "The validation service already has an active request."))
            return
        }
        queue.async { [self] in
            var model: QwenCoreModel?
            let outcome: Result<QwenReply, Error>
            do {
                let directory = try OmniXPCRequestValidation.modelDirectory(
                    relativePath: modelDirectory, container: groupContainer()
                )
                let samples = try OmniXPCRequestValidation.samples(
                    audio: audio, language: language, context: context, maximumTokenCount: maximumTokenCount
                )
                guard lifetime.isActive else { throw OmniXPCFailure.error(.cancelled, "The XPC request was cancelled.") }
                let loaded = try QwenCoreModel(directory: directory)
                model = loaded
                lock.withLock { activeHandle = loaded.handle }
                guard lifetime.isActive else { throw OmniXPCFailure.error(.cancelled, "The XPC request was cancelled.") }
                outcome = .success(try loaded.transcribe(
                    samples: samples, language: language, context: context, maximumTokenCount: maximumTokenCount
                ))
            } catch {
                outcome = .failure(error)
            }
            lock.withLock { activeHandle = nil }
            model?.close()
            lock.withLock { activeOwner = nil }
            guard lifetime.isActive else { return }
            switch outcome {
            case .success(let result):
                reply(result.text, result.language, result.generatedTokenCount, result.hitLengthLimit, nil)
            case .failure(let error):
                reply(nil, nil, 0, false, error as NSError)
            }
        }
    }
}

private final class OmniInferenceSession: NSObject, OmniInferenceXPCProtocol {
    private let engine: OmniInferenceEngine
    private let lifetime: ConnectionLifetime

    init(engine: OmniInferenceEngine, lifetime: ConnectionLifetime) {
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

    func transcribeQwen(
        modelDirectory: String, audio: Data, language: String?, context: String?, maximumTokenCount: Int,
        withReply reply: @escaping @Sendable (String?, String?, Int, Bool, NSError?) -> Void
    ) {
        engine.transcribe(
            modelDirectory: modelDirectory, audio: audio, language: language, context: context,
            maximumTokenCount: maximumTokenCount, lifetime: lifetime, reply: reply
        )
    }

    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void) {
#if VOXT_OMNI_XPC_VALIDATION
        guard !engine.isBusy else {
            reply(OmniXPCFailure.error(.busy, "A running Native request cannot be interrupted by the diagnostic endpoint."))
            return
        }
        reply(nil)
        let replyDeliveryDelaySeconds = 0.1
        DispatchQueue.global().asyncAfter(deadline: .now() + replyDeliveryDelaySeconds) { exit(86) }
#else
        reply(OmniXPCFailure.error(.configuration, "The diagnostic endpoint is disabled."))
#endif
    }
}

final class OmniInferenceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: OmniInferenceEngine

    init(configuration: OmniXPCConfiguration) {
        engine = OmniInferenceEngine(configuration: configuration)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            connection.setCodeSigningRequirement(try engine.configuration.signingRequirement(
                for: engine.configuration.hostBundleIdentifier
            ))
            let lifetime = ConnectionLifetime()
            connection.exportedInterface = NSXPCInterface(with: OmniInferenceXPCProtocol.self)
            connection.exportedObject = OmniInferenceSession(engine: engine, lifetime: lifetime)
            connection.invalidationHandler = { [engine] in
                lifetime.invalidate()
                engine.cancel(owner: lifetime.id)
            }
            connection.resume()
            return true
        } catch {
            return false
        }
    }
}
#endif
