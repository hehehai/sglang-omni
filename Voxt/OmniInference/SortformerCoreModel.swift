/// Retains the ABI5 model and its directory reader until every Native stream lease has drained.
import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
nonisolated final class SortformerCoreModel: @unchecked Sendable {
    private let lock = NSLock()
    private var directoryLease: OmniModelDirectoryLease?
    private var handle: OpaquePointer?
    private var streamLeaseCount = 0

    init(directoryLease: OmniModelDirectoryLease) throws {
        guard Int(omni_core_abi_version()) == OmniXPCProtocolLimits.abiVersion else {
            throw OmniXPCFailure.error(.incompatibleService, "The Native Core ABI is incompatible.")
        }
        self.directoryLease = directoryLease
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        handle = omni_sortformer_create(directoryLease.directory.path, &errorMessage)
        guard handle != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Sortformer model could not be loaded.")
        }
    }

    func registerStreamLease() -> OpaquePointer {
        lock.withLock {
            precondition(handle != nil && streamLeaseCount < OmniXPCSortformerLimits.maximumStreamCount)
            streamLeaseCount += 1
            return handle!
        }
    }

    func releaseStreamLease() {
        lock.withLock {
            precondition(streamLeaseCount > 0)
            streamLeaseCount -= 1
        }
    }

    func close() {
        let released = lock.withLock {
            precondition(streamLeaseCount == 0)
            let released = (handle, directoryLease)
            handle = nil
            directoryLease = nil
            return released
        }
        withExtendedLifetime(released.1) {
            if let releasedHandle = released.0 { omni_sortformer_destroy(releasedHandle) }
        }
    }

    deinit { precondition(handle == nil && streamLeaseCount == 0) }
}
#endif
