import Foundation
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSileroStreamingClientTests: XCTestCase {
    @MainActor
    func testPartialFramesWholeFramesAndExplicitFinalPadding() async throws {
        let state = makeState()
        let received = try state.admit(audio: audio(sampleCount: 511), sequence: 1)
        try state.accept(batch(state, sequence: 1, processed: 0, probabilities: []), sequence: 1, receivedSampleCount: received, isFinal: false)
        let nextReceived = try state.admit(audio: audio(sampleCount: 2), sequence: 2)
        try state.accept(batch(state, sequence: 2, processed: 512, probabilities: [0.25]), sequence: 2, receivedSampleCount: nextReceived, isFinal: false)
        try state.requireReady()
        try state.accept(batch(state, sequence: 2, processed: 1024, probabilities: [0.75], isFinal: true), sequence: 2, receivedSampleCount: nextReceived, isFinal: true)
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: 3))
    }

    @MainActor
    func testContinuousDurationBeyondThirtySecondsUsesOnlyCumulativeCounts() async throws {
        let state = makeState()
        let chunk = audio(sampleCount: 32000)
        for sequence in 1...100 {
            let received = try state.admit(audio: chunk, sequence: sequence)
            let processed = received / 512 * 512
            let probabilities = Array(repeating: Float(0.5), count: Int((processed - state.processedSampleCount) / 512))
            try state.accept(batch(state, sequence: sequence, processed: processed, probabilities: probabilities), sequence: sequence, receivedSampleCount: received, isFinal: false)
        }
        XCTAssertEqual(state.receivedSampleCount, 3_200_000)
    }

    @MainActor
    func testOverlapRejectedBeforeExaminingInvalidAudio() async throws {
        let state = makeState()
        _ = try state.admit(audio: audio(sampleCount: 512), sequence: 1)
        XCTAssertThrowsError(try state.admit(audio: Data(), sequence: 99)) { error in
            XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.busy.rawValue)
        }
    }

    @MainActor
    func testRejectsInvalidAudioAndSequencesWithoutPoisoningReadyStream() async throws {
        let state = makeState()
        var nonfinite = Data()
        withUnsafeBytes(of: Float.nan.bitPattern.littleEndian) { nonfinite.append(contentsOf: $0) }
        for invalid in [Data(), Data([0]), audio(sampleCount: 32001), nonfinite] {
            XCTAssertThrowsError(try state.admit(audio: invalid, sequence: 1))
            try state.requireReady()
        }
        for sequence in [Int.min, -1, 0, 2, Int.max] {
            XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 512), sequence: sequence))
            try state.requireReady()
        }
        let received = try state.admit(audio: audio(sampleCount: 512), sequence: 1)
        try state.accept(batch(state, sequence: 1, processed: 512, probabilities: [0.5]), sequence: 1, receivedSampleCount: received, isFinal: false)
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 512), sequence: 1))
    }

    @MainActor
    func testOriginSequenceFinalityAndCumulativeDeltaMustAllMatch() async throws {
        for invalidField in 0..<7 {
            let state = makeState()
            let received = try state.admit(audio: audio(sampleCount: 512), sequence: 1)
            let invalid = OmniXPCSileroProbabilityBatch(
                serviceInstanceID: invalidField == 0 ? UUID() : state.reference.model.serviceInstanceID,
                modelID: invalidField == 1 ? UUID() : state.reference.model.modelID,
                streamID: invalidField == 2 ? UUID() : state.reference.streamID,
                audioSequence: invalidField == 3 ? 2 : 1,
                processedSampleCount: invalidField == 4 ? 1024 : 512,
                probabilities: invalidField == 5 ? [] : [0.5], isFinal: invalidField == 6
            )
            XCTAssertThrowsError(try state.accept(invalid, sequence: 1, receivedSampleCount: received, isFinal: false)) { error in
                XCTAssertEqual((error as NSError).code, OmniXPCFailure.Code.incompatibleService.rawValue)
            }
        }
    }

    @MainActor
    func testCancellationOrCloseCannotPublishLateReply() async throws {
        for closing in [false, true] {
            let state = makeState()
            let received = try state.admit(audio: audio(sampleCount: 512), sequence: 1)
            state.closing = closing
            state.terminal = !closing
            XCTAssertThrowsError(try state.accept(batch(state, sequence: 1, processed: 512, probabilities: [0.5]), sequence: 1, receivedSampleCount: received, isFinal: false))
            XCTAssertThrowsError(try state.requireReady())
        }
    }

    @MainActor
    func testSampleAndSequenceCountersFailWithoutOverflowTraps() async throws {
        let state = makeState()
        state.receivedSampleCount = UInt64.max - 511
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 512), sequence: 1))
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: 1))
        state.receivedSampleCount = 0
        state.audioSequence = Int.max
        XCTAssertThrowsError(try state.admit(audio: audio(sampleCount: 1), sequence: Int.max))
    }

    @MainActor
    func testEmptyFinishAndAlignedFinishDoNotInventProbabilities() async throws {
        for sampleCount in [0, 512] {
            let state = makeState()
            if sampleCount > 0 {
                let received = try state.admit(audio: audio(sampleCount: sampleCount), sequence: 1)
                try state.accept(batch(state, sequence: 1, processed: 512, probabilities: [0.5]), sequence: 1, receivedSampleCount: received, isFinal: false)
            }
            let final = batch(state, sequence: state.audioSequence, processed: UInt64(sampleCount), probabilities: [], isFinal: true)
            try state.accept(final, sequence: state.audioSequence, receivedSampleCount: UInt64(sampleCount), isFinal: true)
        }
    }

    @MainActor
    private func makeState() -> OmniXPCSileroStreamState {
        let model = OmniXPCSileroModelReference(modelID: UUID(), serviceInstanceID: UUID(), connectionID: UUID())
        let state = OmniXPCSileroStreamState(reference: OmniXPCSileroStreamReference(streamID: UUID(), model: model))
        state.busy = false
        return state
    }

    private func audio(sampleCount: Int) -> Data { Data(repeating: 0, count: sampleCount * 4) }

    @MainActor
    private func batch(
        _ state: OmniXPCSileroStreamState, sequence: Int, processed: UInt64, probabilities: [Float], isFinal: Bool = false
    ) -> OmniXPCSileroProbabilityBatch {
        OmniXPCSileroProbabilityBatch(
            serviceInstanceID: state.reference.model.serviceInstanceID, modelID: state.reference.model.modelID,
            streamID: state.reference.streamID, audioSequence: sequence, processedSampleCount: processed,
            probabilities: probabilities, isFinal: isFinal
        )
    }
}
