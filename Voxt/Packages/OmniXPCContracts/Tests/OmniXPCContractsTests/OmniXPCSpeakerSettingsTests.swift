import Foundation
import OmniXPCContracts
import XCTest

final class OmniXPCSpeakerSettingsTests: XCTestCase {
    func testBothFamilyDefaultsMatchNativeAbsenceAndExactFields() throws {
        XCTAssertEqual(OmniXPCSpeakerSettings.defaults(for: .moss), .moss(prompt: nil))
        XCTAssertEqual(OmniXPCSpeakerSettings.defaults(for: .nemotron), .nemotron(language: nil, chunkMilliseconds: nil))
        for kind in OmniXPCSpeakerKind.allCases {
            let settings = OmniXPCSpeakerSettings.defaults(for: kind)
            XCTAssertEqual(settings.kind, kind)
            XCTAssertEqual(try OmniXPCSpeakerSettings.decode(settings.encoded()), settings)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.encoded()) as? [String: Any])
            let expected: Set<String> = kind == .moss ? ["kind", "prompt"] : ["kind", "language", "chunkMilliseconds"]
            XCTAssertEqual(Set(fields.keys), expected)
            for field in expected.subtracting(["kind"]) { XCTAssertTrue(fields[field] is NSNull) }
            XCTAssertNoThrow(try settings.validate(for: SpeakerTestValues.model(kind)))
            XCTAssertThrowsError(try settings.validate(for: SpeakerTestValues.model(kind == .moss ? .nemotron : .moss)))
        }
        XCTAssertNotEqual(OmniXPCSpeakerSettings.moss(), .moss(prompt: ""))
        XCTAssertNotEqual(OmniXPCSpeakerSettings.nemotron(), .nemotron(language: ""))
    }

    func testPromptActualPlaceholderRuleAndUTF8ByteBoundaries() throws {
        for prompt in [nil, "", "<|audio_pad|>", "prefix <|audio_pad|> suffix", "<|audio_pad| <|audio_pad|>",
                       String(repeating: "é", count: 4096)] {
            let settings = OmniXPCSpeakerSettings.moss(prompt: prompt)
            XCTAssertEqual(try OmniXPCSpeakerSettings.decode(settings.encoded()), settings)
        }
        for prompt in ["<|audio_pad|><|audio_pad|>", "x<|audio_pad|>y<|audio_pad|>z", "\0",
                       String(repeating: "é", count: 4096) + "a"] {
            XCTAssertThrowsError(try OmniXPCSpeakerSettings.moss(prompt: prompt).encoded())
            let bytes = try JSONSerialization.data(withJSONObject: ["kind": 1, "prompt": prompt])
            XCTAssertThrowsError(try OmniXPCSpeakerSettings.decode(bytes))
        }
    }

    func testNemotronPreservesOptionalDoubleWithoutPresetRounding() throws {
        let durations: [Double?] = [nil, .leastNonzeroMagnitude, 0.123456789012345, 559.999999999, 560.000000001, 120_000]
        for duration in durations {
            for language in [nil, "", "en", String(repeating: "é", count: 64)] {
                let settings = OmniXPCSpeakerSettings.nemotron(language: language, chunkMilliseconds: duration)
                XCTAssertEqual(try OmniXPCSpeakerSettings.decode(settings.encoded()), settings)
            }
        }
        for duration in [Double.nan, .infinity, -.infinity, -1, 0, -0.0, 120_000.nextUp] {
            let settings = OmniXPCSpeakerSettings.nemotron(chunkMilliseconds: duration)
            XCTAssertThrowsError(try settings.validate())
            XCTAssertThrowsError(try settings.encoded())
        }
        for language in ["en\0ignored", String(repeating: "é", count: 64) + "a"] {
            XCTAssertThrowsError(try OmniXPCSpeakerSettings.nemotron(language: language).encoded())
            let bytes = try JSONSerialization.data(withJSONObject: ["kind": 2, "language": language, "chunkMilliseconds": NSNull()])
            XCTAssertThrowsError(try OmniXPCSpeakerSettings.decode(bytes))
        }
    }

    func testStrictFamilyUnionRejectsUnknownMissingWrongKindAndWrongTypes() {
        for json in [
            #"{"kind":1}"#, #"{"prompt":null}"#, #"{"kind":2,"language":null}"#,
            #"{"kind":2,"chunkMilliseconds":null}"#, #"{"kind":0,"prompt":null}"#,
            #"{"kind":3,"prompt":null}"#, #"{"kind":true,"prompt":null}"#,
            #"{"kind":1,"prompt":false}"#, #"{"kind":1,"prompt":null,"language":null}"#,
            #"{"kind":1,"prompt":null,"chunkMilliseconds":null}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":null,"prompt":null}"#,
            #"{"kind":2,"language":0,"chunkMilliseconds":null}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":true}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":"1"}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":0}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":120001}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":1e999}"#,
            #"{"kind":2,"language":null,"chunkMilliseconds":null,"hasChunk":0}"#,
            #"{"kind":1,"prompt":null,"moss":{}}"#, "", "null", "[]", "{}", "{", "{}{}"
        ] { XCTAssertThrowsError(try OmniXPCSpeakerSettings.decode(Data(json.utf8)), json) }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        for literal in ["Inf", "-Inf", "NaN"] {
            let json = "{\"kind\":2,\"language\":null,\"chunkMilliseconds\":\"\(literal)\"}"
            XCTAssertThrowsError(try decoder.decode(OmniXPCSpeakerSettings.self, from: Data(json.utf8)))
        }
    }

    func testSettingsByteAdmissionAndInvalidUTF8() throws {
        let settings = OmniXPCSpeakerSettings.moss(prompt: String(repeating: "\u{01}", count: 8192))
        XCTAssertEqual(try OmniXPCSpeakerSettings.decode(settings.encoded()), settings)
        var bytes = try settings.encoded()
        let limit = OmniXPCSpeakerLimits.maximumSettingsByteCount
        bytes.append(Data(repeating: 32, count: limit - bytes.count))
        XCTAssertEqual(try OmniXPCSpeakerSettings.decode(bytes), settings)
        bytes.append(32)
        XCTAssertThrowsError(try OmniXPCSpeakerSettings.decode(bytes))
        XCTAssertThrowsError(try OmniXPCSpeakerSettings.decode(Data([0xFF, 0xFE])))
        let invalidString = Data(#"{"kind":1,"prompt":""#.utf8) + Data([0xFF]) + Data(#""}"#.utf8)
        XCTAssertThrowsError(try OmniXPCSpeakerSettings.decode(invalidString))
    }
}
