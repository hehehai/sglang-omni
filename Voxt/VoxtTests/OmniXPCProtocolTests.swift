import Foundation
import XCTest
@testable import Voxt

final class OmniXPCProtocolTests: XCTestCase {
    private var configuredInfo: [String: String] {
        [
            "OmniAppGroupIdentifier": "group.org.example.VoxtSmoke",
            "OmniInferenceServiceIdentifier": "org.example.VoxtSmoke.OmniInference",
            "OmniHostBundleIdentifier": "org.example.VoxtSmoke",
            "OmniTeamIdentifier": "ABCDEFGHIJ",
        ]
    }

    func testConfigurationUsesExplicitSharedSigningIdentity() throws {
        let configuration = try OmniXPCConfiguration(info: configuredInfo)
        XCTAssertEqual(configuration.appGroupIdentifier, configuredInfo["OmniAppGroupIdentifier"])
        XCTAssertEqual(configuration.teamIdentifier, "ABCDEFGHIJ")
        let requirement = try configuration.signingRequirement(for: configuration.serviceIdentifier)
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("identifier \"org.example.VoxtSmoke.OmniInference\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
        XCTAssertThrowsError(try configuration.signingRequirement(for: "org.example.Unrelated"))
    }

    func testHostAndServiceCannotShareSigningIdentifier() {
        var info = configuredInfo
        info["OmniInferenceServiceIdentifier"] = info["OmniHostBundleIdentifier"]
        XCTAssertThrowsError(try OmniXPCConfiguration(info: info))
    }

    func testMissingSigningConfigurationDoesNotUseFallbackIdentity() {
        for key in configuredInfo.keys {
            var incomplete = configuredInfo
            incomplete.removeValue(forKey: key)
            XCTAssertThrowsError(try OmniXPCConfiguration(info: incomplete))
        }
    }

    func testSigningConfigurationRejectsUnexpandedMacrosAndRequirementInjection() {
        for value in ["", "$(VOXT_OMNI_APP_GROUP_ID)", "../group", "group..example", "group.example.", "group\" or true", " group.example"] {
            var info = configuredInfo
            info["OmniAppGroupIdentifier"] = value
            XCTAssertThrowsError(try OmniXPCConfiguration(info: info))
        }
        for value in ["", "abc1234567", "ABCDEFGHIJK", "ABC DEFGHI", "$(DEVELOPMENT_TEAM)"] {
            var info = configuredInfo
            info["OmniTeamIdentifier"] = value
            XCTAssertThrowsError(try OmniXPCConfiguration(info: info))
        }
    }

    func testModelDirectoryMustExistInsideSharedModels() throws {
        try withContainer { container in
            let expected = container.appendingPathComponent("Models/model").resolvingSymlinksInPath().standardizedFileURL
            XCTAssertEqual(
                try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/model", container: container),
                expected
            )
            XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/missing", container: container))
        }
    }

    func testModelDirectoryRejectsAbsoluteTraversalEmptyAndOversizedPaths() throws {
        try withContainer { container in
            for path in ["", "/Models/model", "Models", "Models/", "Models//model", "Models/../model", "Models/model/..", "Models/./model", "Other/model", "Models/mo\0del", "Models/" + String(repeating: "a", count: 1024)] {
                XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: path, container: container))
            }
        }
    }

    func testModelDirectoryRejectsSymlinkEscape() throws {
        try withContainer { container in
            let outside = container.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: container.appendingPathComponent("Models/escape"), withDestinationURL: outside
            )
            XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/escape", container: container))
        }
    }

    func testModelsRootCannotRedirectOutsideAppGroup() throws {
        try withContainer { container in
            let outside = container.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: outside.appendingPathComponent("model"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.removeItem(at: container.appendingPathComponent("Models"))
            try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("Models"), withDestinationURL: outside)
            XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/model", container: container))
        }
    }

    func testNativeModelFileSymlinksCannotReadOutsideSharedModels() throws {
        try withContainer { container in
            let outside = container.appendingPathComponent("private-file")
            try Data("private".utf8).write(to: outside)
            for filename in ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "tokenizer.json", "weights.safetensors"] {
                let link = container.appendingPathComponent("Models/model").appendingPathComponent(filename)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/model", container: container))
                try FileManager.default.removeItem(at: link)
            }
        }
    }

    func testCaseVariantNativeFileCannotBypassContainmentOnInsensitiveVolume() throws {
        try withContainer { container in
            let model = container.appendingPathComponent("Models/model")
            let probe = model.appendingPathComponent("case-probe")
            try Data().write(to: probe)
            guard FileManager.default.fileExists(atPath: model.appendingPathComponent("CASE-PROBE").path) else {
                throw XCTSkip("This regression requires a case-insensitive filesystem")
            }
            try FileManager.default.removeItem(at: probe)
            let outside = container.appendingPathComponent("private-file")
            try Data("private".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: model.appendingPathComponent("CONFIG.JSON"), withDestinationURL: outside)
            XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/model", container: container))
        }
    }

    func testModelFilesCanLinkToSharedModelsCache() throws {
        try withContainer { container in
            let shared = container.appendingPathComponent("Models/shared-weights")
            try Data("weights".utf8).write(to: shared)
            try FileManager.default.createSymbolicLink(
                at: container.appendingPathComponent("Models/model/weights.safetensors"), withDestinationURL: shared
            )
            XCTAssertNoThrow(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/model", container: container))
        }
    }

    func testLittleEndianFloat32AudioPreservesCapturedSamples() throws {
        let samples: [Float] = [-1, 0, 0.25, 1]
        XCTAssertEqual(
            try OmniXPCRequestValidation.samples(audio: encoded(samples), language: "en", context: nil, maximumTokenCount: 128),
            samples
        )
    }

    func testAudioRejectsEmptyTruncatedAndOversizedMessages() {
        for audio in [Data(), Data([0, 1, 2]), Data(count: OmniXPCProtocolLimits.maximumAudioByteCount + 4)] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.samples(audio: audio, language: nil, context: nil, maximumTokenCount: 1))
        }
    }

    func testAudioRejectsNaNAndInfinityBeforeNativeCall() {
        for sample: Float in [.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.samples(audio: encoded([sample]), language: nil, context: nil, maximumTokenCount: 1))
        }
    }

    func testAudioRejectsInvalidTokenBudgetsAndCStringMetadata() {
        for budget in [0, -1, OmniXPCProtocolLimits.maximumTokenCount + 1] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.samples(audio: encoded([0]), language: nil, context: nil, maximumTokenCount: budget))
        }
        for language in ["en\0ignored", String(repeating: "a", count: OmniXPCProtocolLimits.maximumLanguageByteCount + 1)] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.samples(audio: encoded([0]), language: language, context: nil, maximumTokenCount: 1))
        }
        for context in ["prompt\0ignored", String(repeating: "a", count: OmniXPCProtocolLimits.maximumPromptByteCount + 1)] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.samples(audio: encoded([0]), language: nil, context: context, maximumTokenCount: 1))
        }
    }

    func testAudioAcceptsExactValidationLimits() throws {
        let audio = Data(count: OmniXPCProtocolLimits.maximumAudioByteCount)
        let samples = try OmniXPCRequestValidation.samples(
            audio: audio,
            language: String(repeating: "a", count: OmniXPCProtocolLimits.maximumLanguageByteCount),
            context: String(repeating: "b", count: OmniXPCProtocolLimits.maximumPromptByteCount),
            maximumTokenCount: OmniXPCProtocolLimits.maximumTokenCount
        )
        XCTAssertEqual(samples.count, OmniXPCProtocolLimits.maximumSampleCount)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }

    func testFinalSessionRequiresSequentialChunksAndDoesNotReplayRejectedAudio() throws {
        var session = try makeFinalSession()
        XCTAssertThrowsError(try session.append(audio: encoded([9]), sequence: 0))
        XCTAssertThrowsError(try session.append(audio: encoded([9]), sequence: 2))
        XCTAssertEqual(try session.append(audio: encoded([0.1]), sequence: 1), 1)
        XCTAssertThrowsError(try session.append(audio: encoded([9]), sequence: 1))
        XCTAssertEqual(try session.append(audio: encoded([0.2]), sequence: 2), 2)
        XCTAssertEqual(try session.beginFinish(), [Float(0.1), Float(0.2)])
        XCTAssertEqual(session.state, .finishing)
        XCTAssertTrue(session.complete(succeeded: true))
        XCTAssertEqual(session.state, .completed)
        XCTAssertFalse(session.complete(succeeded: true))
    }

    func testFinalSessionRejectsInvalidChunksWithoutAdvancingSequence() throws {
        var session = try makeFinalSession()
        for chunk in [Data(), Data([0]), encoded([.nan]), Data(count: OmniXPCProtocolLimits.maximumChunkAudioByteCount + 4)] {
            XCTAssertThrowsError(try session.append(audio: chunk, sequence: 1))
            XCTAssertEqual(session.lastAcceptedSequence, 0)
        }
        XCTAssertEqual(try session.append(audio: encoded([1]), sequence: 1), 1)
        XCTAssertEqual(try session.beginFinish(), [Float(1)])
    }

    func testFinalSessionBoundsTotalAudioNotJustIndividualMessages() throws {
        var session = try makeFinalSession()
        let chunk = Data(count: OmniXPCProtocolLimits.maximumChunkAudioByteCount)
        for sequence in 1...15 { _ = try session.append(audio: chunk, sequence: sequence) }
        XCTAssertThrowsError(try session.append(audio: encoded([0]), sequence: 16))
        XCTAssertEqual(session.lastAcceptedSequence, 15)
        XCTAssertEqual(try session.beginFinish().count, OmniXPCProtocolLimits.maximumSampleCount)
    }

    func testEmptyFinalSessionCannotFinishButCanReceiveMoreAudio() throws {
        var session = try makeFinalSession()
        XCTAssertThrowsError(try session.beginFinish())
        XCTAssertEqual(session.state, .receiving)
        _ = try session.append(audio: encoded([1]), sequence: 1)
        XCTAssertEqual(try session.beginFinish(), [Float(1)])
        XCTAssertThrowsError(try session.beginFinish())
    }

    func testCancelReceivingSessionIsTerminalAndIdempotent() throws {
        var session = try makeFinalSession()
        _ = try session.append(audio: encoded([1]), sequence: 1)
        XCTAssertTrue(session.cancel())
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertTrue(session.isTerminal)
        XCTAssertFalse(session.cancel())
        XCTAssertFalse(session.complete(succeeded: true))
        XCTAssertThrowsError(try session.append(audio: encoded([2]), sequence: 2))
        XCTAssertThrowsError(try session.beginFinish())
    }

    func testCancelFinishingSessionWaitsForNativeCompletionAndWinsSuccessRace() throws {
        var session = try makeFinalSession()
        _ = try session.append(audio: encoded([1]), sequence: 1)
        _ = try session.beginFinish()
        XCTAssertTrue(session.cancel())
        XCTAssertEqual(session.state, .cancelling)
        XCTAssertFalse(session.isTerminal)
        XCTAssertFalse(session.cancel())
        XCTAssertTrue(session.complete(succeeded: true))
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertTrue(session.isTerminal)
        XCTAssertFalse(session.complete(succeeded: false))
    }

    func testCompletionCannotHappenBeforeFinishAndCannotBeRewritten() throws {
        for succeeded in [true, false] {
            var session = try makeFinalSession()
            XCTAssertFalse(session.complete(succeeded: succeeded))
            _ = try session.append(audio: encoded([1]), sequence: 1)
            _ = try session.beginFinish()
            XCTAssertTrue(session.complete(succeeded: succeeded))
            XCTAssertEqual(session.state, succeeded ? .completed : .failed)
            XCTAssertTrue(session.isTerminal)
            XCTAssertFalse(session.cancel())
            XCTAssertFalse(session.complete(succeeded: !succeeded))
            XCTAssertThrowsError(try session.append(audio: encoded([2]), sequence: 2))
        }
    }

    func testFinalSessionKeepsExplicitModelAndSessionIdentity() throws {
        let modelID = UUID()
        let sessionID = UUID()
        let session = try OmniXPCFinalSessionBuffer(
            sessionID: sessionID, modelID: modelID, language: "en", context: "context", maximumTokenCount: 128
        )
        XCTAssertEqual(session.sessionID, sessionID)
        XCTAssertEqual(session.modelID, modelID)
        XCTAssertEqual(session.language, "en")
        XCTAssertEqual(session.context, "context")
        XCTAssertEqual(session.maximumTokenCount, 128)
        XCTAssertThrowsError(try OmniXPCFinalSessionBuffer(
            sessionID: sessionID, modelID: modelID, language: nil, context: nil, maximumTokenCount: 0
        ))
    }

    private func makeFinalSession() throws -> OmniXPCFinalSessionBuffer {
        try OmniXPCFinalSessionBuffer(sessionID: UUID(), modelID: UUID(), language: nil, context: nil, maximumTokenCount: 128)
    }

    private func encoded(_ samples: [Float]) -> Data {
        var audio = Data()
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { audio.append(contentsOf: $0) }
        }
        return audio
    }

    private func withContainer(_ body: (URL) throws -> Void) throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Models/model"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try body(container)
    }
}
