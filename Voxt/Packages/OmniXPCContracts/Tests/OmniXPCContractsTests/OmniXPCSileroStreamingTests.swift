import Foundation
import XCTest
import OmniXPCContracts

final class OmniXPCSileroStreamingTests: XCTestCase {
    private let serviceInstanceID = UUID()
    private let modelID = UUID()
    private let streamID = UUID()

    func testStreamReferencePreservesOriginModel() {
        let model = OmniXPCSileroModelReference(modelID: modelID, serviceInstanceID: serviceInstanceID, connectionID: UUID())
        let reference = OmniXPCSileroStreamReference(streamID: streamID, model: model)
        XCTAssertEqual(reference.streamID, streamID)
        XCTAssertEqual(reference.model, model)
        XCTAssertNotEqual(reference, OmniXPCSileroStreamReference(streamID: UUID(), model: model))
    }

    func testStreamingLimitsPreserveSileroBudgetsWithCurrentCoreABI() {
        XCTAssertEqual(OmniXPCSileroLimits.frameSampleCount, 512)
        XCTAssertEqual(OmniXPCSileroLimits.maximumChunkSampleCount, 32000)
        XCTAssertEqual(OmniXPCSileroLimits.maximumStreamCount, 16)
        XCTAssertEqual(OmniXPCSileroLimits.maximumProbabilityCount, 63)
        XCTAssertEqual(OmniXPCSileroLimits.maximumProbabilityBatchByteCount, 4096)
        XCTAssertEqual(OmniXPCProtocolLimits.maximumRequestsPerModel, 256)
        XCTAssertEqual(OmniXPCProtocolLimits.maximumSampleCount, 480000)
        XCTAssertEqual(OmniXPCProtocolLimits.abiVersion, 7)
    }

    func testRoundTripPreservesFieldsAndAcceptsEmptyActiveAndFinalBatches() throws {
        for isFinal in [false, true] {
            for probabilities: [Float] in [[], [0], [0.25], [1]] {
                let batch = makeBatch(sequence: isFinal ? 0 : 1, processed: 512, probabilities: probabilities, isFinal: isFinal)
                let bytes = try batch.encoded()
                XCTAssertEqual(try OmniXPCSileroProbabilityBatch.decode(bytes), batch)
                XCTAssertEqual(try batch.encoded(), bytes)
            }
        }
    }

    func testMaximumActiveCountAndUnboundedCumulativeDuration() throws {
        for processed in [UInt64(0), 512, 480256, UInt64.max - 511] {
            let batch = makeBatch(sequence: Int.max, processed: processed, probabilities: Array(repeating: 0.5, count: 63))
            XCTAssertEqual(try OmniXPCSileroProbabilityBatch.decode(batch.encoded()), batch)
        }
    }

    func testInvalidSequencesAlignmentAndCounts() throws {
        let invalid = [
            makeBatch(sequence: 0), makeBatch(sequence: -1), makeBatch(sequence: Int.min),
            makeBatch(sequence: -1, isFinal: true), makeBatch(processed: 1),
            makeBatch(processed: UInt64.max), makeBatch(probabilities: Array(repeating: 0, count: 64)),
            makeBatch(probabilities: [0, 1], isFinal: true),
        ]
        for batch in invalid {
            assertMalformed { _ = try batch.encoded() }
            let bytes = try JSONEncoder().encode(batch)
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(bytes) }
        }
    }

    func testNonfiniteAndOutOfRangeProbabilities() throws {
        for probability: Float in [-1, -.leastNonzeroMagnitude, Float(1).nextUp, .nan, .infinity, -.infinity] {
            let batch = makeBatch(probabilities: [probability])
            assertMalformed { _ = try batch.encoded() }
        }
        for value in ["-0.1", "1.1", "1e1000", "\"NaN\"", "\"Infinity\"", "true", "null", "{}", "[]"] {
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(wire(probabilities: "[\(value)]")) }
        }
    }

    func testStrictJSONKeysShapeAndUUIDs() throws {
        let valid = String(decoding: wire(), as: UTF8.self)
        for json in ["", "null", "[]", "{}", "true", "1", "{", valid + "false",
                     valid.replacingOccurrences(of: "}", with: ",\"extra\":0}")] {
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(Data(json.utf8)) }
        }
        let fields = [
            "serviceInstanceID": "\"\(serviceInstanceID.uuidString)\"", "modelID": "\"\(modelID.uuidString)\"",
            "streamID": "\"\(streamID.uuidString)\"", "audioSequence": "1", "processedSampleCount": "512",
            "probabilities": "[0.25]", "isFinal": "false",
        ]
        for (field, value) in fields {
            let missing = "{" + fields.filter { $0.key != field }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(Data(missing.utf8)) }
            for replacement in ["null", "{}", "\"invalid\""] {
                let json = valid.replacingOccurrences(of: "\"\(field)\":\(value)", with: "\"\(field)\":\(replacement)")
                assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(Data(json.utf8)) }
            }
        }
        for value in ["true", "-1", "0.5", "18446744073709551616", "1e1000", "\"512\""] {
            let json = valid.replacingOccurrences(of: "\"processedSampleCount\":512", with: "\"processedSampleCount\":\(value)")
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(Data(json.utf8)) }
        }
        for value in ["true", "0.5", "9223372036854775808", "1e1000", "\"1\""] {
            let json = valid.replacingOccurrences(of: "\"audioSequence\":1", with: "\"audioSequence\":\(value)")
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(Data(json.utf8)) }
        }
        for value in ["1", "0", "\"false\"", "[]"] {
            let json = valid.replacingOccurrences(of: "\"isFinal\":false", with: "\"isFinal\":\(value)")
            assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(Data(json.utf8)) }
        }
    }

    func testCountIsRejectedBeforeDecodingProbabilityElements() {
        for (count, isFinal) in [(64, false), (2, true)] {
            let probabilities = "[" + Array(repeating: "{}", count: count).joined(separator: ",") + "]"
            XCTAssertThrowsError(try JSONDecoder().decode(
                OmniXPCSileroProbabilityBatch.self, from: wire(probabilities: probabilities, isFinal: isFinal)
            )) { error in
                XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue)
                XCTAssertTrue(error.localizedDescription.contains("count exceeds"))
            }
        }
    }

    func testExactByteBudgetBeforeJSONDecoding() throws {
        let batch = makeBatch(probabilities: [0.25])
        var bytes = try batch.encoded()
        bytes.append(Data(repeating: 0x20, count: 4096 - bytes.count))
        XCTAssertEqual(try OmniXPCSileroProbabilityBatch.decode(bytes), batch)
        bytes.append(0x20)
        assertMalformed { _ = try OmniXPCSileroProbabilityBatch.decode(bytes) }
    }

    private func makeBatch(
        sequence: Int = 1, processed: UInt64 = 512, probabilities: [Float] = [], isFinal: Bool = false
    ) -> OmniXPCSileroProbabilityBatch {
        OmniXPCSileroProbabilityBatch(
            serviceInstanceID: serviceInstanceID, modelID: modelID, streamID: streamID,
            audioSequence: sequence, processedSampleCount: processed, probabilities: probabilities, isFinal: isFinal
        )
    }

    private func wire(probabilities: String = "[0.25]", isFinal: Bool = false) -> Data {
        Data("""
        {"serviceInstanceID":"\(serviceInstanceID.uuidString)","modelID":"\(modelID.uuidString)","streamID":"\(streamID.uuidString)","audioSequence":1,"processedSampleCount":512,"probabilities":\(probabilities),"isFinal":\(isFinal)}
        """.utf8)
    }

    private func assertMalformed(file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as NSError).domain, "Voxt.Omni.XPC", file: file, line: line)
            XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue, file: file, line: line)
        }
    }
}
