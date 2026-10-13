import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
nonisolated final class SpeakerCoreModel: @unchecked Sendable {
    let kind: OmniXPCSpeakerKind
    private let lock = NSLock()
    private var directoryLease: OmniModelDirectoryLease?
    private var handle: OpaquePointer?
    private var streamLeaseCount = 0
    private var loadReturned = false

    init(kind: OmniXPCSpeakerKind) { self.kind = kind }

    func load(directoryLease: OmniModelDirectoryLease) throws {
        try lock.withLock {
            precondition(self.directoryLease == nil && !loadReturned)
            self.directoryLease = directoryLease
            defer { loadReturned = true }
            guard Int(omni_core_abi_version()) == OmniXPCProtocolLimits.abiVersion,
                  OmniXPCProtocolLimits.abiVersion == 10 else {
                throw OmniXPCFailure.error(.incompatibleService, "The Native Core ABI is incompatible.")
            }
            var created: OpaquePointer?
            let status = omni_speaker_create(kind.rawValue, directoryLease.directory.path, &created)
            handle = created
            try Self.check(status)
            guard handle != nil else { throw Self.error(.failed) }
        }
    }

    func reserveStream() throws -> OpaquePointer {
        try lock.withLock {
            guard loadReturned, let handle else { throw Self.error(.invalid) }
            guard streamLeaseCount == 0 else { throw Self.error(.busy) }
            streamLeaseCount = 1
            return handle
        }
    }

    func releaseStream() {
        lock.withLock {
            precondition(streamLeaseCount == 1)
            streamLeaseCount = 0
        }
    }

    func close() throws {
        try lock.withLock {
            guard streamLeaseCount == 0 else { throw Self.error(.busy) }
            // note (assistant): The engine queue joins load before even a nil handle can retire its reader.
            try Self.check(omni_speaker_destroy_checked(handle))
            handle = nil
            directoryLease = nil
        }
    }

    static func check(_ status: Int32) throws {
        guard status == OMNI_BATCH_OK else {
            throw error(OmniXPCSpeakerStatus(rawValue: status) ?? .failed)
        }
    }

    static func error(_ status: OmniXPCSpeakerStatus) -> NSError {
        NSError(domain: "Voxt.Omni.XPC.Speaker", code: Int(status.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Native speaker operation did not complete (status \(status.rawValue))."])
    }

    deinit { precondition(handle == nil && directoryLease == nil && streamLeaseCount == 0) }
}
#endif
