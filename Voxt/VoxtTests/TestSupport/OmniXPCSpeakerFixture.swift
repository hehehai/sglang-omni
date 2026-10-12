#if OMNI_XPC_PORTABLE_TESTS
import Foundation
import OmniModelArtifacts
import OmniXPCContracts
import XCTest
@testable import Voxt

@MainActor
final class OmniXPCSpeakerFixture {
    static var unprovenOwners: [OmniXPCSpeakerFixture] = []
    let client: OmniXPCClient
    let directory: URL
    let peer: OmniXPCSpeakerTestPeer
    let hooks = OmniXPCSpeakerCacheHooks()
    let coordinator: MeetingLocalInferenceCoordinator
    let owner: OmniXPCSpeakerModelOwner
    let audio = [Float(0.25).bitPattern.littleEndian].withUnsafeBytes { Data($0) }
    var probeRan = false

    init(kind: OmniXPCSpeakerKind = .moss, workClass: MeetingLocalInferenceWorkClass = .fileASR) throws {
        let (client, directory, base) = try makeBatchFixture()
        self.client = client
        self.directory = directory
        peer = OmniXPCSpeakerTestPeer(base: base)
        NSXPCConnection.setup = { [peer] in $0.exportedObject = peer }
        coordinator = MeetingLocalInferenceCoordinator(beginFileWorkUnit: { [hooks] in hooks.begin() },
            readThermalState: { [hooks] in hooks.thermalState })
        owner = OmniXPCSpeakerModelOwner(client: client, kind: kind, modelDirectory: directory,
            coordinator: coordinator, workClass: workClass)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        let header = Data(#"{"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var weights = [UInt64(header.count).littleEndian].withUnsafeBytes { Data($0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 4))
        try weights.write(to: directory.appendingPathComponent("model.safetensors"))
    }

    func dispose() {
        NSXPCConnection.setup = nil
        if !owner.isClosed {
            XCTAssertTrue(owner.hasPendingCleanup, "Unproven cleanup must stay quarantined")
            Self.unprovenOwners.append(self)
        } else {
            client.invalidate()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func assertReader(pinned: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        do {
            let writer = try OmniModelDirectoryLease.acquire(for: directory, mode: .exclusiveMutation)
            XCTAssertFalse(pinned, "Writer acquired before checked model drain", file: file, line: line)
            withExtendedLifetime(writer) {}
        } catch OmniModelStorageError.busy {
            XCTAssertTrue(pinned, "Reader survived confirmed model drain", file: file, line: line)
        }
    }

    func blockedProbe() async throws -> Task<Void, Error> {
        let submitted = await coordinator.currentStatistics().submittedCount
        probeRan = false
        let probe = Task {
            try await self.coordinator.withPermit(.liveASRFinal) {
                await MainActor.run { self.probeRan = true }
            }
        }
        try await speakerWait { await self.coordinator.currentStatistics().submittedCount == submitted + 1 }
        XCTAssertFalse(probeRan)
        return probe
    }
}

nonisolated final class OmniXPCSpeakerCacheHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0, restores = 0
    private var critical = false
    var beginCount: Int { lock.withLock { begins } }
    var restoreCount: Int { lock.withLock { restores } }
    var thermalState: ProcessInfo.ThermalState { lock.withLock { critical ? .critical : .nominal } }
    func constrainThermalState() { lock.withLock { critical = true } }
    func begin() -> @Sendable () -> Void {
        lock.withLock { begins += 1 }
        return { self.lock.withLock { self.restores += 1 } }
    }
}

@MainActor
func speakerWait(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await condition()) {
        guard Date() < deadline else { throw OmniXPCFailure.error(.timedOut, "Test gate did not open") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
func speakerFailure(code: OmniXPCFailure.Code? = nil, file: StaticString = #filePath, line: UInt = #line,
                    _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
    catch {
        if let code {
            XCTAssertEqual((error as NSError).domain, OmniXPCFailure.error(code, "").domain, file: file, line: line)
            XCTAssertEqual((error as NSError).code, code.rawValue, file: file, line: line)
        }
    }
}
#endif
