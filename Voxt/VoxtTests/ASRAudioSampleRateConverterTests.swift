import Foundation
import MLXAudioCore
import XCTest
@testable import Voxt

final class ASRAudioSampleRateConverterTests: XCTestCase {
    func testEmptyAndEqualRateInputsPreserveEarlyReturnBeforeValidation() throws {
        for (sourceSampleRate, targetSampleRate) in [(48_000, 16_000), (0, -1), (-1, 0)] {
            XCTAssertEqual(
                try ASRAudioSampleRateConverter.resample(samples: [], from: sourceSampleRate, to: targetSampleRate),
                try resampleAudio([], from: sourceSampleRate, to: targetSampleRate)
            )
        }
        let samples: [Float] = [0, -0.0, .nan, .infinity, -.infinity, 0.5]
        for sampleRate in [16_000, 0, -1] {
            let output = try ASRAudioSampleRateConverter.resample(samples: samples, from: sampleRate, to: sampleRate)
            XCTAssertEqual(output.map(\.bitPattern), samples.map(\.bitPattern))
            samples.withUnsafeBufferPointer { inputPointer in
                output.withUnsafeBufferPointer { outputPointer in
                    XCTAssertEqual(inputPointer.baseAddress, outputPointer.baseAddress)
                }
            }
        }
    }

    func testInvalidUnequalRatesKeepFailureDescription() {
        for (sourceSampleRate, targetSampleRate) in [(0, 16_000), (-1, 16_000), (16_000, 0), (16_000, -1)] {
            XCTAssertThrowsError(try resampleAudio([0, 1], from: sourceSampleRate, to: targetSampleRate)) { error in
                XCTAssertEqual(error.localizedDescription, "Audio resampling failed.")
            }
            XCTAssertThrowsError(
                try ASRAudioSampleRateConverter.resample(samples: [0, 1], from: sourceSampleRate, to: targetSampleRate)
            ) { error in
                XCTAssertEqual(error as? ASRAudioSampleRateConverter.ConversionError, .resamplingFailed)
                XCTAssertEqual(error.localizedDescription, "Audio resampling failed.")
            }
        }
    }

    func testConversionMatchesAudioCoreAcrossRatesAndFrameBoundaries() throws {
        for (sourceSampleRate, targetSampleRate) in [
            (48_000, 16_000), (44_100, 16_000), (22_050, 16_000), (8_000, 16_000), (16_000, 48_000)
        ] {
            for sampleCount in [1, 2, 63, 64, 127, 1_024, 4_097] {
                let samples: [Float] = (0..<sampleCount).map { sampleIndex in
                    let timeSeconds = Double(sampleIndex) / Double(sourceSampleRate)
                    return Float(0.5 * sin(2 * .pi * 440 * timeSeconds) + 0.2 * cos(2 * .pi * 3_100 * timeSeconds))
                }
                let expected = try resampleAudio(samples, from: sourceSampleRate, to: targetSampleRate)
                let actual = try ASRAudioSampleRateConverter.resample(
                    samples: samples, from: sourceSampleRate, to: targetSampleRate
                )
                XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern),
                               "\(sampleCount) frames, \(sourceSampleRate) -> \(targetSampleRate)")
            }
        }
    }

    func testSilenceConstantAndImpulseMatchAudioCore() throws {
        var impulseSamples = Array(repeating: Float.zero, count: 4_099)
        impulseSamples[2_049] = 1
        let signals = [Array(repeating: Float.zero, count: 4_099),
                       Array(repeating: Float(0.25), count: 4_099), impulseSamples]
        for samples in signals {
            let expected = try resampleAudio(samples, from: 44_100, to: 16_000)
            let actual = try ASRAudioSampleRateConverter.resample(samples: samples, from: 44_100, to: 16_000)
            XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern))
        }
    }

    func testDetachedPreparationPreservesOneHertzToleranceAndSharedStorage() throws {
        let samples: [Float] = [0, -0.0, .nan, .infinity, 0.5]
        for sampleRate in [15_999.0, 15_999.5, 16_000.0, 16_000.5, 16_001.0] {
            let output = try MLXTranscriber.prepareInputSamplesDetached(samples, sampleRate: sampleRate, targetSampleRate: 16_000)
            XCTAssertEqual(output.map(\.bitPattern), samples.map(\.bitPattern))
            samples.withUnsafeBufferPointer { inputPointer in
                output.withUnsafeBufferPointer { outputPointer in
                    XCTAssertEqual(inputPointer.baseAddress, outputPointer.baseAddress)
                }
            }
        }
    }

    func testDetachedPreparationKeepsIntegerRateTruncation() throws {
        let samples = (0..<4_097).map { Float($0 % 17) / 17 }
        for sampleRate in [44_100.9, 48_000.75, 16_001.01, 15_998.99] {
            let expected = try resampleAudio(samples, from: Int(sampleRate), to: 16_000)
            let actual = try MLXTranscriber.prepareInputSamplesDetached(samples, sampleRate: sampleRate, targetSampleRate: 16_000)
            XCTAssertEqual(actual.map(\.bitPattern), expected.map(\.bitPattern))
        }
    }
}
