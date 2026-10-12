import Foundation
import OmniXPCContracts
import XCTest

final class OmniXPCSpeakerEventTests: XCTestCase {
    func testBothFamiliesRoundTripTypedPreviewFinalAndTerminalEvents() throws {
        for kind in OmniXPCSpeakerKind.allCases {
            let session = try SpeakerTestValues.session(kind)
            let segment = try SpeakerTestValues.segment(text: "你好", speaker: "", language: nil, emotion: "", event: "speech")
            let events: [OmniXPCSpeakerEvent] = try [
                .init(session: session, eventSequence: 1, kind: .updated),
                .init(session: session, eventSequence: 2, kind: .segment, segmentID: 0, text: "", isFinal: false),
                .init(session: session, eventSequence: 3, kind: .segment, segmentID: 0, text: "hello", isFinal: true, segments: []),
                .init(session: session, eventSequence: 4, kind: .segment, segmentID: .max, text: "你好", isFinal: true, segments: [segment]),
                .init(session: session, eventSequence: 5, kind: .completed, text: "", segments: []),
                .init(session: session, eventSequence: 6, kind: .completed, text: "你好", segments: [segment]),
                .init(session: session, eventSequence: 7, kind: .cancelled, failureStatus: .cancelled),
                .init(session: session, eventSequence: .max, kind: .failed, failureStatus: .failed)
            ]
            for event in events { XCTAssertEqual(try OmniXPCSpeakerEvent.decode(event.encoded()), event) }
            let preview = try XCTUnwrap(JSONSerialization.jsonObject(with: events[1].encoded()) as? [String: Any])
            let final = try XCTUnwrap(JSONSerialization.jsonObject(with: events[2].encoded()) as? [String: Any])
            XCTAssertNil(preview["segments"])
            XCTAssertEqual((final["segments"] as? [Any])?.count, 0)
            let decodedSegment = try XCTUnwrap(OmniXPCSpeakerEvent.decode(events[3].encoded()).segments?.first)
            XCTAssertEqual(decodedSegment.startSeconds.bitPattern, segment.startSeconds.bitPattern)
            XCTAssertEqual(decodedSegment.endSeconds.bitPattern, segment.endSeconds.bitPattern)
            XCTAssertNotEqual(decodedSegment.startSeconds, Double(Float(segment.startSeconds)))
            XCTAssertEqual(decodedSegment.speaker, "")
            XCTAssertNil(decodedSegment.language)
            XCTAssertEqual(decodedSegment.emotion, "")
        }
        XCTAssertEqual(OmniXPCSpeakerEventKind.allCases.map(\.rawValue), [1, 2, 3, 4, 5])
    }

    func testNativeTerminalStatusesAreNotPollReturnCodesOrPrivateMessages() throws {
        let session = try SpeakerTestValues.session()
        for status in OmniXPCSpeakerStatus.allCases {
            if [.failed, .outOfMemory, .limit].contains(status) {
                let event = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .failed, failureStatus: status)
                XCTAssertEqual(try OmniXPCSpeakerEvent.decode(event.encoded()), event)
            } else {
                XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .failed, failureStatus: status))
            }
            if status != .cancelled {
                XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .cancelled, failureStatus: status))
            } else { }
            if status != .ok {
                XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .updated, failureStatus: status))
            } else { }
        }
        let failure = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .failed, failureStatus: .failed)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: failure.encoded()) as? [String: Any])
        fields["failureMessage"] = "/PRIVATE/model/path"
        XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: fields))) { error in
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
        fields.removeValue(forKey: "failureMessage")
        for invalidStatus in [-1, 0, 1, 2, 3, 7] {
            fields["failureStatus"] = invalidStatus
            XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testDirectConstructionRejectsIncompatiblePayloads() throws {
        let session = try SpeakerTestValues.session()
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 0, kind: .updated))
        for kind in [OmniXPCSpeakerEventKind.updated, .cancelled, .failed] {
            let status: OmniXPCSpeakerStatus = kind == .updated ? .ok : kind == .cancelled ? .cancelled : .failed
            XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: kind, text: "", failureStatus: status))
            XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: kind, isFinal: false, failureStatus: status))
            XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: kind, segments: [], failureStatus: status))
        }
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, text: "", isFinal: false))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, segmentID: -1, text: "", isFinal: false))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, segmentID: 0, isFinal: false))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, segmentID: 0, text: ""))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, segmentID: 0,
                                                   text: "", isFinal: false, segments: []))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, segmentID: 0,
                                                   text: "", isFinal: true))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed, text: ""))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed, text: "", isFinal: true, segments: []))
    }

    func testStrictWireShapesRequiredAbsentAndIntegerBoundaries() throws {
        let session = try SpeakerTestValues.session()
        let preview = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .segment, segmentID: 0, text: "", isFinal: false)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.encoded()) as? [String: Any])
        for (field, replacement): (String, Any) in [
            ("extra", 1), ("segmentID", -1), ("segmentID", 2_147_483_648), ("segmentID", true), ("segmentID", 0.5),
            ("isFinal", 1), ("isFinal", NSNull()), ("text", NSNull()), ("text", []), ("segments", []), ("segments", NSNull()),
            ("eventSequence", 0), ("eventSequence", -1), ("eventSequence", 1.5), ("eventSequence", true),
            ("kind", 0), ("kind", 6), ("kind", "segment"), ("kind", true), ("failureStatus", true)
        ] {
            var invalid = original
            invalid[field] = replacement
            XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: invalid)), field)
        }
        for field in original.keys {
            var missing = original
            missing.removeValue(forKey: field)
            XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: missing)), field)
        }
        let encoded = String(decoding: try preview.encoded(), as: UTF8.self)
        XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(Data(encoded.replacingOccurrences(
            of: "\"eventSequence\":1", with: "\"eventSequence\":18446744073709551616").utf8)))
        for kind in [OmniXPCSpeakerEventKind.updated, .cancelled, .failed, .completed] {
            let event = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: kind,
                                              text: kind == .completed ? "" : nil, segments: kind == .completed ? [] : nil,
                                              failureStatus: kind == .cancelled ? .cancelled : kind == .failed ? .failed : .ok)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: event.encoded()) as? [String: Any])
            for field in ["segmentID", "isFinal", "text", "segments"].filter({ fields[$0] == nil }) {
                var invalid = fields
                invalid[field] = NSNull()
                XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: invalid)))
            }
        }
    }

    func testUTF8TextMetadataTimeAndSegmentBounds() throws {
        let session = try SpeakerTestValues.session()
        let maximumText = String(repeating: "é", count: 32_768)
        let maximumMetadata = String(repeating: "é", count: 64)
        let segment = try SpeakerTestValues.segment(text: maximumText, speaker: maximumMetadata,
                                                    language: maximumMetadata, emotion: maximumMetadata, event: maximumMetadata)
        let event = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed, text: maximumText, segments: [segment])
        XCTAssertEqual(try OmniXPCSpeakerEvent.decode(event.encoded()), event)
        for text in [maximumText + "a", "\0"] {
            XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed, text: text, segments: []))
        }
        for (startSeconds, endSeconds) in [(Double.nan, 1), (0, Double.infinity), (-1, 0), (2, 1)] {
            XCTAssertThrowsError(try OmniXPCBatchSegment(startSeconds: startSeconds, endSeconds: endSeconds,
                                                        text: "", speaker: nil, language: nil, emotion: nil, event: nil))
        }
        let empty = try SpeakerTestValues.segment()
        XCTAssertNoThrow(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed,
                                                text: "", segments: Array(repeating: empty, count: 512)))
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed,
                                                   text: "", segments: Array(repeating: empty, count: 513)))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(segment)) as? [String: Any])
        for field in ["text", "speaker", "language", "emotion", "event"] {
            for replacement in ["\0", String(repeating: "é", count: field == "text" ? 32_769 : 65)] {
                var invalid = original
                invalid[field] = replacement
                try assertRejectedSegment(invalid, session: session)
            }
        }
        for (field, replacement): (String, Any) in [("startSeconds", -1), ("endSeconds", 0), ("extra", 0)] {
            var invalid = original
            invalid[field] = replacement
            try assertRejectedSegment(invalid, session: session)
        }
        for field in original.keys {
            var missing = original
            missing.removeValue(forKey: field)
            try assertRejectedSegment(missing, session: session)
        }
    }

    func testEventAggregateIncludesEveryPresentStringTerminator() throws {
        let session = try SpeakerTestValues.session()
        let text = String(repeating: "x", count: 65_535)
        let segment = try SpeakerTestValues.segment(text: text)
        let exact = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed,
                                          text: text, segments: Array(repeating: segment, count: 3))
        XCTAssertEqual(try OmniXPCSpeakerEvent.decode(exact.encoded()), exact)
        XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed,
                                                   text: text + "x", segments: Array(repeating: segment, count: 3)))
        for metadataField in ["speaker", "language", "emotion", "event"] {
            let extraTerminator = try SpeakerTestValues.segment(text: text, speaker: metadataField == "speaker" ? "" : nil,
                                                                language: metadataField == "language" ? "" : nil,
                                                                emotion: metadataField == "emotion" ? "" : nil,
                                                                event: metadataField == "event" ? "" : nil)
            XCTAssertThrowsError(try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed,
                                                       text: text, segments: [segment, segment, extraTerminator]))
        }
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: exact.encoded()) as? [String: Any])
        var oversized = original
        oversized["text"] = text + "x"
        XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: oversized)))
    }

    func testBoundedEventDecodeBeforeArraysAndMalformedJSON() throws {
        let session = try SpeakerTestValues.session()
        let sessionJSON = String(decoding: try session.encoded(), as: UTF8.self)
        let largeArray = Array(repeating: "null", count: 10_000).joined(separator: ",")
        let oversized = Data("{\"session\":\(sessionJSON),\"eventSequence\":1,\"kind\":3,\"failureStatus\":0,\"text\":\"\",\"segments\":[\(largeArray)]}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(OmniXPCSpeakerEvent.self, from: oversized)) { error in
            XCTAssertTrue(error.localizedDescription.contains("segment count"))
        }
        let event = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .updated)
        var bytes = try event.encoded()
        let limit = OmniXPCSpeakerLimits.maximumEventByteCount
        bytes.append(Data(repeating: 32, count: limit - bytes.count))
        XCTAssertEqual(try OmniXPCSpeakerEvent.decode(bytes), event)
        bytes.append(32)
        XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(bytes))
        for invalid in [Data(), Data("null".utf8), Data("[]".utf8), Data("{}{}".utf8), Data([0xFF, 0xFE])] {
            XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(invalid))
        }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        for nonfinite in ["Inf", "-Inf", "NaN", "1e999"] {
            let literal = nonfinite == "1e999" ? nonfinite : "\"\(nonfinite)\""
            let segmentJSON = "{\"startSeconds\":\(literal),\"endSeconds\":1,\"text\":\"\",\"speaker\":null,\"language\":null,\"emotion\":null,\"event\":null}"
            let json = "{\"session\":\(sessionJSON),\"eventSequence\":1,\"kind\":3,\"failureStatus\":0,\"text\":\"\",\"segments\":[\(segmentJSON)]}"
            XCTAssertThrowsError(try decoder.decode(OmniXPCSpeakerEvent.self, from: Data(json.utf8)))
        }
    }

    private func assertRejectedSegment(_ segment: [String: Any], session: OmniXPCSpeakerSessionReference) throws {
        let event = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .completed, text: "", segments: [])
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: event.encoded()) as? [String: Any])
        fields["segments"] = [segment]
        XCTAssertThrowsError(try OmniXPCSpeakerEvent.decode(JSONSerialization.data(withJSONObject: fields)))
    }
}
