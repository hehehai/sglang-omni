import Foundation
import XCTest
import OmniXPCContracts

final class OmniXPCSortformerTests: XCTestCase {
    private let serviceInstanceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let modelID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let streamID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let connectionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let durationSeconds = Double(Float(160) / Float(16_000) * 8)
    private let settingsFields = [
        "threshold": "0.25", "minimumDurationSeconds": "0.125", "mergeGapSeconds": "0.5",
        "speakerCacheMaximumFrameCount": "188", "fifoMaximumFrameCount": "40",
    ]
    private var batchFields: [String: String] {
        ["serviceInstanceID": "\"\(serviceInstanceID)\"", "modelID": "\"\(modelID)\"", "streamID": "\"\(streamID)\"",
         "audioSequence": "1", "processedFrameCount": "1", "frameCount": "1", "speakerCount": "4",
         "frameDurationSeconds": "\(durationSeconds)", "probabilities": "[0,0.25,0.5,1]", "segments": "[]"]
    }

    func testSupportedLimitsAndNativeFloatDuration() {
        XCTAssertEqual(OmniXPCSortformerLimits.sampleRate, 16_000)
        XCTAssertEqual(OmniXPCSortformerLimits.featureHopSampleCount, 160)
        XCTAssertEqual(OmniXPCSortformerLimits.subsamplingFactor, 8)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumChunkSampleCount, 32_000)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumStreamCount, 16)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumStateFrameCount, 4096)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumChunkFrameCount, 26)
        XCTAssertEqual(OmniXPCSortformerLimits.speakerCount, 4)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumSegmentCount, 104)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumSettingsByteCount, 1024)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumBatchByteCount, 32_768)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumDurationSeconds, 3600)
        XCTAssertEqual(OmniXPCSortformerLimits.maximumProcessedFrameCount, UInt64(Int32.max))
        XCTAssertEqual(OmniXPCSortformerLimits.frameDurationSeconds, durationSeconds)
        XCTAssertNotEqual(durationSeconds, 0.08)
    }

    func testReferencesPreserveModelServiceConnectionAndStreamScope() {
        let model = OmniXPCSortformerModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: connectionID)
        let stream = OmniXPCSortformerStreamReference(streamID: streamID, model: model)
        XCTAssertEqual(stream.streamID, streamID)
        XCTAssertEqual(stream.model.modelID, modelID)
        XCTAssertEqual(stream.model.serviceInstanceID, serviceInstanceID)
        XCTAssertEqual(stream.model.connectionID, connectionID)
        XCTAssertEqual(stream, OmniXPCSortformerStreamReference(streamID: streamID, model: model))
        XCTAssertNotEqual(stream, OmniXPCSortformerStreamReference(streamID: connectionID, model: model))
        for otherModel in [
            OmniXPCSortformerModelReference(modelID: streamID, serviceInstanceID: serviceInstanceID, connectionID: connectionID),
            OmniXPCSortformerModelReference(modelID: modelID, serviceInstanceID: streamID, connectionID: connectionID),
            OmniXPCSortformerModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: streamID),
        ] {
            XCTAssertNotEqual(stream, OmniXPCSortformerStreamReference(streamID: streamID, model: otherModel))
        }
    }

    func testSettingsRoundTripAndIndependentInclusiveBoundsWithoutModelPolicy() throws {
        let settings = try makeSettings()
        XCTAssertEqual(try OmniXPCSortformerSettings.decode(json(settingsFields)), settings)
        XCTAssertEqual(try settings.encoded(), try settings.encoded())
        for threshold: Float in [0, .leastNonzeroMagnitude, 1] {
            for durationSeconds: Float in [0, .leastNonzeroMagnitude, 3600] {
                for cacheFrameCount in [1, 4096] {
                    for fifoFrameCount in [0, 4096] {
                        let settings = try makeSettings(threshold: threshold, minimumDurationSeconds: durationSeconds,
                                                        mergeGapSeconds: durationSeconds, cacheFrameCount: cacheFrameCount,
                                                        fifoFrameCount: fifoFrameCount)
                        try settings.validate()
                        XCTAssertEqual(try OmniXPCSortformerSettings.decode(settings.encoded()), settings)
                        XCTAssertEqual(try JSONDecoder().decode(OmniXPCSortformerSettings.self, from: JSONEncoder().encode(settings)), settings)
                    }
                }
            }
        }
    }

    func testSettingsConstructorsRejectNonfiniteAndOutOfRangeValues() {
        for value: Float in [-.leastNonzeroMagnitude, -1, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            assertFailure(.invalidRequest) { _ = try makeSettings(threshold: value) }
            assertFailure(.invalidRequest) { _ = try makeSettings(minimumDurationSeconds: value) }
            assertFailure(.invalidRequest) { _ = try makeSettings(mergeGapSeconds: value) }
        }
        assertFailure(.invalidRequest) { _ = try makeSettings(threshold: Float(1).nextUp) }
        assertFailure(.invalidRequest) { _ = try makeSettings(minimumDurationSeconds: Float(3600).nextUp) }
        assertFailure(.invalidRequest) { _ = try makeSettings(mergeGapSeconds: Float(3600).nextUp) }
        for frameCount in [Int.min, -1, 4097, Int.max] {
            assertFailure(.invalidRequest) { _ = try makeSettings(cacheFrameCount: frameCount) }
            assertFailure(.invalidRequest) { _ = try makeSettings(fifoFrameCount: frameCount) }
        }
        assertFailure(.invalidRequest) { _ = try makeSettings(cacheFrameCount: 0) }
    }

    func testSettingsStrictFieldsAndNumericWireDomains() {
        assertInvalidFields(settingsFields, code: .invalidRequest) { _ = try OmniXPCSortformerSettings.decode($0) }
        for field in settingsFields.keys {
            for value in ["-1", "4097", "1e1000", "\"NaN\"", "\"Infinity\"", "[]"] {
                assertFailure(.invalidRequest) { _ = try OmniXPCSortformerSettings.decode(json(settingsFields, replacing: field, with: value)) }
            }
        }
        for field in ["speakerCacheMaximumFrameCount", "fifoMaximumFrameCount"] {
            for value in ["0.5", "9223372036854775808"] {
                assertFailure(.invalidRequest) { _ = try OmniXPCSortformerSettings.decode(json(settingsFields, replacing: field, with: value)) }
            }
        }
        for (field, value) in [("threshold", "1.01"), ("minimumDurationSeconds", "3600.5"),
                               ("mergeGapSeconds", "3600.5"), ("speakerCacheMaximumFrameCount", "0")] {
            assertFailure(.invalidRequest) { _ = try OmniXPCSortformerSettings.decode(json(settingsFields, replacing: field, with: value)) }
        }
    }

    func testProbabilityRoundTripPreservesRowMajorShapeIdentitiesAndSeconds() throws {
        let probabilities: [Float] = [0, 0.25, 0.5, 1, 1, 1, 1, 1]
        let segments = try [OmniXPCSortformerSegment(startSeconds: 0, endSeconds: durationSeconds, speakerIndex: 3)]
        let batch = try makeBatch(processedFrameCount: 2, frameCount: 2, probabilities: probabilities, segments: segments)
        let decoded = try OmniXPCSortformerProbabilityBatch.decode(batch.encoded())
        XCTAssertEqual(decoded, batch)
        XCTAssertEqual(decoded.probabilities, probabilities)
        XCTAssertEqual(decoded.segments, segments)
        XCTAssertEqual(decoded.serviceInstanceID, serviceInstanceID)
        XCTAssertEqual(decoded.modelID, modelID)
        XCTAssertEqual(decoded.streamID, streamID)
        XCTAssertEqual(decoded.processedFrameCount, 2)
        XCTAssertEqual(decoded.frameDurationSeconds, durationSeconds)
        XCTAssertEqual(try batch.encoded(), try batch.encoded())
        XCTAssertEqual(try OmniXPCSortformerProbabilityBatch.decode(json(batchFields)), try makeBatch())
    }

    func testMaximumArrayCountsAndProcessedFramesWithoutSampleAlignmentOrDurationCap() throws {
        let segments = try Array(repeating: OmniXPCSortformerSegment(startSeconds: 0, endSeconds: 0, speakerIndex: 0), count: 104)
        let maximum = try makeBatch(processedFrameCount: 26, frameCount: 26,
                                   probabilities: Array(repeating: 1, count: 104), segments: segments)
        XCTAssertEqual(try OmniXPCSortformerProbabilityBatch.decode(maximum.encoded()), maximum)
        XCTAssertLessThanOrEqual(try maximum.encoded().count, OmniXPCSortformerLimits.maximumBatchByteCount)
        for processedFrameCount: UInt64 in [1, 513, 100_000, UInt64(Int32.max)] {
            let batch = try makeBatch(audioSequence: Int.max, processedFrameCount: processedFrameCount)
            XCTAssertEqual(try OmniXPCSortformerProbabilityBatch.decode(batch.encoded()), batch)
        }
    }

    func testBatchConstructorRejectsInvalidSequencesCountersShapeAndDuration() {
        for audioSequence in [Int.min, -1, 0] { assertFailure { _ = try makeBatch(audioSequence: audioSequence) } }
        for processedFrameCount: UInt64 in [0, UInt64(Int32.max) + 1, UInt64.max] {
            assertFailure { _ = try makeBatch(processedFrameCount: processedFrameCount) }
        }
        for frameCount in [Int.min, -1, 0, 2, 27, Int.max] { assertFailure { _ = try makeBatch(frameCount: frameCount) } }
        for speakerCount in [Int.min, -1, 0, 1, 3, 5, Int.max] { assertFailure { _ = try makeBatch(speakerCount: speakerCount) } }
        for count in [0, 1, 3, 5, 104, 105] { assertFailure { _ = try makeBatch(probabilities: Array(repeating: 0, count: count)) } }
        for seconds in [Double.nan, .infinity, -.infinity, -1, 0, 0.08, 80, durationSeconds.nextUp, durationSeconds.nextDown] {
            assertFailure { _ = try makeBatch(frameDurationSeconds: seconds) }
        }
    }

    func testBatchDecodeRejectsMismatchedShapeAndProcessedFrameCount() {
        for count in [0, 1, 3, 5, 104] {
            let probabilities = "[" + Array(repeating: "0", count: count).joined(separator: ",") + "]"
            assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(batchFields, replacing: "probabilities", with: probabilities)) }
        }
        var fields = batchFields
        fields["frameCount"] = "2"
        fields["probabilities"] = "[0,0,0,0,0,0,0,0]"
        assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(fields)) }
    }

    func testProbabilityValuesRejectNonfiniteAndOutOfRangeAtConstructionAndDecode() {
        for probability: Float in [-.leastNonzeroMagnitude, -1, Float(1).nextUp, .nan, .infinity, -.infinity] {
            assertFailure { _ = try makeBatch(probabilities: [probability, 0, 0, 0]) }
        }
        for value in ["-0.1", "1.1", "1e1000", "\"NaN\"", "\"Infinity\"", "true", "null", "{}", "[]"] {
            assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(batchFields, replacing: "probabilities", with: "[\(value),0,0,0]")) }
        }
    }

    func testBatchStrictFieldsMalformedUUIDsAndIntegerDomains() {
        assertInvalidFields(batchFields) { _ = try OmniXPCSortformerProbabilityBatch.decode($0) }
        for field in ["audioSequence", "processedFrameCount", "frameCount", "speakerCount"] {
            for value in ["-1", "0", "0.5", "18446744073709551616", "1e1000", "[]"] {
                assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(batchFields, replacing: field, with: value)) }
            }
        }
        for (field, value) in [("processedFrameCount", "2147483648"), ("frameCount", "27"), ("speakerCount", "3"),
                               ("frameDurationSeconds", "0.08"), ("frameDurationSeconds", "80"), ("probabilities", "[]"),
                               ("frameDurationSeconds", "1e1000"), ("probabilities", "[[0,0.25,0.5,1]]"), ("isFinal", "true")] {
            assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(batchFields, replacing: field, with: value)) }
        }
    }

    func testSegmentConstructorsRejectInvalidSecondsAndSpeakerIndices() throws {
        for seconds in [Double.nan, .infinity, -.infinity, -1, -.leastNonzeroMagnitude] {
            assertFailure { _ = try OmniXPCSortformerSegment(startSeconds: seconds, endSeconds: 1, speakerIndex: 0) }
            assertFailure { _ = try OmniXPCSortformerSegment(startSeconds: 0, endSeconds: seconds, speakerIndex: 0) }
        }
        assertFailure { _ = try OmniXPCSortformerSegment(startSeconds: 1, endSeconds: 0, speakerIndex: 0) }
        for speakerIndex in [Int.min, -1, 4, Int.max] {
            assertFailure { _ = try OmniXPCSortformerSegment(startSeconds: 0, endSeconds: 1, speakerIndex: speakerIndex) }
        }
        let segment = try OmniXPCSortformerSegment(startSeconds: 5000.125, endSeconds: 5000.125, speakerIndex: 3)
        XCTAssertEqual(try JSONDecoder().decode(OmniXPCSortformerSegment.self, from: JSONEncoder().encode(segment)), segment)
    }

    func testSegmentStrictFieldsAndNumericIndicesNotGeneratedLabels() {
        let fields = ["startSeconds": "0", "endSeconds": "0.01", "speakerIndex": "3"]
        assertInvalidFields(fields) { bytes in
            _ = try OmniXPCSortformerProbabilityBatch.decode(json(batchFields, replacing: "segments", with: "[\(String(decoding: bytes, as: UTF8.self))]"))
        }
        for (field, value) in [("startSeconds", "-0.01"), ("startSeconds", "0.02"), ("endSeconds", "-1"),
                               ("endSeconds", "1e1000"), ("endSeconds", "0.1"), ("speakerIndex", "4"),
                               ("speakerIndex", "-1"), ("speakerIndex", "0.5"), ("speakerIndex", "\"speaker_0\"")] {
            let segment = String(decoding: json(fields, replacing: field, with: value), as: UTF8.self)
            assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(batchFields, replacing: "segments", with: "[\(segment)]")) }
        }
    }

    func testAbsoluteRangesAllowOverlapAndEqualStartsButRejectUnsortedOrOutsideBatch() throws {
        let startSeconds = Double(Float(10) * Float(durationSeconds))
        let endSeconds = Double(Float(durationSeconds) + Float(startSeconds))
        let first = try OmniXPCSortformerSegment(startSeconds: startSeconds, endSeconds: endSeconds, speakerIndex: 3)
        let simultaneous = try OmniXPCSortformerSegment(startSeconds: startSeconds, endSeconds: endSeconds, speakerIndex: 0)
        let last = try OmniXPCSortformerSegment(startSeconds: endSeconds, endSeconds: endSeconds, speakerIndex: 1)
        let batch = try makeBatch(processedFrameCount: 11, segments: [first, simultaneous, last])
        XCTAssertEqual(try OmniXPCSortformerProbabilityBatch.decode(batch.encoded()), batch)
        for segments in [
            [last, first], [try OmniXPCSortformerSegment(startSeconds: startSeconds.nextDown, endSeconds: endSeconds, speakerIndex: 0)],
            [try OmniXPCSortformerSegment(startSeconds: startSeconds, endSeconds: endSeconds.nextUp, speakerIndex: 0)],
            [try OmniXPCSortformerSegment(startSeconds: 0, endSeconds: durationSeconds, speakerIndex: 0)],
            Array(repeating: first, count: 105),
        ] {
            assertFailure { _ = try makeBatch(processedFrameCount: 11, segments: segments) }
            var fields = batchFields
            fields["processedFrameCount"] = "11"
            fields["segments"] = String(decoding: try JSONEncoder().encode(segments), as: UTF8.self)
            assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(json(fields)) }
        }
    }

    func testLongStreamFloatOperationOrderAndCollapsedZeroDuration() throws {
        for previousFrameCount: UInt64 in [100_001, 16_777_217, UInt64(Int32.max) - 26] {
            for frameCount in [1, 26] {
                let startSeconds = Float(previousFrameCount) * Float(durationSeconds)
                let endSeconds = Float(frameCount) * Float(durationSeconds) + startSeconds
                let segment = try OmniXPCSortformerSegment(startSeconds: Double(startSeconds), endSeconds: Double(endSeconds), speakerIndex: 2)
                let batch = try makeBatch(processedFrameCount: previousFrameCount + UInt64(frameCount), frameCount: frameCount,
                                         probabilities: Array(repeating: 0.5, count: frameCount * 4), segments: [segment])
                XCTAssertEqual(try OmniXPCSortformerProbabilityBatch.decode(batch.encoded()), batch)
                XCTAssertNotEqual(Double(startSeconds), Double(previousFrameCount) * durationSeconds)
                let outside = try OmniXPCSortformerSegment(startSeconds: Double(startSeconds).nextDown,
                                                          endSeconds: Double(endSeconds), speakerIndex: 2)
                assertFailure {
                    _ = try makeBatch(processedFrameCount: batch.processedFrameCount, frameCount: frameCount,
                                      probabilities: batch.probabilities, segments: [outside])
                }
            }
        }
        let startSeconds = Float(UInt64(Int32.max) - 1) * Float(durationSeconds)
        XCTAssertEqual(startSeconds + Float(durationSeconds), startSeconds)
        let segment = try OmniXPCSortformerSegment(startSeconds: Double(startSeconds), endSeconds: Double(startSeconds), speakerIndex: 0)
        XCTAssertNoThrow(try makeBatch(processedFrameCount: UInt64(Int32.max), segments: [segment]))
    }

    func testArrayCountsAreBoundedBeforeDecodingEitherArrayElements() {
        let oversized = "[" + Array(repeating: "{}", count: 105).joined(separator: ",") + "]"
        for field in ["probabilities", "segments"] {
            var fields = batchFields
            fields["probabilities"] = "[{}]"
            fields[field] = oversized
            XCTAssertThrowsError(try JSONDecoder().decode(OmniXPCSortformerProbabilityBatch.self, from: json(fields))) { error in
                XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue)
                XCTAssertTrue(error.localizedDescription.contains("count exceeds"))
            }
        }
    }

    func testCustomNonconformingFloatDecoderStillValidatesValues() {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for value in ["\"NaN\"", "\"Infinity\"", "\"-Infinity\""] {
            assertFailure(.invalidRequest) { _ = try decoder.decode(OmniXPCSortformerSettings.self, from: json(settingsFields, replacing: "threshold", with: value)) }
            assertFailure { _ = try decoder.decode(OmniXPCSortformerProbabilityBatch.self, from: json(batchFields, replacing: "probabilities", with: "[\(value),0,0,0]")) }
            assertFailure { _ = try decoder.decode(OmniXPCSortformerProbabilityBatch.self, from: json(batchFields, replacing: "frameDurationSeconds", with: value)) }
            assertFailure { _ = try decoder.decode(OmniXPCSortformerSegment.self, from: json(["startSeconds": value, "endSeconds": "1", "speakerIndex": "0"])) }
        }
    }

    func testMalformedJSONAndExactByteLimitsBeforeParsing() throws {
        for prefix in ["", "null", "[]", "{}", "true", "1", "{", "{}false"] {
            assertFailure(.invalidRequest) { _ = try OmniXPCSortformerSettings.decode(Data(prefix.utf8)) }
            assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(Data(prefix.utf8)) }
        }
        let settings = try makeSettings()
        let batch = try makeBatch()
        var settingsBytes = try settings.encoded()
        var batchBytes = try batch.encoded()
        settingsBytes.append(Data(repeating: 0x20, count: 1024 - settingsBytes.count))
        batchBytes.append(Data(repeating: 0x20, count: 32_768 - batchBytes.count))
        XCTAssertEqual(try OmniXPCSortformerSettings.decode(settingsBytes), settings)
        XCTAssertEqual(try OmniXPCSortformerProbabilityBatch.decode(batchBytes), batch)
        settingsBytes.append(0x20)
        batchBytes.append(0x20)
        assertFailure(.invalidRequest) { _ = try OmniXPCSortformerSettings.decode(settingsBytes) }
        assertFailure { _ = try OmniXPCSortformerProbabilityBatch.decode(batchBytes) }
        for malformed in [false, true] {
            settingsBytes[0] = malformed ? 0xFF : 0x7B
            batchBytes[0] = malformed ? 0xFF : 0x7B
            XCTAssertThrowsError(try OmniXPCSortformerSettings.decode(settingsBytes)) { XCTAssertTrue($0.localizedDescription.contains("byte limit")) }
            XCTAssertThrowsError(try OmniXPCSortformerProbabilityBatch.decode(batchBytes)) { XCTAssertTrue($0.localizedDescription.contains("byte limit")) }
        }
    }

    private func makeSettings(
        threshold: Float = 0.25, minimumDurationSeconds: Float = 0.125, mergeGapSeconds: Float = 0.5,
        cacheFrameCount: Int = 188, fifoFrameCount: Int = 40
    ) throws -> OmniXPCSortformerSettings {
        try OmniXPCSortformerSettings(threshold: threshold, minimumDurationSeconds: minimumDurationSeconds,
                                     mergeGapSeconds: mergeGapSeconds, speakerCacheMaximumFrameCount: cacheFrameCount,
                                     fifoMaximumFrameCount: fifoFrameCount)
    }

    private func makeBatch(
        audioSequence: Int = 1, processedFrameCount: UInt64 = 1, frameCount: Int = 1, speakerCount: Int = 4,
        frameDurationSeconds: Double = Double(Float(0.08)), probabilities: [Float] = [0, 0.25, 0.5, 1],
        segments: [OmniXPCSortformerSegment] = []
    ) throws -> OmniXPCSortformerProbabilityBatch {
        try OmniXPCSortformerProbabilityBatch(serviceInstanceID: serviceInstanceID, modelID: modelID, streamID: streamID,
                                             audioSequence: audioSequence, processedFrameCount: processedFrameCount,
                                             frameCount: frameCount, speakerCount: speakerCount, frameDurationSeconds: frameDurationSeconds,
                                             probabilities: probabilities, segments: segments)
    }

    private func json(_ fields: [String: String], replacing field: String, with value: String) -> Data {
        var fields = fields
        fields[field] = value
        return json(fields)
    }

    private func json(_ fields: [String: String]) -> Data {
        Data(("{" + fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}").utf8)
    }

    private func assertInvalidFields(
        _ fields: [String: String], code: OmniXPCFailure.Code = .incompatibleService, decode: (Data) throws -> Void
    ) {
        assertFailure(code) { try decode(json(fields, replacing: "unknown", with: "0")) }
        for field in fields.keys {
            assertFailure(code) { try decode(json(fields.filter { $0.key != field })) }
            for value in ["null", "true", "\"invalid\"", "{}"] {
                assertFailure(code) { try decode(json(fields, replacing: field, with: value)) }
            }
        }
    }

    private func assertFailure(
        _ code: OmniXPCFailure.Code = .incompatibleService, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as NSError).domain, "Voxt.Omni.XPC", file: file, line: line)
            XCTAssertEqual((error as NSError).code, code.rawValue, file: file, line: line)
        }
    }
}
