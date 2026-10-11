/// Command-line validation entry for an explicitly signed XPC smoke build.
#if os(macOS)
import AppKit
import Darwin
import Foundation

#if VOXT_OMNI_XPC_VALIDATION
nonisolated private struct OmniXPCSmokeReport: Encodable {
    enum Status: String, Encodable { case prepared, passed, failed }
    let status: Status
    var groupContainer: String? = nil
    var abiVersion: Int? = nil
    var hostProcessIdentifier: Int32? = nil
    var serviceProcessIdentifier: Int32? = nil
    var firstServiceProcessIdentifier: Int32? = nil
    var restartedServiceProcessIdentifier: Int32? = nil
    var textCharacterCount: Int? = nil
    var generatedTokenCount: Int? = nil
    var elapsedSeconds: Double? = nil
    var errorDomain: String? = nil
    var errorCode: Int? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case groupContainer = "group_container"
        case abiVersion = "abi_version"
        case hostProcessIdentifier = "host_process_id"
        case serviceProcessIdentifier = "service_process_id"
        case firstServiceProcessIdentifier = "first_service_process_id"
        case restartedServiceProcessIdentifier = "restarted_service_process_id"
        case textCharacterCount = "text_character_count"
        case generatedTokenCount = "generated_token_count"
        case elapsedSeconds = "elapsed_seconds"
        case errorDomain = "error_domain"
        case errorCode = "error_code"
    }
}
#endif

extension AppDelegate {
    func maybeRunOmniXPCSmokeAndTerminate() -> Bool {
#if VOXT_OMNI_XPC_VALIDATION
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["VOXT_OMNI_XPC_SMOKE_MODE"] else { return false }
        Task { @MainActor in
            var client: OmniXPCClient?
            do {
                guard mode == "prepare" || mode == "infer" else {
                    throw OmniXPCFailure.error(.invalidRequest, "The XPC smoke mode must be prepare or infer.")
                }
                let connected = try OmniXPCClient()
                client = connected
                let probe = try await connected.probe()
                if mode == "prepare" {
                    try Self.emitOmniXPCSmokeResult(OmniXPCSmokeReport(
                        status: .prepared, groupContainer: probe.groupContainer.path,
                        abiVersion: probe.abiVersion,
                        hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                        serviceProcessIdentifier: probe.serviceProcessIdentifier
                    ))
                } else {
                    guard let rawID = environment["VOXT_OMNI_XPC_SMOKE_RUN_ID"], let id = UUID(uuidString: rawID) else {
                        throw OmniXPCFailure.error(.invalidRequest, "The XPC smoke run identifier is invalid.")
                    }
                    let timeoutSeconds = try Self.omniSmokeInteger(
                        environment["VOXT_OMNI_XPC_SMOKE_TIMEOUT_SECONDS"], defaultValue: 240, maximum: 1800
                    )
                    let maximumTokenCount = try Self.omniSmokeInteger(
                        environment["VOXT_OMNI_XPC_SMOKE_MAX_TOKENS"], defaultValue: 128,
                        maximum: OmniXPCProtocolLimits.maximumTokenCount
                    )
                    let artifactDirectory = probe.groupContainer
                        .appendingPathComponent("OmniXPCSmoke", isDirectory: true)
                        .appendingPathComponent(id.uuidString, isDirectory: true)
                        .resolvingSymlinksInPath().standardizedFileURL
                    let root = probe.groupContainer.resolvingSymlinksInPath().standardizedFileURL
                    guard artifactDirectory.path.hasPrefix(root.path + "/") else {
                        throw OmniXPCFailure.error(.invalidRequest, "The smoke artifacts are outside the shared container.")
                    }
                    let audio = try Data(contentsOf: artifactDirectory.appendingPathComponent("audio.f32"))
                    let expected = try String(contentsOf: artifactDirectory.appendingPathComponent("expected.txt"), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !expected.isEmpty else {
                        throw OmniXPCFailure.error(.invalidRequest, "The smoke test requires an expected speech transcript.")
                    }
                    let modelDirectory = "Models/OmniXPCSmoke/\(id.uuidString)"
                    let language = environment["VOXT_OMNI_XPC_SMOKE_LANGUAGE"]
                    let started = Date()
                    let model = try await connected.loadQwen(modelDirectory: modelDirectory, timeout: .seconds(timeoutSeconds))
                    let cancelled = try await connected.startFinalSession(
                        model: model, language: language, maximumTokenCount: maximumTokenCount
                    )
                    let firstChunk = audio.prefix(OmniXPCProtocolLimits.maximumChunkAudioByteCount)
                    try await connected.pushFinalAudio(Data(firstChunk), to: cancelled, sequence: 1)
                    try await connected.cancelFinalSession(cancelled)
                    let result = try await connected.transcribeFinal(
                        model: model, audio: audio, language: language,
                        maximumTokenCount: maximumTokenCount, timeout: .seconds(timeoutSeconds)
                    )
                    try Self.validateOmniSmokeTranscript(result, expected: expected)
                    let reused = try await connected.transcribeFinal(
                        model: model, audio: audio, language: language,
                        maximumTokenCount: maximumTokenCount, timeout: .seconds(timeoutSeconds)
                    )
                    try Self.validateOmniSmokeTranscript(reused, expected: expected)
                    try await connected.unloadQwen(model)
                    try await connected.terminateForValidation()
                    let restarted = try await connected.probe()
                    guard restarted.serviceProcessIdentifier != probe.serviceProcessIdentifier else {
                        throw OmniXPCFailure.error(.incompatibleService, "The XPC service did not restart after the diagnostic exit.")
                    }
                    let recoveredModel = try await connected.loadQwen(
                        modelDirectory: modelDirectory, timeout: .seconds(timeoutSeconds)
                    )
                    let recovered = try await connected.transcribeFinal(
                        model: recoveredModel, audio: audio, language: language,
                        maximumTokenCount: maximumTokenCount, timeout: .seconds(timeoutSeconds)
                    )
                    try Self.validateOmniSmokeTranscript(recovered, expected: expected)
                    try await connected.unloadQwen(recoveredModel)
                    try Self.emitOmniXPCSmokeResult(OmniXPCSmokeReport(
                        status: .passed, abiVersion: restarted.abiVersion,
                        hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                        firstServiceProcessIdentifier: probe.serviceProcessIdentifier,
                        restartedServiceProcessIdentifier: restarted.serviceProcessIdentifier,
                        textCharacterCount: recovered.text.count,
                        generatedTokenCount: recovered.generationMetadata?.generatedTokenCount,
                        elapsedSeconds: Date().timeIntervalSince(started)
                    ))
                }
                connected.invalidate()
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                client?.invalidate()
                let failure = error as NSError
                try? Self.emitOmniXPCSmokeResult(OmniXPCSmokeReport(
                    status: .failed, errorDomain: failure.domain, errorCode: failure.code
                ))
                fflush(stdout)
                exit(EXIT_FAILURE)
            }
        }
        return true
#else
        return false
#endif
    }

#if VOXT_OMNI_XPC_VALIDATION
    private static func omniSmokeInteger(_ value: String?, defaultValue: Int, maximum: Int) throws -> Int {
        guard let value else { return defaultValue }
        guard let number = Int(value), number > 0, number <= maximum else {
            throw OmniXPCFailure.error(.invalidRequest, "The XPC smoke numeric option is invalid.")
        }
        return number
    }

    private static func validateOmniSmokeTranscript(_ result: ASRTranscriptionResult, expected: String) throws {
        guard result.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
              result.generationMetadata?.hitLengthLimit == false else {
            throw OmniXPCFailure.error(.nativeFailure, "The XPC smoke transcript did not match its fixture or hit the token limit.")
        }
    }

    private static func emitOmniXPCSmokeResult(_ report: OmniXPCSmokeReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(report)
        print("VOXT_OMNI_XPC_RESULT \(String(decoding: encoded, as: UTF8.self))")
    }
#endif
}
#endif
