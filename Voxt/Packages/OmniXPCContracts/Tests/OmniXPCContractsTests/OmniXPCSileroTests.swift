import Foundation
import XCTest
import OmniXPCContracts

final class OmniXPCSileroTests: XCTestCase {
    private let serviceInstanceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let modelID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let requestID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let connectionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let settingsJSON = """
        {"threshold":0.25,"minimumSpeechMilliseconds":123,"minimumSilenceMilliseconds":456,"speechPaddingMilliseconds":789}
        """

    func testSettingsRoundTripPreservesExplicitValues() throws {
        let settings = OmniXPCSileroSettings(
            threshold: 0.25, minimumSpeechMilliseconds: 123,
            minimumSilenceMilliseconds: 456, speechPaddingMilliseconds: 789
        )
        try settings.validate()
        XCTAssertEqual(try OmniXPCSileroSettings.decode(Data(settingsJSON.utf8)), settings)
        let bytes = try settings.encoded()
        XCTAssertEqual(try OmniXPCSileroSettings.decode(bytes), settings)
        XCTAssertEqual(try settings.encoded(), bytes)
        XCTAssertLessThanOrEqual(bytes.count, OmniXPCSileroLimits.maximumSettingsByteCount)
    }

    func testSettingsAcceptInclusiveThresholdAndIndependentMillisecondLimits() throws {
        for threshold: Float in [0, .leastNonzeroMagnitude, 0.5, 1] {
            for milliseconds in [0, 1, OmniXPCSileroLimits.maximumOptionMilliseconds] {
                for settings in [
                    OmniXPCSileroSettings(threshold: threshold, minimumSpeechMilliseconds: milliseconds,
                                         minimumSilenceMilliseconds: 0, speechPaddingMilliseconds: 0),
                    OmniXPCSileroSettings(threshold: threshold, minimumSpeechMilliseconds: 0,
                                         minimumSilenceMilliseconds: milliseconds, speechPaddingMilliseconds: 0),
                    OmniXPCSileroSettings(threshold: threshold, minimumSpeechMilliseconds: 0,
                                         minimumSilenceMilliseconds: 0, speechPaddingMilliseconds: milliseconds),
                ] {
                    try settings.validate()
                    XCTAssertEqual(try OmniXPCSileroSettings.decode(settings.encoded()), settings)
                }
            }
        }
    }

    func testSettingsRejectNonfiniteAndOutOfRangeThresholdsBeforeEncoding() {
        for threshold: Float in [-.leastNonzeroMagnitude, -1, Float(1).nextUp, .greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            let settings = OmniXPCSileroSettings(
                threshold: threshold, minimumSpeechMilliseconds: 0,
                minimumSilenceMilliseconds: 0, speechPaddingMilliseconds: 0
            )
            assertFailure(.invalidRequest) { try settings.validate() }
            assertFailure(.invalidRequest) { _ = try settings.encoded() }
        }
    }

    func testSettingsRejectEachOutOfRangeMillisecondOption() {
        for milliseconds in [Int.min, -1, OmniXPCSileroLimits.maximumOptionMilliseconds + 1, Int.max] {
            for settings in [
                OmniXPCSileroSettings(threshold: 0.5, minimumSpeechMilliseconds: milliseconds,
                                     minimumSilenceMilliseconds: 0, speechPaddingMilliseconds: 0),
                OmniXPCSileroSettings(threshold: 0.5, minimumSpeechMilliseconds: 0,
                                     minimumSilenceMilliseconds: milliseconds, speechPaddingMilliseconds: 0),
                OmniXPCSileroSettings(threshold: 0.5, minimumSpeechMilliseconds: 0,
                                     minimumSilenceMilliseconds: 0, speechPaddingMilliseconds: milliseconds),
            ] {
                assertFailure(.invalidRequest) { try settings.validate() }
                assertFailure(.invalidRequest) { _ = try settings.encoded() }
            }
        }
    }

    func testSettingsDecodeRejectsInvalidJSONAndUnknownFields() {
        for json in ["", "null", "[]", "{}", "true", "1", "{", settingsJSON + "false",
                     settingsJSON.replacingOccurrences(of: "}", with: ",\"unknown\":0}")] {
            assertFailure(.invalidRequest) { _ = try OmniXPCSileroSettings.decode(Data(json.utf8)) }
        }
    }

    func testSettingsDecodeRequiresAllFieldsWithNumericTypesAndValidDomains() {
        let fieldValues = [
            ("threshold", "0.25"), ("minimumSpeechMilliseconds", "123"),
            ("minimumSilenceMilliseconds", "456"), ("speechPaddingMilliseconds", "789"),
        ]
        for (field, value) in fieldValues {
            let remainingFields = fieldValues.filter { $0.0 != field }.map { "\"\($0.0)\":\($0.1)" }
            let missingField = "{" + remainingFields.joined(separator: ",") + "}"
            assertFailure(.invalidRequest) { _ = try OmniXPCSileroSettings.decode(Data(missingField.utf8)) }
            for replacement in ["null", "true", "\"\(value)\"", "[]", "{}", "-1", "30001", "1e1000"] {
                let json = settingsJSON.replacingOccurrences(of: "\"\(field)\":\(value)", with: "\"\(field)\":\(replacement)")
                assertFailure(.invalidRequest) { _ = try OmniXPCSileroSettings.decode(Data(json.utf8)) }
            }
        }
        for (field, value) in fieldValues.dropFirst() {
            let json = settingsJSON.replacingOccurrences(of: "\"\(field)\":\(value)", with: "\"\(field)\":123.5")
            assertFailure(.invalidRequest) { _ = try OmniXPCSileroSettings.decode(Data(json.utf8)) }
        }
        for threshold in ["1.01", "-0.01", "\"NaN\"", "\"Infinity\""] {
            let json = settingsJSON.replacingOccurrences(of: "0.25", with: threshold)
            assertFailure(.invalidRequest) { _ = try OmniXPCSileroSettings.decode(Data(json.utf8)) }
        }
    }

    func testSettingsDecodeEnforcesExactByteBudget() throws {
        var bytes = Data(settingsJSON.utf8)
        bytes.append(Data(repeating: 0x20, count: OmniXPCSileroLimits.maximumSettingsByteCount - bytes.count))
        XCTAssertEqual(try OmniXPCSileroSettings.decode(bytes), try OmniXPCSileroSettings.decode(Data(settingsJSON.utf8)))
        bytes.append(0x20)
        assertFailure(.invalidRequest) { _ = try OmniXPCSileroSettings.decode(bytes) }
    }

    func testSileroModelReferencePreservesAllThreeIdentities() {
        let reference = OmniXPCSileroModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: connectionID)
        XCTAssertEqual(reference.modelID, modelID)
        XCTAssertEqual(reference.serviceInstanceID, serviceInstanceID)
        XCTAssertEqual(reference.connectionID, connectionID)
        XCTAssertEqual(reference, OmniXPCSileroModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: connectionID))
        XCTAssertNotEqual(reference, OmniXPCSileroModelReference(modelID: requestID, serviceInstanceID: serviceInstanceID, connectionID: connectionID))
        XCTAssertNotEqual(reference, OmniXPCSileroModelReference(modelID: modelID, serviceInstanceID: requestID, connectionID: connectionID))
        XCTAssertNotEqual(reference, OmniXPCSileroModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: requestID))
    }

    func testTimestampBatchRoundTripPreservesIdentitiesAndSampleUnits() throws {
        let timestamps = [
            OmniXPCSileroTimestamp(startSample: 0, endSample: 1),
            OmniXPCSileroTimestamp(startSample: 1, endSample: 32),
            OmniXPCSileroTimestamp(startSample: 100, endSample: 480_000),
        ]
        let batch = makeBatch(sampleCount: 480_000, timestamps: timestamps)
        let bytes = try batch.encoded()
        let decoded = try OmniXPCSileroTimestampBatch.decode(bytes)
        XCTAssertEqual(decoded, batch)
        XCTAssertEqual(decoded.serviceInstanceID, serviceInstanceID)
        XCTAssertEqual(decoded.modelID, modelID)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.sampleCount, 480_000)
        XCTAssertEqual(decoded.timestamps, timestamps)
        XCTAssertEqual(try batch.encoded(), bytes)
        XCTAssertEqual(try OmniXPCSileroTimestampBatch.decode(Data(batchJSON(
            sampleCount: "480000", timestamps: "[{\"startSample\":0,\"endSample\":1},{\"startSample\":1,\"endSample\":32},{\"startSample\":100,\"endSample\":480000}]"
        ).utf8)), batch)
    }

    func testEmptyTimestampBatchRepresentsNoSpeechForNonemptyAudio() throws {
        for sampleCount in [1, OmniXPCProtocolLimits.maximumSampleCount] {
            let batch = makeBatch(sampleCount: sampleCount, timestamps: [])
            XCTAssertEqual(try OmniXPCSileroTimestampBatch.decode(batch.encoded()), batch)
        }
    }

    func testTimestampBatchAcceptsMaximumTimestampCountAndSampleCount() throws {
        let timestamps = (0..<OmniXPCSileroLimits.maximumTimestampCount).map { index in
            OmniXPCSileroTimestamp(
                startSample: Int64(index * 512),
                endSample: Int64(min((index + 1) * 512, OmniXPCProtocolLimits.maximumSampleCount))
            )
        }
        let batch = makeBatch(sampleCount: OmniXPCProtocolLimits.maximumSampleCount, timestamps: timestamps)
        let bytes = try batch.encoded()
        XCTAssertLessThanOrEqual(bytes.count, OmniXPCSileroLimits.maximumTimestampBatchByteCount)
        XCTAssertEqual(try OmniXPCSileroTimestampBatch.decode(bytes), batch)
    }

    func testTimestampBatchRejectsExcessTimestampCountOnEncodeAndDecode() throws {
        let timestampCount = OmniXPCSileroLimits.maximumTimestampCount + 1
        let timestamps = (0..<timestampCount).map { OmniXPCSileroTimestamp(startSample: Int64($0), endSample: Int64($0 + 1)) }
        let batch = makeBatch(sampleCount: timestampCount, timestamps: timestamps)
        assertFailure(.incompatibleService) { _ = try batch.encoded() }
        let bytes = try JSONEncoder().encode(batch)
        XCTAssertLessThan(bytes.count, OmniXPCSileroLimits.maximumTimestampBatchByteCount)
        assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(bytes) }
    }

    func testTimestampBatchRejectsInvalidSampleCountOnEncodeAndDecode() throws {
        for sampleCount in [Int.min, -1, 0, OmniXPCProtocolLimits.maximumSampleCount + 1, Int.max] {
            let batch = makeBatch(sampleCount: sampleCount, timestamps: [])
            assertFailure(.incompatibleService) { _ = try batch.encoded() }
            let bytes = try JSONEncoder().encode(batch)
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(bytes) }
        }
    }

    func testTimestampBatchRejectsNegativeEmptyReversedOverlappingAndUnorderedRanges() throws {
        let invalidRanges: [[OmniXPCSileroTimestamp]] = [
            [.init(startSample: -1, endSample: 1)],
            [.init(startSample: 0, endSample: 0)],
            [.init(startSample: 2, endSample: 1)],
            [.init(startSample: 0, endSample: 101)],
            [.init(startSample: Int64.min, endSample: Int64.max)],
            [.init(startSample: Int64.max - 1, endSample: Int64.max)],
            [.init(startSample: 1, endSample: 5), .init(startSample: 4, endSample: 7)],
            [.init(startSample: 1, endSample: 5), .init(startSample: 1, endSample: 5)],
            [.init(startSample: 10, endSample: 20), .init(startSample: 0, endSample: 5)],
        ]
        for timestamps in invalidRanges {
            let batch = makeBatch(sampleCount: 100, timestamps: timestamps)
            assertFailure(.incompatibleService) { _ = try batch.encoded() }
            let bytes = try JSONEncoder().encode(batch)
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(bytes) }
        }
    }

    func testTimestampBatchDecodeEnforcesExactByteBudget() throws {
        let batch = makeBatch(sampleCount: 1, timestamps: [])
        var bytes = try batch.encoded()
        bytes.append(Data(repeating: 0x20, count: OmniXPCSileroLimits.maximumTimestampBatchByteCount - bytes.count))
        XCTAssertEqual(try OmniXPCSileroTimestampBatch.decode(bytes), batch)
        bytes.append(0x20)
        assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(bytes) }
    }

    func testTimestampBatchDecodeRejectsInvalidShapeAndUUIDs() {
        let json = batchJSON(sampleCount: "1", timestamps: "[]")
        for invalidJSON in ["", "null", "[]", "{}", "true", "1", "{", json + "false",
                            json.replacingOccurrences(of: "}", with: ",\"unknown\":0}")] {
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(invalidJSON.utf8)) }
        }
        for (field, value) in [("serviceInstanceID", serviceInstanceID), ("modelID", modelID), ("requestID", requestID)] {
            let missingField = json.replacingOccurrences(of: "\"\(field)\":\"\(value.uuidString)\",", with: "")
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(missingField.utf8)) }
            for replacement in ["null", "1", "true", "[]", "{}", "\"not-a-uuid\""] {
                let invalidJSON = json.replacingOccurrences(of: "\"\(value.uuidString)\"", with: replacement)
                assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(invalidJSON.utf8)) }
            }
        }
        for field in ["\"sampleCount\":1,", ",\"timestamps\":[]"] {
            let missingField = json.replacingOccurrences(of: field, with: "")
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(missingField.utf8)) }
        }
        for sampleCount in ["null", "true", "\"1\"", "1.5", "1e1000", "[]", "{}"] {
            let invalidJSON = batchJSON(sampleCount: sampleCount, timestamps: "[]")
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(invalidJSON.utf8)) }
        }
    }

    func testTimestampBatchDecodeRejectsInvalidTimestampFieldsAndNonintegerSamples() {
        let timestampJSON = "{\"startSample\":0,\"endSample\":10}"
        for timestamps in ["null", "true", "{}", "1", "\"[]\"", "[null]", "[[]]", "[{}]",
                           "[{\"startSample\":0}]", "[{\"endSample\":1}]",
                           "[{\"startSample\":0,\"endSample\":1,\"seconds\":0}]"] {
            let json = batchJSON(sampleCount: "10", timestamps: timestamps)
            assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(json.utf8)) }
        }
        for (field, value) in [("startSample", "0"), ("endSample", "10")] {
            for replacement in ["null", "true", "\"1\"", "0.5", "[]", "{}", "9223372036854775808", "1e1000"] {
                let timestamp = timestampJSON.replacingOccurrences(of: "\"\(field)\":\(value)", with: "\"\(field)\":\(replacement)")
                let json = batchJSON(sampleCount: "10", timestamps: "[\(timestamp)]")
                assertFailure(.incompatibleService) { _ = try OmniXPCSileroTimestampBatch.decode(Data(json.utf8)) }
            }
        }
    }

    func testOfflineLimitsLeaveCoreABIAndSharedAudioAndRequestLimitsUnchanged() {
        XCTAssertEqual(OmniXPCSileroLimits.maximumSettingsByteCount, 1024)
        XCTAssertEqual(OmniXPCSileroLimits.maximumTimestampBatchByteCount, 65_536)
        XCTAssertEqual(OmniXPCSileroLimits.maximumTimestampCount, 938)
        XCTAssertEqual(OmniXPCSileroLimits.maximumOptionMilliseconds, 30_000)
        XCTAssertEqual(OmniXPCProtocolLimits.abiVersion, 4)
        XCTAssertEqual(OmniXPCProtocolLimits.sampleRate, 16_000)
        XCTAssertEqual(OmniXPCProtocolLimits.maximumSampleCount, 480_000)
        XCTAssertEqual(OmniXPCProtocolLimits.maximumRequestsPerModel, 256)
    }

    private func makeBatch(sampleCount: Int, timestamps: [OmniXPCSileroTimestamp]) -> OmniXPCSileroTimestampBatch {
        OmniXPCSileroTimestampBatch(
            serviceInstanceID: serviceInstanceID, modelID: modelID, requestID: requestID,
            sampleCount: sampleCount, timestamps: timestamps
        )
    }

    private func batchJSON(sampleCount: String, timestamps: String) -> String {
        """
        {"serviceInstanceID":"\(serviceInstanceID.uuidString)","modelID":"\(modelID.uuidString)","requestID":"\(requestID.uuidString)","sampleCount":\(sampleCount),"timestamps":\(timestamps)}
        """
    }

    private func assertFailure(
        _ code: OmniXPCFailure.Code, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "Voxt.Omni.XPC", file: file, line: line)
            XCTAssertEqual(failure.code, code.rawValue, file: file, line: line)
        }
    }
}
