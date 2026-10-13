import Foundation
import OmniModelArtifacts
import XCTest

@testable import Voxt

@MainActor
final class MeetingSortformerModelStorageTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUp() async throws {
        root = try TestDoubles.canonicalTemporaryDirectory().appendingPathComponent("voxt-sortformer-readers-\(UUID())")
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
        XCTAssertEqual(reader?.directory.path, try TestDoubles.canonicalFileURL(for: directory).path)
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

}
