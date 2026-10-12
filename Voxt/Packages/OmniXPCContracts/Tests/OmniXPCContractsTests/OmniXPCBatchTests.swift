import Foundation
import XCTest
@testable import OmniXPCContracts

final class OmniXPCBatchTests: XCTestCase {
    func testAllDefaultsAndPrecisionRoundTrip() throws {
        for kind in OmniXPCBatchKind.allCases {
            let settings = OmniXPCBatchSettings.defaults(for: kind)
            XCTAssertEqual(settings.kind, kind)
            XCTAssertEqual(try OmniXPCBatchSettings.decode(settings.encoded()), settings)
        }
        let settings: [OmniXPCBatchSettings] = [
            .whisper(language: "", maximumTokenCount: 4096, temperature: Float(0.12345678)),
            .cohere(language: "zh", usePunctuation: false, maximumTokenCount: 2, temperature: 0.1,
                    chunkDurationSeconds: 12.125, minimumChunkDurationSeconds: 0.125),
            .moss(prompt: "", maximumTokenCount: 0, stopAtEndOfText: true, stopOnTokenLoop: true),
            .nemotron(language: "", chunkFrameCount: 4096), .parakeet(chunkDurationSeconds: 2.123456789012345),
            .sensevoice(language: "", useInverseTextNormalization: true)
        ]
        for value in settings { XCTAssertEqual(try OmniXPCBatchSettings.decode(value.encoded()), value) }
        XCTAssertNotEqual(OmniXPCBatchSettings.moss(), .moss(prompt: "", maximumTokenCount: 0))
        XCTAssertNotEqual(OmniXPCBatchSettings.nemotron(), .nemotron(language: ""))
    }

    func testInvalidSettingsAndStrictUnionDecode() throws {
        let invalid: [OmniXPCBatchSettings] = [
            .whisper(maximumTokenCount: -1), .whisper(temperature: .nan), .whisper(temperature: -.infinity),
            .whisper(language: "en\0"), .whisper(language: String(repeating: "x", count: 129)),
            .cohere(chunkDurationSeconds: 0), .cohere(chunkDurationSeconds: 1201),
            .cohere(chunkDurationSeconds: 1, minimumChunkDurationSeconds: 2),
            .cohere(minimumChunkDurationSeconds: 31), .cohere(temperature: -1),
            .moss(prompt: String(repeating: "x", count: 8193)), .moss(maximumTokenCount: -1),
            .nemotron(chunkFrameCount: 0), .nemotron(chunkFrameCount: 4097),
            .parakeet(chunkDurationSeconds: 1), .parakeet(chunkDurationSeconds: 301),
            .parakeet(chunkDurationSeconds: 1201), .parakeet(chunkDurationSeconds: .infinity)
        ]
        for value in invalid { XCTAssertThrowsError(try value.encoded()) }
        for json in [
            #"{"kind":1,"language":null,"maximumTokenCount":0,"temperature":0,"prompt":"x"}"#,
            #"{"kind":1,"maximumTokenCount":0,"temperature":0}"#,
            #"{"kind":6,"language":null,"useInverseTextNormalization":1}"#,
            #"{"kind":2,"language":null,"maximumTokenCount":0,"temperature":0}"#,
            #"{"kind":100,"chunkDurationSeconds":1200}"#,
            #"{"kind":4,"language":null,"chunkFrameCount":1.5}"#
        ] { XCTAssertThrowsError(try OmniXPCBatchSettings.decode(Data(json.utf8))) }
        XCTAssertThrowsError(try OmniXPCBatchSettings.decode(Data(repeating: 32, count: 65_537)))
    }

    func testAllMetadataAndEmptyVersusAbsentRoundTrip() throws {
        let segment = try OmniXPCBatchSegment(startSeconds: 0.125, endSeconds: 1.75, text: "你好",
                                              speaker: "", language: nil, emotion: "", event: "speech")
        let result = try OmniXPCBatchResult(serviceInstanceID: UUID(), modelID: UUID(), requestID: UUID(), kind: .moss,
                                            text: "héllo 世界", language: "", generatedTokenCount: 3,
                                            finishReason: .length, segments: [segment])
        XCTAssertEqual(try OmniXPCBatchResult.decode(result.encoded()), result)
        XCTAssertEqual(result.segments[0].speaker, "")
        XCTAssertNil(result.segments[0].language)
        XCTAssertEqual(result.segments[0].emotion, "")
    }

    func testResultCountersStringsAndAggregateBudgets() throws {
        let segment = try OmniXPCBatchSegment(startSeconds: 0, endSeconds: 30,
                                              text: String(repeating: "x", count: 65_536),
                                              speaker: nil, language: nil, emotion: nil, event: nil)
        func result(text: String = "", tokens: Int = 0, segments: [OmniXPCBatchSegment] = []) throws -> OmniXPCBatchResult {
            try OmniXPCBatchResult(serviceInstanceID: UUID(), modelID: UUID(), requestID: UUID(), kind: .whisper,
                                   text: text, language: nil, generatedTokenCount: tokens, finishReason: .stop, segments: segments)
        }
        XCTAssertNoThrow(try result(text: String(repeating: "x", count: 65_536), tokens: 4096))
        XCTAssertThrowsError(try result(tokens: 4097))
        XCTAssertThrowsError(try result(tokens: -1))
        XCTAssertThrowsError(try result(text: "\0"))
        XCTAssertThrowsError(try result(text: String(repeating: "x", count: 65_537)))
        XCTAssertThrowsError(try result(segments: Array(repeating: segment, count: 4)))
        let empty = try OmniXPCBatchSegment(startSeconds: 0, endSeconds: 0, text: "", speaker: nil,
                                            language: nil, emotion: nil, event: nil)
        XCTAssertNoThrow(try result(segments: Array(repeating: empty, count: 512)))
        XCTAssertThrowsError(try result(segments: Array(repeating: empty, count: 513)))
        for (start, end) in [(Double.nan, 1), (0, Double.infinity), (-1, 0), (2, 1)] {
            XCTAssertThrowsError(try OmniXPCBatchSegment(startSeconds: start, endSeconds: end, text: "",
                                                        speaker: nil, language: nil, emotion: nil, event: nil))
        }
    }

    func testMalformedResultsRejectUnknownMissingAndInvalidFields() throws {
        let result = try OmniXPCBatchResult(serviceInstanceID: UUID(), modelID: UUID(), requestID: UUID(), kind: .whisper,
                                            text: "", language: nil, generatedTokenCount: 0, finishReason: .stop, segments: [])
        let bytes = try result.encoded()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (field, replacement): (String, Any) in [
            ("generatedTokenCount", -1), ("finishReason", 8), ("kind", 0), ("serviceInstanceID", "x"),
            ("extra", 1), ("segments", [["startSeconds": 0, "endSeconds": 1, "text": ""]])
        ] {
            var invalid = original
            invalid[field] = replacement
            XCTAssertThrowsError(try OmniXPCBatchResult.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        var missing = original
        missing.removeValue(forKey: "language")
        XCTAssertThrowsError(try OmniXPCBatchResult.decode(JSONSerialization.data(withJSONObject: missing)))
        XCTAssertThrowsError(try OmniXPCBatchResult.decode(Data(repeating: 32, count: 2 * 1024 * 1024 + 1)))
    }

    func testEveryAdditionalNativeModelFileIsNamespaceChecked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Models/batch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try Data("fixture".utf8).write(to: outside)
        for name in ["generation_config.json", "processor_config.json", "tokenizer.model", "custom.model", "weights.npz", "am.mvn"] {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            XCTAssertThrowsError(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/batch", container: root), name)
            try FileManager.default.removeItem(at: file)
            try Data().write(to: file)
            XCTAssertEqual(try OmniXPCRequestValidation.modelDirectory(relativePath: "Models/batch", container: root).path, directory.path)
            try FileManager.default.removeItem(at: file)
        }
    }

    func testNativeFailureStatusDistinctionsAreSanitized() {
        for rawValue in 1...6 {
            let error = OmniXPCBatchFailure.error(OmniXPCBatchFailure.Code(rawValue: rawValue)!)
            XCTAssertEqual(error.domain, "Voxt.Omni.XPC.Batch")
            XCTAssertEqual(error.code, rawValue)
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
    }
}
