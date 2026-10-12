import Foundation
import OmniModelArtifacts
import XCTest
#if OMNI_SORTFORMER_PORTABLE_TESTS
import MLXAudioVAD
#endif

@testable import Voxt

@MainActor
final class MeetingSortformerModelStorageTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voxt-sortformer-readers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelStorageDirectoryManager.setAuthorizedRootURLForTesting(root)
        directory = try XCTUnwrap(MeetingSortformerModelStorage.writeModelDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
    }

    override func tearDown() async throws {
        ModelStorageDirectoryManager.resetForTesting()
        try FileManager.default.removeItem(at: root)
    }

    func testValidatedReaderExcludesDeleteAndReleasesWithoutMovingModel() async throws {
        var reader = try await MeetingSortformerModelStorage.validatedModelDirectoryLease()
        XCTAssertEqual(reader?.directory.path, directory.resolvingSymlinksInPath().path)
        do {
            try await ModelDiskOperations.removeModelDirectories([directory])
            XCTFail("A validated reader did not exclude deletion")
        } catch OmniModelStorageError.busy {}
        reader = nil
        try await ModelDiskOperations.removeModelDirectories([directory])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMutationRejectsModelAcquisitionBeforeValidationOrLoading() async throws {
        let mutation = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        do {
            _ = try await MeetingSortformerModelStorage.validatedModelDirectoryLease()
            XCTFail("A mutating model was selected")
        } catch OmniModelStorageError.busy {}
        withExtendedLifetime(mutation) {}
    }

    func testInvalidPresenceAndMissingDirectoryReleaseReaders() async throws {
        try Data("broken".utf8).write(to: directory.appendingPathComponent("config.json"))
        let invalid = try await MeetingSortformerModelStorage.validatedModelDirectoryLease()
        XCTAssertNil(invalid)
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        try FileManager.default.removeItem(at: directory)
        let missing = try await MeetingSortformerModelStorage.validatedModelDirectoryLease()
        XCTAssertNil(missing)
    }

    func testCancelledSelectionDoesNotLeaveAReader() async throws {
        let selection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingSortformerModelStorage.validatedModelDirectoryLease()
        }
        do { _ = try await selection.value; XCTFail("Cancelled selection succeeded") }
        catch is CancellationError {}
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

#if OMNI_SORTFORMER_PORTABLE_TESTS
    func testCachedLegacyModelRetainsReaderUntilItsOwnerIsDropped() async throws {
        var engine: MLXSortformerMeetingSpeakerDiarizationEngine? = MLXSortformerMeetingSpeakerDiarizationEngine()
        _ = try await engine?.diarize(asset: MeetingAudioAsset(source: .mixed, samples: [0.25],
            sampleRate: 16_000, sessionStartOffset: 0), options: .init())
        do { _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation); XCTFail("Cached model lost its reader") }
        catch OmniModelStorageError.busy {}
        engine = nil
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    func testModelDecoderFailureDoesNotStrandTheDirectoryReader() async throws {
        try Data("{\"processor_config\":{\"sampling_rate\":\"invalid\"}}".utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let engine = MLXSortformerMeetingSpeakerDiarizationEngine()
        do {
            _ = try await engine.diarizeFile(descriptors: [], loadAsset: { _ in nil }, options: .init(), progress: nil)
            XCTFail("Invalid model configuration loaded")
        } catch is DecodingError {}
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    func testFileModelAndBlockedCancellationKeepTheReaderUntilActualFeedReturns() async throws {
        await SortformerTestControl.blockNextFeed()
        let engine = MLXSortformerMeetingSpeakerDiarizationEngine()
        let descriptor = MeetingAudioAssetDescriptor(source: .mixed, sampleRate: 16_000, startSample: 0, sampleCount: 160)
        let operation = Task {
            try await engine.diarizeFile(descriptors: [descriptor], loadAsset: { descriptor in
                MeetingAudioAsset(source: descriptor.source, samples: [Float](repeating: 0.25, count: 160),
                    sampleRate: 16_000, sessionStartOffset: 0)
            }, options: .init(), progress: nil)
        }
        await SortformerTestControl.waitForFeed()
        operation.cancel()
        do { _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation); XCTFail("Cancellation freed an active reader") }
        catch OmniModelStorageError.busy {}
        await SortformerTestControl.releaseFeed()
        do { _ = try await operation.value; XCTFail("Cancelled feed succeeded") } catch is CancellationError {}
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }

    func testRealtimeResetKeepsAnInFlightModelsReaderUntilItsFeedReturns() async throws {
        await SortformerTestControl.blockNextFeed()
        let stage = MeetingRealtimeDiarizationStage()
        let segment = MeetingTranscriptSegment(id: UUID(), speaker: .me, speakerID: nil, speakerDisplayName: nil,
            audioSource: .microphone, speakerConfidence: nil, startSeconds: 0, endSeconds: 0.01,
            text: "fixture", preventsAdjacentMerge: false)
        let operation = Task {
            await stage.annotate(segment: segment, source: .microphone,
                asset: MeetingAudioAsset(source: .microphone, samples: [Float](repeating: 0.25, count: 160),
                    sampleRate: 16_000, sessionStartOffset: 0), captureMode: .microphone)
        }
        await SortformerTestControl.waitForFeed()
        await stage.reset()
        do { _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation); XCTFail("Reset freed an active reader") }
        catch OmniModelStorageError.busy {}
        await SortformerTestControl.releaseFeed()
        _ = await operation.value
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
    }
#endif
}
