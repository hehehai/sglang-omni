import Foundation
import OmniXPCContracts
import XCTest

final class OmniXPCSpeakerBatchTests: XCTestCase {
    func testBothFamilyPollBatchesAndStableEncoding() throws {
        for kind in OmniXPCSpeakerKind.allCases {
            let session = try SpeakerTestValues.session(kind)
            for isDrained in [false, true] {
                let batch = try OmniXPCSpeakerBatch(session: session, events: [], isDrained: isDrained)
                XCTAssertEqual(try OmniXPCSpeakerBatch.decode(batch.encoded()), batch)
            }
            let events: [OmniXPCSpeakerEvent] = try [
                .init(session: session, eventSequence: 41, kind: .updated),
                .init(session: session, eventSequence: 42, kind: .segment, segmentID: 0, text: "preview", isFinal: false),
                .init(session: session, eventSequence: 43, kind: .segment, segmentID: 0, text: "final", isFinal: true,
                      segments: [SpeakerTestValues.segment(text: "final", speaker: "speaker_0")]),
                .init(session: session, eventSequence: 44, kind: .completed, text: "final", segments: [])
            ]
            let batch = try OmniXPCSpeakerBatch(session: session, events: events, isDrained: false)
            XCTAssertEqual(try OmniXPCSpeakerBatch.decode(batch.encoded()), batch)
            XCTAssertEqual(try batch.encoded(), try batch.encoded())
            XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: session, events: events, isDrained: true))
        }
    }

    func testExactly64EventsAccepted65RejectedBeforeElementsDecode() throws {
        let session = try SpeakerTestValues.session()
        let events = try (1...64).map { try OmniXPCSpeakerEvent(session: session, eventSequence: UInt64($0), kind: .updated) }
        let batch = try OmniXPCSpeakerBatch(session: session, events: events, isDrained: false)
        XCTAssertEqual(OmniXPCSpeakerLimits.maximumEventsPerBatch, 64)
        XCTAssertEqual(try OmniXPCSpeakerBatch.decode(batch.encoded()), batch)
        let extra = try OmniXPCSpeakerEvent(session: session, eventSequence: 65, kind: .updated)
        XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: session, events: events + [extra], isDrained: false))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.encoded()) as? [String: Any])
        var fields = original
        var eventFields = try XCTUnwrap(fields["events"] as? [[String: Any]])
        eventFields.append(try XCTUnwrap(JSONSerialization.jsonObject(with: extra.encoded()) as? [String: Any]))
        fields["events"] = eventFields
        XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(JSONSerialization.data(withJSONObject: fields)))
        for count in [65, 100_000] {
            fields["events"] = Array(repeating: NSNull(), count: count)
            let bytes = try JSONSerialization.data(withJSONObject: fields)
            XCTAssertThrowsError(try JSONDecoder().decode(OmniXPCSpeakerBatch.self, from: bytes)) { error in
                XCTAssertTrue(error.localizedDescription.contains("event count"))
            }
        }
    }

    func testContiguousUInt64SequencesRejectDuplicatesGapsAndOverflow() throws {
        let session = try SpeakerTestValues.session(.nemotron)
        for sequences: [UInt64] in [[1, 1], [2, 1], [1, 3], [.max, 1]] {
            let events = try sequences.map { try OmniXPCSpeakerEvent(session: session, eventSequence: $0, kind: .updated) }
            XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: session, events: events, isDrained: false))
            let eventJSON = try events.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: ",")
            let sessionJSON = String(decoding: try session.encoded(), as: UTF8.self)
            let json = "{\"session\":\(sessionJSON),\"events\":[\(eventJSON)],\"isDrained\":false}"
            XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(Data(json.utf8)))
        }
        for sequences: [UInt64] in [[UInt64.max], [UInt64.max - 1, UInt64.max]] {
            let events = try sequences.map { try OmniXPCSpeakerEvent(session: session, eventSequence: $0, kind: .updated) }
            let batch = try OmniXPCSpeakerBatch(session: session, events: events, isDrained: false)
            XCTAssertEqual(try OmniXPCSpeakerBatch.decode(batch.encoded()), batch)
        }
    }

    func testEveryTerminalMustBeLastNotCleanupProof() throws {
        let session = try SpeakerTestValues.session()
        let terminals: [OmniXPCSpeakerEvent] = try [
            .init(session: session, eventSequence: 1, kind: .completed, text: "", segments: []),
            .init(session: session, eventSequence: 1, kind: .cancelled, failureStatus: .cancelled),
            .init(session: session, eventSequence: 1, kind: .failed, failureStatus: .limit)
        ]
        let later = try OmniXPCSpeakerEvent(session: session, eventSequence: 2, kind: .updated)
        for terminal in terminals {
            let valid = try OmniXPCSpeakerBatch(session: session, events: [terminal], isDrained: false)
            XCTAssertEqual(try OmniXPCSpeakerBatch.decode(valid.encoded()), valid)
            XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: session, events: [terminal, later], isDrained: false))
            XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: session, events: [terminal], isDrained: true))
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.encoded()) as? [String: Any])
            fields["events"] = try [terminal, later].map { try JSONSerialization.jsonObject(with: $0.encoded()) }
            XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testEveryReferenceScopeMustMatchIncludingFamilyAndOriginalLoad() throws {
        let session = try SpeakerTestValues.session()
        let event = try OmniXPCSpeakerEvent(session: session, eventSequence: 1, kind: .updated)
        let sessionFields = try XCTUnwrap(JSONSerialization.jsonObject(with: session.encoded()) as? [String: Any])
        let modelFields = try XCTUnwrap(sessionFields["model"] as? [String: Any])
        var alternateScopes: [OmniXPCSpeakerSessionReference] = [
            try OmniXPCSpeakerSessionReference(sessionID: UUID(), model: session.model)
        ]
        for field in ["kind", "modelID", "serviceInstanceID", "connectionID", "loadOperationID"] {
            var changedModel = modelFields
            changedModel[field] = field == "kind" ? 2 : UUID().uuidString
            var changedSession = sessionFields
            changedSession["model"] = changedModel
            alternateScopes.append(try OmniXPCSpeakerSessionReference.decode(JSONSerialization.data(withJSONObject: changedSession)))
        }
        let batch = try OmniXPCSpeakerBatch(session: session, events: [event], isDrained: false)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.encoded()) as? [String: Any])
        for alternate in alternateScopes {
            XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: alternate, events: [event], isDrained: false))
            var fields = original
            fields["session"] = try JSONSerialization.jsonObject(with: alternate.encoded())
            XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testNativeQueueStringBudgetAndJSONEscapingBudgetAreIndependent() throws {
        let session = try SpeakerTestValues.session()
        let text = String(repeating: "x", count: 65_535)
        let segment = try SpeakerTestValues.segment(text: text)
        let events = try (1...17).map {
            try OmniXPCSpeakerEvent(session: session, eventSequence: UInt64($0), kind: .segment,
                                    segmentID: Int32($0), text: text, isFinal: true, segments: Array(repeating: segment, count: 3))
        }
        XCTAssertEqual(OmniXPCSpeakerLimits.maximumEventStringByteCount * 16, OmniXPCSpeakerLimits.maximumBatchStringByteCount)
        XCTAssertNoThrow(try OmniXPCSpeakerBatch(session: session, events: Array(events.prefix(16)), isDrained: false))
        XCTAssertThrowsError(try OmniXPCSpeakerBatch(session: session, events: events, isDrained: false))
        let sessionJSON = String(decoding: try session.encoded(), as: UTF8.self)
        let eventJSON = try events.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: ",")
        let json = "{\"session\":\(sessionJSON),\"events\":[\(eventJSON)],\"isDrained\":false}"
        XCTAssertThrowsError(try JSONDecoder().decode(OmniXPCSpeakerBatch.self, from: Data(json.utf8)))
        XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(Data(json.utf8)))
        let escapedText = String(repeating: "\u{01}", count: 65_536)
        let escapedEvents = try (1...11).map {
            try OmniXPCSpeakerEvent(session: session, eventSequence: UInt64($0), kind: .segment,
                                    segmentID: Int32($0), text: escapedText, isFinal: false)
        }
        let escapedBatch = try OmniXPCSpeakerBatch(session: session, events: escapedEvents, isDrained: false)
        XCTAssertThrowsError(try escapedBatch.encoded())
        let unchecked = try JSONEncoder().encode(escapedBatch)
        XCTAssertGreaterThan(unchecked.count, OmniXPCSpeakerLimits.maximumBatchByteCount)
        XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(unchecked))
    }

    func testExactWireByteLimitAndStrictBatchFields() throws {
        let session = try SpeakerTestValues.session()
        let batch = try OmniXPCSpeakerBatch(session: session, events: [], isDrained: false)
        var bytes = try batch.encoded()
        let limit = OmniXPCSpeakerLimits.maximumBatchByteCount
        XCTAssertEqual(limit, 4_194_304)
        bytes.append(Data(repeating: 32, count: limit - bytes.count))
        XCTAssertEqual(try OmniXPCSpeakerBatch.decode(bytes), batch)
        bytes.append(32)
        XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(bytes))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.encoded()) as? [String: Any])
        for (field, replacement): (String, Any) in [
            ("extra", 0), ("events", NSNull()), ("events", [:]), ("isDrained", 1), ("isDrained", NSNull()), ("session", "bad")
        ] {
            var fields = original
            fields[field] = replacement
            XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(JSONSerialization.data(withJSONObject: fields)))
        }
        for field in original.keys {
            var fields = original
            fields.removeValue(forKey: field)
            XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(JSONSerialization.data(withJSONObject: fields)))
        }
        for invalid in [Data(), Data("null".utf8), Data("[]".utf8), Data("{}".utf8), Data([0xFF, 0xFE])] {
            XCTAssertThrowsError(try OmniXPCSpeakerBatch.decode(invalid))
        }
    }
}
