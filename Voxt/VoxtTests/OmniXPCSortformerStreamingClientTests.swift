import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSortformerStreamingClientTests: XCTestCase {
    @MainActor
    func testNativeFrameShapeIncludesCenteredFeatureFrameAndCeilingSubsampling() async throws {
        for (sampleCount, frameCount) in [(1, 1), (159, 1), (160, 1), (1279, 1), (1280, 2), (31999, 25), (32000, 26)] {
            let state = makeState()
            try state.admit(audio: audio(sampleCount: sampleCount), sequence: 1)
            let reply = try batch(state, sequence: 1, processedFrameCount: UInt64(frameCount), frameCount: frameCount)
            try state.accept(reply, sequence: 1)
            XCTAssertEqual(state.processedFrameCount, UInt64(frameCount))
            XCTAssertEqual(reply.probabilities.count, frameCount * 4)
            try state.requireReady()
        }
    }

    @MainActor
    func testProgressIsPerChunkFramesNotCumulativeSampleAlignment() async throws {
        let state = makeState()
        for sequence in 1...100 {
            try state.admit(audio: audio(sampleCount: 32000), sequence: sequence)
            try state.accept(batch(state, sequence: sequence, processedFrameCount: UInt64(sequence * 26), frameCount: 26), sequence: sequence)
        }
        XCTAssertEqual(state.processedFrameCount, 2600)
        try state.admit(audio: audio(sampleCount: 1), sequence: 101)
        try state.accept(batch(state, sequence: 101, processedFrameCount: 2601), sequence: 101)
        try state.admit(audio: audio(sampleCount: 1), sequence: 102)
        try state.accept(batch(state, sequence: 102, processedFrameCount: 2602), sequence: 102)
    }

    @MainActor
    func testInvalidAudioAndSequenceDoNotConsumeAdmission() async throws {
        let state = makeState()
        let invalidAudio = [Data(), Data([0]), Data(repeating: 0, count: 7), audio(sampleCount: 32001)]
            + [Float.nan, .infinity, -.infinity].map { value in
                withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) }
            }
        for invalid in invalidAudio {
            XCTAssertThrowsError(try state.admit(audio: invalid, sequence: 1))
            try state.requireReady()
            XCTAssertEqual(state.audioSequence, 0)
        }
        for sequence in [Int.min, -1, 0, 2, Int.max] {
            XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: sequence))
            try state.requireReady()
        }
        try state.admit(audio: audio(sampleCount: 1), sequence: 1)
        try state.accept(batch(state, sequence: 1, processedFrameCount: 1), sequence: 1)
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: 1))
        try state.requireReady()
    }

    @MainActor
    func testOverlapRejectedBeforeExaminingAudioAndUnsolicitedReplyRejected() async throws {
        let state = makeState()
        XCTAssertThrowsError(try state.accept(batch(state, sequence: 1, processedFrameCount: 1), sequence: 1))
        try state.admit(audio: audio(sampleCount: 1), sequence: 1)
        XCTAssertThrowsError(try state.admit(audio: Data(), sequence: 99)) { error in
            XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue)
        }
        try state.accept(batch(state, sequence: 1, processedFrameCount: 1), sequence: 1)
        XCTAssertThrowsError(try state.accept(batch(state, sequence: 1, processedFrameCount: 1), sequence: 1))
    }

    @MainActor
    func testEveryIdentitySequenceAndFrameDeltaMustMatch() async throws {
        for invalidField in 0..<6 {
            let state = makeState()
            try state.admit(audio: audio(sampleCount: 1), sequence: 1)
            let frameCount = invalidField == 5 ? 2 : 1
            let invalid = try OmniXPCSortformerProbabilityBatch(
                serviceInstanceID: invalidField == 0 ? UUID() : state.reference.model.serviceInstanceID,
                modelID: invalidField == 1 ? UUID() : state.reference.model.modelID,
                streamID: invalidField == 2 ? UUID() : state.reference.streamID,
                audioSequence: invalidField == 3 ? 2 : 1,
                processedFrameCount: invalidField >= 4 ? 2 : 1, frameCount: frameCount,
                speakerCount: 4, frameDurationSeconds: OmniXPCSortformerLimits.frameDurationSeconds,
                probabilities: Array(repeating: 0.25, count: frameCount * 4), segments: []
            )
            XCTAssertThrowsError(try state.accept(invalid, sequence: 1)) { error in
                XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue)
            }
            XCTAssertEqual(state.processedFrameCount, 0)
            XCTAssertEqual(state.audioSequence, 0)
        }
    }

    @MainActor
    func testCumulativeFrameCounterCannotRegressOrSkip() async throws {
        let state = makeState()
        try state.admit(audio: audio(sampleCount: 1), sequence: 1)
        try state.accept(batch(state, sequence: 1, processedFrameCount: 1), sequence: 1)
        try state.admit(audio: audio(sampleCount: 1), sequence: 2)
        for processedFrameCount: UInt64 in [1, 3, UInt64(Int32.max)] {
            XCTAssertThrowsError(try state.accept(batch(state, sequence: 2, processedFrameCount: processedFrameCount), sequence: 2))
        }
        try state.accept(batch(state, sequence: 2, processedFrameCount: 2), sequence: 2)
    }

    @MainActor
    func testFrameAndSequenceCountersFailWithoutOverflowTraps() async throws {
        let state = makeState()
        for processedFrameCount in [UInt64.max, OmniXPCSortformerLimits.maximumProcessedFrameCount] {
            state.processedFrameCount = processedFrameCount
            XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: 1))
            try state.requireReady()
        }
        state.processedFrameCount = OmniXPCSortformerLimits.maximumProcessedFrameCount - 1
        try state.admit(audio: audio(sampleCount: 1), sequence: 1)
        try state.accept(batch(state, sequence: 1, processedFrameCount: OmniXPCSortformerLimits.maximumProcessedFrameCount), sequence: 1)
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: 2))
        state.processedFrameCount = 0
        state.audioSequence = Int.max
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: Int.max))
    }

    @MainActor
    func testTerminalOrClosingStateCannotPublishLateBatch() async throws {
        for closing in [false, true] {
            let state = makeState()
            try state.admit(audio: audio(sampleCount: 1), sequence: 1)
            state.closing = closing
            state.terminal = !closing
            XCTAssertThrowsError(try state.accept(batch(state, sequence: 1, processedFrameCount: 1), sequence: 1))
            XCTAssertThrowsError(try state.requireReady())
            XCTAssertEqual(state.audioSequence, 0)
        }
    }

    @MainActor
    func testActualDTOKeepsRowMajorProbabilitiesAndAbsoluteSeconds() async throws {
        let state = makeState()
        state.processedFrameCount = 100_001
        try state.admit(audio: audio(sampleCount: 1280), sequence: 1)
        let durationSeconds = OmniXPCSortformerLimits.frameDurationSeconds
        let startSeconds = Float(100_001) * Float(durationSeconds)
        let segment = try OmniXPCSortformerSegment(
            startSeconds: Double(startSeconds), endSeconds: Double(startSeconds + 2 * Float(durationSeconds)), speakerIndex: 3
        )
        let reply = try OmniXPCSortformerProbabilityBatch(
            serviceInstanceID: state.reference.model.serviceInstanceID, modelID: state.reference.model.modelID,
            streamID: state.reference.streamID, audioSequence: 1, processedFrameCount: 100_003,
            frameCount: 2, speakerCount: 4, frameDurationSeconds: durationSeconds,
            probabilities: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], segments: [segment]
        )
        let decoded = try OmniXPCSortformerProbabilityBatch.decode(reply.encoded())
        XCTAssertEqual(decoded, reply)
        try state.accept(decoded, sequence: 1)
        XCTAssertEqual(decoded.segments[0].speakerIndex, 3)
        XCTAssertEqual(decoded.frameDurationSeconds, Double(Float(0.01) * 8))
    }

    @MainActor
    func testActualDTODecoderRejectsMalformedShapeUUIDUnitsAndUnknownFields() async throws {
        let state = makeState()
        let valid = try batch(state, sequence: 1, processedFrameCount: 1).encoded()
        let json = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let mutations = [
            (state.reference.streamID.uuidString, "invalid-uuid"),
            ("\"speakerCount\":4", "\"speakerCount\":3"),
            ("\"frameCount\":1", "\"frameCount\":2"),
            ("\"audioSequence\":1", "\"audioSequence\":0"),
            ("\"processedFrameCount\":1", "\"processedFrameCount\":2147483648"),
            ("\"probabilities\":[0.25,0.25,0.25,0.25]", "\"probabilities\":[0.25]"),
            ("\"segments\":[]", "\"segments\":[],\"isFinal\":true"),
            ("\"frameDurationSeconds\":\(OmniXPCSortformerLimits.frameDurationSeconds)", "\"frameDurationSeconds\":80")
        ]
        for (original, replacement) in mutations {
            XCTAssertTrue(json.contains(original), original)
            XCTAssertThrowsError(try OmniXPCSortformerProbabilityBatch.decode(Data(json.replacingOccurrences(of: original, with: replacement).utf8)))
        }
        XCTAssertThrowsError(try OmniXPCSortformerProbabilityBatch.decode(Data(repeating: 0, count: 32769)))
    }

    @MainActor
    private func makeState() -> OmniXPCSortformerStreamState {
        let model = OmniXPCSortformerModelReference(modelID: UUID(), serviceInstanceID: UUID(), connectionID: UUID())
        let state = OmniXPCSortformerStreamState(reference: OmniXPCSortformerStreamReference(streamID: UUID(), model: model))
        state.busy = false
        return state
    }

    private func audio(sampleCount: Int) -> Data { Data(repeating: 0, count: sampleCount * 4) }

    @MainActor
    private func batch(
        _ state: OmniXPCSortformerStreamState, sequence: Int, processedFrameCount: UInt64, frameCount: Int = 1
    ) throws -> OmniXPCSortformerProbabilityBatch {
        try OmniXPCSortformerProbabilityBatch(
            serviceInstanceID: state.reference.model.serviceInstanceID, modelID: state.reference.model.modelID,
            streamID: state.reference.streamID, audioSequence: sequence, processedFrameCount: processedFrameCount,
            frameCount: frameCount, speakerCount: 4, frameDurationSeconds: OmniXPCSortformerLimits.frameDurationSeconds,
            probabilities: Array(repeating: 0.25, count: frameCount * 4), segments: []
        )
    }
}
