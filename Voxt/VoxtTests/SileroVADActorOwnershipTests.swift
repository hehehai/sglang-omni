#if OMNI_SILERO_PORTABLE_TESTS
import Foundation
import MLXAudioVAD
import OmniModelArtifacts
import XCTest

@testable import Voxt

// Note (assistant): the portable harness uses explicit MLX/model stand-ins, not Metal inference.
@MainActor
final class SileroVADActorOwnershipTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private let samples = [Float](repeating: 0.75, count: 512)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voxt-silero-actors-\(UUID())")
        directory = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        let header = Data("{\"weight\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}".utf8)
        var headerByteCount = UInt64(header.count).littleEndian
        var weights = withUnsafeBytes(of: &headerByteCount) { Data($0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 4))
        try weights.write(to: directory.appendingPathComponent("model.safetensors"))
        SileroVADModelProvisioner.shared.configure(directory: directory)
        SileroTestControl.shared.reset()
    }

    override func tearDown() async throws {
        SileroVADModelProvisioner.shared.release()
        SileroTestControl.shared.releaseInference()
        try FileManager.default.removeItem(at: root)
    }

    func testBothCachedActorsKeepIndependentReadersAndDestroyModelsBeforeRelease() async throws {
        let streaming = ASRSileroStreamingVoiceActivityDetector()
        let offline = ASRSileroOfflineVoiceActivityDetector()
        _ = try await streaming.probability(samples: samples, sampleRate: 16_000)
        _ = try await offline.speechRanges(samples: samples, sampleRate: 16_000)
        try assertBusy()
        await streaming.unload()
        try assertBusy()
        await offline.unload()
        try assertMutable()
        XCTAssertEqual(SileroTestControl.shared.loadCount, 2)
        XCTAssertEqual(SileroTestControl.shared.destructionCount, 2)
        XCTAssertTrue(SileroTestControl.shared.events.allSatisfy { $0.1 }, "Load, inference and destruction must all hold a reader")
    }

    func testStreamingResetRetainsReaderAndModelButClearsStreamState() async throws {
        let detector = ASRSileroStreamingVoiceActivityDetector()
        let first = try await detector.probability(samples: samples, sampleRate: 16_000)
        _ = try await detector.probability(samples: samples, sampleRate: 16_000)
        await detector.reset()
        try assertBusy()
        let reset = try await detector.probability(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(first, reset)
        XCTAssertEqual(SileroTestControl.shared.loadCount, 1)
        await detector.unload()
        try assertMutable()
    }

    func testConcurrentStreamingAcquisitionsUseTheSameCachedModel() async throws {
        SileroVADModelProvisioner.shared.block()
        let detector = ASRSileroStreamingVoiceActivityDetector()
        let first = Task { try await detector.probability(samples: samples, sampleRate: 16_000, streamID: "first") }
        let second = Task { try await detector.probability(samples: samples, sampleRate: 16_000, streamID: "second") }
        try await waitUntil { SileroVADModelProvisioner.shared.waitingCount == 2 }
        SileroVADModelProvisioner.shared.release()
        let probabilities = try await (first.value, second.value)
        XCTAssertEqual(probabilities.0, probabilities.1)
        XCTAssertEqual(SileroTestControl.shared.loadCount, 1)
        try assertBusy()
        await detector.unload()
        try assertMutable()
    }

    func testConcurrentOfflineAcquisitionsUseTheSameCachedModel() async throws {
        SileroVADModelProvisioner.shared.block()
        let detector = ASRSileroOfflineVoiceActivityDetector()
        let first = Task { try await detector.speechRanges(samples: samples, sampleRate: 16_000) }
        let second = Task { try await detector.speechRanges(samples: samples, sampleRate: 16_000) }
        try await waitUntil { SileroVADModelProvisioner.shared.waitingCount == 2 }
        SileroVADModelProvisioner.shared.release()
        let ranges = try await (first.value, second.value)
        XCTAssertEqual(ranges.0, ranges.1)
        XCTAssertEqual(SileroTestControl.shared.loadCount, 1)
        await detector.unload()
        try assertMutable()
    }

    func testUnloadWhileProvisioningCannotRepopulateEitherActorCache() async throws {
        SileroVADModelProvisioner.shared.block()
        let streaming = ASRSileroStreamingVoiceActivityDetector()
        let offline = ASRSileroOfflineVoiceActivityDetector()
        let streamOperation = Task { try await streaming.probability(samples: samples, sampleRate: 16_000) }
        let offlineOperation = Task { try await offline.speechRanges(samples: samples, sampleRate: 16_000) }
        try await waitUntil { SileroVADModelProvisioner.shared.waitingCount == 2 }
        await streaming.unload()
        await offline.unload()
        SileroVADModelProvisioner.shared.release()
        do { _ = try await streamOperation.value; XCTFail("Unload resurrected the streaming cache") }
        catch is CancellationError {}
        do { _ = try await offlineOperation.value; XCTFail("Unload resurrected the offline cache") }
        catch is CancellationError {}
        XCTAssertEqual(SileroTestControl.shared.loadCount, 0)
        try assertMutable()
    }

    func testResetWhileProvisioningInvalidatesTheOldStreamingCall() async throws {
        SileroVADModelProvisioner.shared.block()
        let detector = ASRSileroStreamingVoiceActivityDetector()
        let operation = Task { try await detector.probability(samples: samples, sampleRate: 16_000) }
        try await waitUntil { SileroVADModelProvisioner.shared.waitingCount == 1 }
        await detector.reset()
        SileroVADModelProvisioner.shared.release()
        do { _ = try await operation.value; XCTFail("Reset admitted an old stream call") }
        catch is CancellationError {}
        XCTAssertEqual(SileroTestControl.shared.loadCount, 0)
        try assertMutable()
    }

    func testCancellationWhileProvisioningDoesNotLoadEitherModel() async throws {
        SileroVADModelProvisioner.shared.block()
        let streaming = ASRSileroStreamingVoiceActivityDetector()
        let offline = ASRSileroOfflineVoiceActivityDetector()
        let streamOperation = Task { try await streaming.probability(samples: samples, sampleRate: 16_000) }
        let offlineOperation = Task { try await offline.speechRanges(samples: samples, sampleRate: 16_000) }
        try await waitUntil { SileroVADModelProvisioner.shared.waitingCount == 2 }
        streamOperation.cancel()
        offlineOperation.cancel()
        SileroVADModelProvisioner.shared.release()
        do { _ = try await streamOperation.value; XCTFail("Cancelled streaming load succeeded") }
        catch is CancellationError {}
        do { _ = try await offlineOperation.value; XCTFail("Cancelled offline load succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(SileroTestControl.shared.loadCount, 0)
        try assertMutable()
    }

    func testBlockedStreamingFeedKeepsReaderDespiteCancellationAndQueuedUnload() async throws {
        SileroTestControl.shared.blockInference()
        let detector = ASRSileroStreamingVoiceActivityDetector()
        let operation = Task { try await detector.probability(samples: samples, sampleRate: 16_000) }
        try await waitUntil { SileroTestControl.shared.entered }
        operation.cancel()
        let unload = Task { await detector.unload() }
        try assertBusy()
        SileroTestControl.shared.releaseInference()
        _ = try await operation.value
        await unload.value
        try assertMutable()
        XCTAssertTrue(SileroTestControl.shared.events.allSatisfy { $0.1 })
    }

    func testBlockedOfflineInferenceKeepsReaderDespiteCancellationAndQueuedUnload() async throws {
        SileroTestControl.shared.blockInference()
        let detector = ASRSileroOfflineVoiceActivityDetector()
        let operation = Task { try await detector.speechRanges(samples: samples, sampleRate: 16_000) }
        try await waitUntil { SileroTestControl.shared.entered }
        operation.cancel()
        let unload = Task { await detector.unload() }
        try assertBusy()
        SileroTestControl.shared.releaseInference()
        _ = try await operation.value
        await unload.value
        try assertMutable()
        XCTAssertTrue(SileroTestControl.shared.events.allSatisfy { $0.1 })
    }

    func testModelLoadFailureReleasesBothReaders() async throws {
        try Data().write(to: directory.appendingPathComponent("fail-load"))
        let streaming = ASRSileroStreamingVoiceActivityDetector()
        let offline = ASRSileroOfflineVoiceActivityDetector()
        do { _ = try await streaming.probability(samples: samples, sampleRate: 16_000); XCTFail("Load should fail") }
        catch SileroFixtureError.loadFailed {}
        try assertMutable()
        do { _ = try await offline.speechRanges(samples: samples, sampleRate: 16_000); XCTFail("Load should fail") }
        catch SileroFixtureError.loadFailed {}
        try assertMutable()
        XCTAssertTrue(SileroTestControl.shared.events.allSatisfy { $0.1 })
    }

    func testInferenceFailureKeepsCachedReaderUntilUnload() async throws {
        try Data().write(to: directory.appendingPathComponent("fail-inference"))
        let streaming = ASRSileroStreamingVoiceActivityDetector()
        let offline = ASRSileroOfflineVoiceActivityDetector()
        do { _ = try await streaming.probability(samples: samples, sampleRate: 16_000); XCTFail("Feed should fail") }
        catch SileroFixtureError.inferenceFailed {}
        do { _ = try await offline.speechRanges(samples: samples, sampleRate: 16_000); XCTFail("Inference should fail") }
        catch SileroFixtureError.inferenceFailed {}
        try assertBusy()
        await streaming.unload()
        try assertBusy()
        await offline.unload()
        try assertMutable()
    }

    func testDroppingActorsReleasesCachedModelsBeforeReaders() async throws {
        var streaming: ASRSileroStreamingVoiceActivityDetector? = ASRSileroStreamingVoiceActivityDetector()
        var offline: ASRSileroOfflineVoiceActivityDetector? = ASRSileroOfflineVoiceActivityDetector()
        _ = try await streaming?.probability(samples: samples, sampleRate: 16_000)
        _ = try await offline?.speechRanges(samples: samples, sampleRate: 16_000)
        streaming = nil
        offline = nil
        try assertMutable()
        XCTAssertEqual(SileroTestControl.shared.destructionCount, 2)
        XCTAssertTrue(SileroTestControl.shared.events.allSatisfy { $0.1 })
    }

    func testMutationPreventsBothActorLoads() async throws {
        let mutation = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        defer { withExtendedLifetime(mutation) {} }
        let streaming = ASRSileroStreamingVoiceActivityDetector()
        let offline = ASRSileroOfflineVoiceActivityDetector()
        do { _ = try await streaming.probability(samples: samples, sampleRate: 16_000); XCTFail("Mutation admitted a load") }
        catch OmniModelStorageError.busy {}
        do { _ = try await offline.speechRanges(samples: samples, sampleRate: 16_000); XCTFail("Mutation admitted a load") }
        catch OmniModelStorageError.busy {}
        XCTAssertEqual(SileroTestControl.shared.loadCount, 0)
    }

    private func assertBusy(file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
            XCTFail("An active Silero model lost its reader", file: file, line: line)
        } catch OmniModelStorageError.busy {}
    }

    private func assertMutable() throws {
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "Timed out waiting for the fixture barrier")
    }
}
#endif
