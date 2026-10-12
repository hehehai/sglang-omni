/// Foundation-only configuration and bounded messages for the validation XPC service.
import Foundation

public nonisolated enum OmniXPCProtocolLimits {
    public static let abiVersion = 7
    public static let sampleRate = 16_000
    public static let maximumAudioSeconds = 30
    public static let maximumSampleCount = sampleRate * maximumAudioSeconds
    public static let maximumAudioByteCount = maximumSampleCount * MemoryLayout<UInt32>.size
    public static let maximumChunkAudioByteCount = sampleRate * 2 * MemoryLayout<UInt32>.size
    public static let maximumRequestsPerModel = 256
    public static let maximumTokenCount = 4096
    public static let maximumPromptByteCount = 16_384
    public static let maximumLanguageByteCount = 128
    public static let maximumModelPathByteCount = 1024
    public static let maximumRealtimeContextByteCount = 8192
    public static let maximumRealtimeEventsPerBatch = 16
    public static let maximumRealtimeBatchByteCount = 2 * 1024 * 1024
    public static let maximumRealtimeEventStringByteCount = 65_536
}

public nonisolated enum OmniXPCFailure {
    public enum Code: Int, Sendable {
        case configuration = 1
        case invalidRequest
        case nativeFailure
        case busy
        case cancelled
        case timedOut
        case disconnected
        case incompatibleService
    }

    public static func error(_ code: Code, _ message: String) -> NSError {
        NSError(domain: "Voxt.Omni.XPC", code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public nonisolated struct OmniXPCConfiguration: Equatable, Sendable {
    public let appGroupIdentifier: String
    public let serviceIdentifier: String
    public let hostBundleIdentifier: String
    public let teamIdentifier: String

    public init(info: [String: String]) throws {
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

    public init(bundle: Bundle) throws {
        var strings: [String: String] = [:]
        for key in ["OmniAppGroupIdentifier", "OmniInferenceServiceIdentifier", "OmniHostBundleIdentifier", "OmniTeamIdentifier"] {
            strings[key] = bundle.object(forInfoDictionaryKey: key) as? String
        }
        try self.init(info: strings)
    }

    public func signingRequirement(for identifier: String) throws -> String {
        guard identifier == serviceIdentifier || identifier == hostBundleIdentifier else {
            throw OmniXPCFailure.error(.configuration, "The XPC peer identifier is not configured.")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public nonisolated enum OmniXPCRequestValidation {
    public static func modelDirectory(relativePath: String, container: URL) throws -> URL {
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
        let modelFileNames = [
            "config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "tokenizer.json",
            "generation_config.json", "processor_config.json", "tokenizer.model", "weights.npz", "am.mvn"
        ]
        var files = try FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" || $0.pathExtension == "model" }
        for name in modelFileNames {
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

    public static func options(language: String?, context: String?, maximumTokenCount: Int) throws {
        guard maximumTokenCount > 0, maximumTokenCount <= OmniXPCProtocolLimits.maximumTokenCount,
              (language?.utf8.count ?? 0) <= OmniXPCProtocolLimits.maximumLanguageByteCount,
              (context?.utf8.count ?? 0) <= OmniXPCProtocolLimits.maximumPromptByteCount,
              language?.contains("\0") != true, context?.contains("\0") != true else {
            throw OmniXPCFailure.error(.invalidRequest, "The XPC transcription options exceed validation limits.")
        }
    }

    public static func realtimeOptions(language: String?, context: String?, maximumTokenCount: Int) throws {
        try options(language: language, context: context, maximumTokenCount: maximumTokenCount)
        guard (context?.utf8.count ?? 0) <= OmniXPCProtocolLimits.maximumRealtimeContextByteCount else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime context exceeds validation limits.")
        }
    }

    public static func samples(audio: Data, language: String?, context: String?, maximumTokenCount: Int) throws -> [Float] {
        try options(language: language, context: context, maximumTokenCount: maximumTokenCount)
        return try audioSamples(audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount)
    }

    public static func audioSamples(audio: Data, maximumSampleCount: Int) throws -> [Float] {
        guard (1...OmniXPCProtocolLimits.maximumSampleCount).contains(maximumSampleCount),
              !audio.isEmpty, audio.count <= maximumSampleCount * MemoryLayout<UInt32>.size,
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
@objc public nonisolated protocol OmniInferenceXPCProtocol {
    func probe(withReply reply: @escaping @Sendable (Int, String, Int32, NSError?) -> Void)
    func loadBatch(
        operationID: String, kind: Int, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    )
    func transcribeBatch(
        requestID: String, modelID: String, audio: Data, settings: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func cancelBatchRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func drainBatchLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func unloadBatch(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func loadQwen(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    )
    func unloadQwen(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func loadSilero(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    )
    func unloadSilero(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func sileroSpeechTimestamps(
        requestID: String, modelID: String, audio: Data, settings: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func startSileroStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    )
    func pushSileroAudio(
        streamID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func finishSileroStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func closeSileroStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    )
    func cancelSileroRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func loadSortformer(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    )
    func unloadSortformer(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func drainSortformerLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func startSortformerStream(
        streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    )
    func pushSortformerAudio(
        streamID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func finishSortformerStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    )
    func closeSortformerStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    )
    func cancelSortformerRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void)
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
    func startRealtimeSession(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int,
        withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    )
    func pushRealtimeAudio(
        sessionID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Int, NSError?) -> Void
    )
    func finishRealtimeSession(
        sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    )
    func pollRealtimeEvents(
        sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func closeRealtimeSession(
        sessionID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    )
    func cancelRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func terminateForValidation(withReply reply: @escaping @Sendable (NSError?) -> Void)
}
#endif
