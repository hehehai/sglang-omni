import Foundation
import OmniXPCContracts
import XCTest

final class OmniXPCRealtimeTests: XCTestCase {
    private let sessionID = UUID()
    private let modelID = UUID()
    private let serviceInstanceID = UUID()

    func testPublicModelAndSessionReferencesPreserveIdentity() {
        let model = OmniXPCModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: UUID())
        let final = OmniXPCFinalSessionReference(sessionID: sessionID, model: model, language: "en", maximumTokenCount: 128)
        let realtime = OmniXPCRealtimeSessionReference(sessionID: sessionID, model: model, language: "en", maximumTokenCount: 128)
        XCTAssertEqual(final.sessionID, realtime.sessionID)
        XCTAssertEqual(final.model, model)
        XCTAssertEqual(realtime.model, model)
        XCTAssertEqual(final.language, realtime.language)
        XCTAssertEqual(final.maximumTokenCount, realtime.maximumTokenCount)
        XCTAssertEqual(OmniXPCProtocolLimits.abiVersion, 5)
    }

    func testSettingsDefaultsAndIndependentInclusiveSampleBounds() throws {
        let defaults = try OmniXPCRealtimeSettings()
        XCTAssertEqual(defaults.decodeIntervalSamples, 16_000)
        XCTAssertEqual(defaults.firstDecodeSamples, 8_000)
        XCTAssertEqual(defaults.maximumSegmentSamples, 48_000)
        for count in [1, OmniXPCProtocolLimits.maximumSampleCount] {
            XCTAssertEqual(try OmniXPCRealtimeSettings(decodeIntervalSamples: count).decodeIntervalSamples, count)
            XCTAssertEqual(try OmniXPCRealtimeSettings(firstDecodeSamples: count).firstDecodeSamples, count)
            XCTAssertEqual(try OmniXPCRealtimeSettings(maximumSegmentSamples: count).maximumSegmentSamples, count)
        }
        for count in [Int.min, -1, 0, OmniXPCProtocolLimits.maximumSampleCount + 1, Int.max] {
            XCTAssertThrowsError(try OmniXPCRealtimeSettings(decodeIntervalSamples: count))
            XCTAssertThrowsError(try OmniXPCRealtimeSettings(firstDecodeSamples: count))
            XCTAssertThrowsError(try OmniXPCRealtimeSettings(maximumSegmentSamples: count))
        }
    }

    func testRealtimeOptionsUseSmallerContextBudgetWithoutChangingFinalOptions() throws {
        let limit = OmniXPCProtocolLimits.maximumRealtimeContextByteCount
        XCTAssertEqual(limit, 8192)
        XCTAssertEqual(OmniXPCProtocolLimits.maximumPromptByteCount, 16_384)
        for context in [nil, "", String(repeating: "é", count: limit / 2)] {
            try OmniXPCRequestValidation.realtimeOptions(language: "en", context: context, maximumTokenCount: 4096)
        }
        let oversized = String(repeating: "é", count: limit / 2) + "a"
        XCTAssertThrowsError(try OmniXPCRequestValidation.realtimeOptions(language: nil, context: oversized, maximumTokenCount: 1))
        XCTAssertNoThrow(try OmniXPCRequestValidation.options(language: nil, context: oversized, maximumTokenCount: 1))
        for language in ["en\0ignored", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.realtimeOptions(language: language, context: nil, maximumTokenCount: 1))
        }
        for count in [Int.min, 0, 4097, Int.max] {
            XCTAssertThrowsError(try OmniXPCRequestValidation.realtimeOptions(language: nil, context: nil, maximumTokenCount: count))
        }
        XCTAssertThrowsError(try OmniXPCRequestValidation.realtimeOptions(language: nil, context: "prompt\0ignored", maximumTokenCount: 1))
    }

    func testCodecRoundTripsAllKindsAndEmptyTranscripts() throws {
        let prefixes: [OmniXPCRealtimeEvent] = [
            .init(sequence: 1, kind: .updated),
            .init(sequence: 2, kind: .segment, segmentID: 0, text: "", isFinal: false),
            .init(sequence: 3, kind: .segment, segmentID: 0, text: "Hello 世界\n", isFinal: true),
        ]
        let terminals: [OmniXPCRealtimeEvent] = [
            .init(sequence: 4, kind: .completed, text: ""),
            .init(sequence: 4, kind: .cancelled),
            .init(sequence: 4, kind: .failed, failureMessage: "Realtime transcription failed."),
        ]
        for terminal in terminals {
            let expected = batch(prefixes + [terminal])
            XCTAssertEqual(try OmniXPCRealtimeCodec.decode(OmniXPCRealtimeCodec.encode(expected)), expected)
        }
        for kind in [OmniXPCRealtimeEventKind.updated, .segment, .completed, .cancelled, .failed] {
            XCTAssertEqual(try JSONDecoder().decode(OmniXPCRealtimeEventKind.self, from: JSONEncoder().encode(kind)), kind)
        }
    }

    func testEmptyIdleAndDrainedBatchesAreDistinct() throws {
        for isDrained in [false, true] {
            let expected = batch([], isDrained: isDrained)
            XCTAssertEqual(try OmniXPCRealtimeCodec.decode(OmniXPCRealtimeCodec.encode(expected)), expected)
        }
        try assertRejected(batch([.init(sequence: 1, kind: .updated)], isDrained: true))
    }

    func testCodecAllowsConsecutiveContinuationAndStableReplayBytes() throws {
        let expected = batch([
            .init(sequence: 42, kind: .updated),
            .init(sequence: 43, kind: .segment, segmentID: 2, text: "preview", isFinal: false),
        ])
        let firstReply = try OmniXPCRealtimeCodec.encode(expected)
        XCTAssertEqual(try OmniXPCRealtimeCodec.encode(expected), firstReply)
        XCTAssertEqual(try OmniXPCRealtimeCodec.decode(firstReply), expected)
        let last = batch([.init(sequence: Int.max, kind: .completed, text: "done")])
        XCTAssertEqual(try OmniXPCRealtimeCodec.decode(OmniXPCRealtimeCodec.encode(last)), last)
    }

    func testCodecRejectsNonpositiveDuplicateRegressedAndSkippedSequences() throws {
        for sequences in [[0], [-1], [Int.min], [1, 1], [2, 1], [1, 3], [Int.max, 1]] {
            try assertRejected(batch(sequences.map { .init(sequence: $0, kind: .updated) }))
        }
    }

    func testCodecRejectsEventsAfterAnyTerminal() throws {
        for terminal: OmniXPCRealtimeEvent in [
            .init(sequence: 1, kind: .completed, text: "done"),
            .init(sequence: 1, kind: .cancelled),
            .init(sequence: 1, kind: .failed, failureMessage: "Failed."),
        ] {
            try assertRejected(batch([terminal, .init(sequence: 2, kind: .updated)]))
            try assertRejected(batch([terminal, .init(sequence: 2, kind: .cancelled)]))
        }
    }

    func testCodecRejectsInvalidEventShapesOnEncodeAndDecode() throws {
        let events: [OmniXPCRealtimeEvent] = [
            .init(sequence: 1, kind: .updated, segmentID: 0),
            .init(sequence: 1, kind: .updated, text: ""),
            .init(sequence: 1, kind: .updated, isFinal: false),
            .init(sequence: 1, kind: .updated, failureMessage: "Failed."),
            .init(sequence: 1, kind: .cancelled, segmentID: 0),
            .init(sequence: 1, kind: .cancelled, text: ""),
            .init(sequence: 1, kind: .cancelled, isFinal: false),
            .init(sequence: 1, kind: .cancelled, failureMessage: "Failed."),
            .init(sequence: 1, kind: .segment, text: "", isFinal: false),
            .init(sequence: 1, kind: .segment, segmentID: -1, text: "", isFinal: false),
            .init(sequence: 1, kind: .segment, segmentID: 0, isFinal: false),
            .init(sequence: 1, kind: .segment, segmentID: 0, text: ""),
            .init(sequence: 1, kind: .segment, segmentID: 0, text: "", isFinal: false, failureMessage: "Failed."),
            .init(sequence: 1, kind: .completed),
            .init(sequence: 1, kind: .completed, segmentID: 0, text: ""),
            .init(sequence: 1, kind: .completed, text: "", isFinal: true),
            .init(sequence: 1, kind: .completed, text: "", failureMessage: "Failed."),
            .init(sequence: 1, kind: .failed),
            .init(sequence: 1, kind: .failed, failureMessage: ""),
            .init(sequence: 1, kind: .failed, segmentID: 0, failureMessage: "Failed."),
            .init(sequence: 1, kind: .failed, text: "", failureMessage: "Failed."),
            .init(sequence: 1, kind: .failed, isFinal: true, failureMessage: "Failed."),
        ]
        for event in events { try assertRejected(batch([event])) }
    }

    func testCodecBoundsUTF8BytesAndRejectsNULAndUnsanitizedFailures() throws {
        let maximumText = String(repeating: "é", count: OmniXPCProtocolLimits.maximumRealtimeEventStringByteCount / 2)
        for event: OmniXPCRealtimeEvent in [
            .init(sequence: 1, kind: .completed, text: maximumText),
            .init(sequence: 1, kind: .segment, segmentID: 0, text: maximumText, isFinal: false),
            .init(sequence: 1, kind: .failed, failureMessage: maximumText),
        ] {
            let expected = batch([event])
            XCTAssertEqual(try OmniXPCRealtimeCodec.decode(OmniXPCRealtimeCodec.encode(expected)), expected)
        }
        for text in [maximumText + "a", "nul\0ignored"] {
            try assertRejected(batch([.init(sequence: 1, kind: .completed, text: text)]))
            try assertRejected(batch([.init(sequence: 1, kind: .segment, segmentID: 0, text: text, isFinal: false)]))
            try assertRejected(batch([.init(sequence: 1, kind: .failed, failureMessage: text)]))
        }
        for text in ["failed\nsecret", "failed\rsecret", "failed\tsecret", "failed\u{1B}secret", "failed\u{7F}secret"] {
            try assertRejected(batch([.init(sequence: 1, kind: .failed, failureMessage: text)]))
        }
    }

    func testCodecEnforcesEventCountAndEncodedByteBudgets() throws {
        let limit = OmniXPCProtocolLimits.maximumRealtimeEventsPerBatch
        XCTAssertEqual(limit, 16)
        let events: [OmniXPCRealtimeEvent] = (1...limit).map { .init(sequence: $0, kind: .updated) }
        let expected = batch(events)
        XCTAssertEqual(try OmniXPCRealtimeCodec.decode(OmniXPCRealtimeCodec.encode(expected)), expected)
        try assertRejected(batch(events + [.init(sequence: limit + 1, kind: .updated)]))
        let escapedText = String(repeating: "\u{01}", count: OmniXPCProtocolLimits.maximumRealtimeEventStringByteCount)
        let oversized = batch((1...limit).map {
            .init(sequence: $0, kind: .segment, segmentID: $0, text: escapedText, isFinal: false)
        })
        try assertRejected(oversized)
        let maximumByteCount = OmniXPCProtocolLimits.maximumRealtimeBatchByteCount
        XCTAssertEqual(maximumByteCount, 2 * 1024 * 1024)
        var exact = try OmniXPCRealtimeCodec.encode(batch([]))
        exact.append(Data(repeating: 32, count: maximumByteCount - exact.count))
        XCTAssertEqual(try OmniXPCRealtimeCodec.decode(exact), batch([]))
        exact.append(32)
        XCTAssertThrowsError(try OmniXPCRealtimeCodec.decode(exact))
    }

    func testDecodeRejectsUnknownMissingNullAndWronglyTypedEventFields() {
        for event in [
            #"{"sequence":1,"kind":1,"unknown":0}"#,
            #"{"kind":1}"#, #"{"sequence":1}"#,
            #"{"sequence":1,"kind":99}"#, #"{"sequence":1,"kind":"updated"}"#,
            #"{"sequence":1,"kind":true}"#, #"{"sequence":true,"kind":1}"#,
            #"{"sequence":"1","kind":1}"#, #"{"sequence":1.5,"kind":1}"#,
            #"{"sequence":18446744073709551615,"kind":1}"#,
            #"{"sequence":1,"kind":1,"text":null}"#,
            #"{"sequence":1,"kind":1,"segmentID":null}"#,
            #"{"sequence":1,"kind":1,"isFinal":null}"#,
            #"{"sequence":1,"kind":1,"failureMessage":null}"#,
            #"{"sequence":1,"kind":2,"segmentID":0,"text":"","isFinal":1}"#,
            #"{"sequence":1,"kind":2,"segmentID":true,"text":"","isFinal":false}"#,
            #"{"sequence":1,"kind":3,"text":[]}"#,
            #"{"sequence":1,"kind":5,"failureMessage":{}}"#,
        ] {
            XCTAssertThrowsError(try OmniXPCRealtimeCodec.decode(wire(events: "[\(event)]")), event)
        }
    }

    func testDecodeRejectsBatchSchemaIdentityTypeAndSyntaxAbuse() throws {
        let valid = String(decoding: try OmniXPCRealtimeCodec.encode(batch([])), as: UTF8.self)
        let invalid = [
            "", "null", "[]", "{}", valid + "{}", String(valid.dropLast()),
            valid.replacingOccurrences(of: #""events":[]"#, with: #""events":null"#),
            valid.replacingOccurrences(of: #""events":[]"#, with: #""events":{}"#),
            valid.replacingOccurrences(of: #""events":[],"#, with: ""),
            valid.replacingOccurrences(of: #""events":[]"#, with: #""events":[],"unknown":0"#),
            valid.replacingOccurrences(of: #""isDrained":false"#, with: #""isDrained":0"#),
            valid.replacingOccurrences(of: #""isDrained":false"#, with: #""isDrained":"false""#),
            valid.replacingOccurrences(of: sessionID.uuidString, with: "not-a-session"),
            valid.replacingOccurrences(of: modelID.uuidString, with: "not-a-model"),
            valid.replacingOccurrences(of: serviceInstanceID.uuidString, with: "not-a-service"),
            valid.replacingOccurrences(of: sessionID.uuidString, with: #"\u0000"#),
        ]
        for json in invalid { XCTAssertThrowsError(try OmniXPCRealtimeCodec.decode(Data(json.utf8)), json) }
        XCTAssertThrowsError(try OmniXPCRealtimeCodec.decode(Data([0xFF, 0xFE])))
    }

    private func batch(_ events: [OmniXPCRealtimeEvent], isDrained: Bool = false) -> OmniXPCRealtimeBatch {
        .init(sessionID: sessionID, modelID: modelID, serviceInstanceID: serviceInstanceID, events: events, isDrained: isDrained)
    }

    private func wire(events: String) -> Data {
        Data("""
        {"sessionID":"\(sessionID)","modelID":"\(modelID)","serviceInstanceID":"\(serviceInstanceID)","events":\(events),"isDrained":false}
        """.utf8)
    }

    private func assertRejected(_ batch: OmniXPCRealtimeBatch, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try OmniXPCRealtimeCodec.encode(batch), file: file, line: line)
        let unchecked = try JSONEncoder().encode(batch)
        XCTAssertThrowsError(try OmniXPCRealtimeCodec.decode(unchecked), file: file, line: line)
    }
}
