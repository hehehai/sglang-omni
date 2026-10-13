#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

@MainActor
func makeSileroOwnerFixture() throws -> (OmniXPCClient, SileroOwnerTestPeer, URL) {
    let peer = SileroOwnerTestPeer()
    NSXPCConnection.setup = { $0.exportedObject = peer }
    let container = try XCTUnwrap(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.test.silero"))
    let bundleDirectory = container.appendingPathComponent("Host-" + UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleDirectory) }
    let properties = ["CFBundleIdentifier": "test.silero.host", "OmniAppGroupIdentifier": "group.test.silero",
                      "OmniInferenceServiceIdentifier": "test.silero.service", "OmniHostBundleIdentifier": "test.silero.host",
                      "OmniTeamIdentifier": "TESTTEAM01"]
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        .write(to: bundleDirectory.appendingPathComponent("Info.plist"))
    let client = try OmniXPCClient(bundle: XCTUnwrap(Bundle(url: bundleDirectory)))
    let directory = container.appendingPathComponent("Models/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
    let header = Data("{\"weight\":{\"dtype\":\"F32\",\"shape\":[1],\"data_offsets\":[0,4]}}".utf8)
    var weights = withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) }
    weights.append(header)
    weights.append(Data(repeating: 0, count: 4))
    try weights.write(to: directory.appendingPathComponent("model.safetensors"))
    return (client, peer, directory)
}

func assertSileroReaderBusy(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    do {
        _ = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
        XCTFail("Reader released before native retirement", file: file, line: line)
    } catch OmniModelStorageError.busy {}
}

@MainActor
func awaitSileroCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SileroOwnerTestFailure.deadline }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
func assertSileroLaneBlocked(_ coordinator: MeetingLocalInferenceCoordinator) async throws {
    var probeRan = false
    let probe = Task {
        try await coordinator.withPermit(.liveASRFinal) { await MainActor.run { probeRan = true } }
    }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(probeRan)
    probe.cancel()
    do { try await probe.value; XCTFail("Cancelled blocked probe succeeded") } catch is CancellationError {}
}

enum SileroOwnerTestFailure: Error { case deadline }
#endif
