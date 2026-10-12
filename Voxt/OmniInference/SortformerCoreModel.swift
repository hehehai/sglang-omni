/// Retains the ABI6 model reader until stream leases and checked model destruction complete.
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

    func close() throws {
        let closingHandle = lock.withLock {
            precondition(streamLeaseCount == 0)
            return handle
        }
        guard let closingHandle else { return }
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        guard omni_sortformer_destroy_checked(closingHandle, &errorMessage) == 1, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Sortformer model destruction did not complete.")
        }
        lock.withLock {
            handle = nil
            directoryLease = nil
        }
    }

    deinit { precondition(handle == nil && streamLeaseCount == 0) }
}
#endif
