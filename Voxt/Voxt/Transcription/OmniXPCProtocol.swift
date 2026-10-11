/// Foundation-only configuration and bounded messages for the validation XPC service.
import Foundation

nonisolated enum OmniXPCProtocolLimits {
    static let abiVersion = 2
    static let sampleRate = 16_000
    static let maximumAudioSeconds = 30
    static let maximumSampleCount = sampleRate * maximumAudioSeconds
    static let maximumAudioByteCount = maximumSampleCount * MemoryLayout<UInt32>.size
    static let maximumChunkAudioByteCount = sampleRate * 2 * MemoryLayout<UInt32>.size
    static let maximumRequestsPerModel = 256
    static let maximumTokenCount = 4096
    static let maximumPromptByteCount = 16_384
    static let maximumLanguageByteCount = 128
    static let maximumModelPathByteCount = 1024
}

nonisolated enum OmniXPCFailure {
    enum Code: Int {
        case configuration = 1
        case invalidRequest
        case nativeFailure
        case busy
        case cancelled
        case timedOut
        case disconnected
        case incompatibleService
    }

    static func error(_ code: Code, _ message: String) -> NSError {
        NSError(domain: "Voxt.Omni.XPC", code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

nonisolated struct OmniXPCConfiguration: Equatable, Sendable {
    let appGroupIdentifier: String
    let serviceIdentifier: String
    let hostBundleIdentifier: String
    let teamIdentifier: String

    init(info: [String: String]) throws {
        func identifier(_ key: String) throws -> String {
            guard let value = info[key],
                  value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil,
                  !value.contains(".."), !value.hasSuffix(".") else {
                throw OmniXPCFailure.error(.configuration, "The XPC signing configuration is incomplete.")
            }
            return value
        }
        appGroupIdentifier = try identifier("OmniAppGroupIdentifier")
        serviceIdentifier = try identifier("OmniInferenceServiceIdentifier")
        hostBundleIdentifier = try identifier("OmniHostBundleIdentifier")
        guard hostBundleIdentifier != serviceIdentifier else {
            throw OmniXPCFailure.error(.configuration, "The XPC host and service must have distinct bundle identifiers.")
        }
        guard let team = info["OmniTeamIdentifier"],
              team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw OmniXPCFailure.error(.configuration, "The XPC signing team is not configured.")
        }
        teamIdentifier = team
    }

    init(bundle: Bundle) throws {
        var strings: [String: String] = [:]
        for key in ["OmniAppGroupIdentifier", "OmniInferenceServiceIdentifier", "OmniHostBundleIdentifier", "OmniTeamIdentifier"] {
            strings[key] = bundle.object(forInfoDictionaryKey: key) as? String
        }
        try self.init(info: strings)
    }

    func signingRequirement(for identifier: String) throws -> String {
        guard identifier == serviceIdentifier || identifier == hostBundleIdentifier else {
            throw OmniXPCFailure.error(.configuration, "The XPC peer identifier is not configured.")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

nonisolated enum OmniXPCRequestValidation {
    static func modelDirectory(relativePath: String, container: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard relativePath.utf8.count <= OmniXPCProtocolLimits.maximumModelPathByteCount,
              components.count >= 2, components.first == "Models",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw OmniXPCFailure.error(.invalidRequest, "The model must be inside the shared Models directory.")
        }
        let root = container.appendingPathComponent("Models", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = container.appendingPathComponent(relativePath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let resolvedContainer = container.resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(resolvedContainer.path + "/"),
              candidate.path.hasPrefix(root.path + "/") else {
            throw OmniXPCFailure.error(.invalidRequest, "The model directory is outside the shared Models directory.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OmniXPCFailure.error(.invalidRequest, "The shared model directory is not installed.")
        }
        let namesReadByQwen = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "tokenizer.json"]
        var files = try FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        for name in namesReadByQwen {
            let file = candidate.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
                files.append(file)
            }
        }
        for file in files {
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw OmniXPCFailure.error(.invalidRequest, "Model files must be regular files inside the shared Models directory.")
            }
        }
        return candidate
    }

    static func options(language: String?, context: String?, maximumTokenCount: Int) throws {
        guard maximumTokenCount > 0, maximumTokenCount <= OmniXPCProtocolLimits.maximumTokenCount,
              (language?.utf8.count ?? 0) <= OmniXPCProtocolLimits.maximumLanguageByteCount,
              (context?.utf8.count ?? 0) <= OmniXPCProtocolLimits.maximumPromptByteCount,
              language?.contains("\0") != true, context?.contains("\0") != true else {
            throw OmniXPCFailure.error(.invalidRequest, "The XPC transcription options exceed validation limits.")
        }
    }

    static func samples(audio: Data, language: String?, context: String?, maximumTokenCount: Int) throws -> [Float] {
        try options(language: language, context: context, maximumTokenCount: maximumTokenCount)
        guard !audio.isEmpty, audio.count <= OmniXPCProtocolLimits.maximumAudioByteCount,
              audio.count % MemoryLayout<UInt32>.size == 0 else {
            throw OmniXPCFailure.error(.invalidRequest, "The XPC audio message exceeds validation limits.")
        }
        let samples = audio.withUnsafeBytes { bytes in
            stride(from: 0, to: audio.count, by: MemoryLayout<UInt32>.size).map { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw OmniXPCFailure.error(.invalidRequest, "Audio samples must be finite Float32 values.")
        }
        return samples
    }
}

#if os(macOS)
@objc nonisolated protocol OmniInferenceXPCProtocol {
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void)
    func loadQwen(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    )
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func startFinalSession(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    )
    func pushFinalAudio(
        sessionID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Int, NSError?) -> Void
    )
    func finishFinalSession(
        sessionID: String, modelID: String,
        withReply reply: @escaping @Sendable (String?, String?, String?, String?, Int, Bool, NSError?) -> Void
    )
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void)
}
#endif
