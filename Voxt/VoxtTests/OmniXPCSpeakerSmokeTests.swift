#if OMNI_XPC_PORTABLE_TESTS && VOXT_OMNI_XPC_VALIDATION
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

nonisolated final class OmniXPCSpeakerSmokeTests: XCTestCase {
    @MainActor
    func testExplicitKindInputsAreCanonicalAndOptionalAsAGroup() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        let expected = fixture.directory.appendingPathComponent("expected.txt")
        try Data("fixture 世界".utf8).write(to: expected)
        let fields = ["VOXT_OMNI_XPC_SMOKE_SPEAKER_KIND", "VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE",
                      "VOXT_OMNI_XPC_SMOKE_SPEAKER_EXPECTED_SOURCE"]
        let environment = Dictionary(uniqueKeysWithValues: zip(fields, ["1", fixture.directory.path, expected.path]))
        XCTAssertNil(try OmniXPCSmokeSpeakerValidation.kind(environment: [:]))
        XCTAssertEqual(try OmniXPCSmokeSpeakerValidation.kind(environment: environment), .moss)
        XCTAssertEqual(try OmniXPCSmokeSpeakerValidation.kind(environment: environment.merging([fields[0]: "2"], uniquingKeysWith: { _, new in new })), .nemotron)
        for value in ["0", "3", "01", "+1", "moss", " 1", "١"] {
            XCTAssertThrowsError(try OmniXPCSmokeSpeakerValidation.kind(environment: environment.merging([fields[0]: value], uniquingKeysWith: { _, new in new })))
        }
        for field in fields {
            var partial = environment
            partial.removeValue(forKey: field)
            XCTAssertThrowsError(try OmniXPCSmokeSpeakerValidation.kind(environment: partial))
        }
        try await fixture.owner.close()
    }

    @MainActor
    func testExpectedSnapshotRejectsInvalidUtf8EmptyAndOversize() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        let expected = fixture.directory.appendingPathComponent("expected.txt")
        let environment = ["VOXT_OMNI_XPC_SMOKE_SPEAKER_KIND": "1",
            "VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE": fixture.directory.path,
            "VOXT_OMNI_XPC_SMOKE_SPEAKER_EXPECTED_SOURCE": expected.path]
        for bytes in [Data(), Data(" \n".utf8), Data([255]), Data(repeating: 65, count: 65537)] {
            try bytes.write(to: expected)
            XCTAssertThrowsError(try OmniXPCSmokeSpeakerValidation.kind(environment: environment))
        }
        try Data(repeating: 65, count: 65536).write(to: expected)
        XCTAssertEqual(try OmniXPCSmokeSpeakerValidation.kind(environment: environment), .moss)
        try await fixture.owner.close()
    }

    @MainActor
    func testActualSmokeCallerUsesASRConsumerAndCheckedOriginalOwnerClose() async throws {
        let fixture = try OmniXPCSpeakerFixture()
        defer { fixture.dispose() }
        let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.host"))
        let identifier = UUID()
        let model = container.appendingPathComponent("Models/OmniXPCSpeakerSmoke/\(identifier.uuidString)")
        let artifacts = container.appendingPathComponent("OmniXPCSmoke/\(identifier.uuidString)")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for name in ["config.json", "model.safetensors"] {
            try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent(name), to: model.appendingPathComponent(name))
        }
        try Data("fixture 世界".utf8).write(to: artifacts.appendingPathComponent("speaker-expected.txt"))
        fixture.peer.removesAcknowledgedEvents = true
        fixture.peer.completionText = "fixture 世界"
        let running = Task {
            try await OmniXPCSmokeSpeakerValidation.run(client: fixture.client, kind: .moss, container: container,
                identifier: identifier, samples: [0.25], timeout: .seconds(5))
        }
        try await speakerWait { fixture.peer.drainOperations.count == 1 }
        XCTAssertTrue(OmniXPCSmokeSpeakerValidation.hasRetainedOwner)
        XCTAssertThrowsError(try OmniModelDirectoryLease.acquire(for: model, mode: .exclusiveMutation))
        fixture.peer.completeControlledWork()
        try await running.value
        XCTAssertFalse(OmniXPCSmokeSpeakerValidation.hasRetainedOwner)
        XCTAssertEqual(fixture.peer.finishCount, 1)
        XCTAssertEqual(fixture.peer.acknowledgedDrains, 1)
        let writer = try OmniModelDirectoryLease.acquire(for: model, mode: .exclusiveMutation)
        withExtendedLifetime(writer) {}
        try await fixture.owner.close()
        try FileManager.default.removeItem(at: model)
        try FileManager.default.removeItem(at: artifacts)
    }
}
#endif
