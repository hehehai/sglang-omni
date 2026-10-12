import Foundation
import OmniModelArtifacts
import OmniXPCContracts

#if os(macOS)
nonisolated final class BatchCoreModel: @unchecked Sendable {
    let kind: OmniXPCBatchKind
    private var directoryLease: OmniModelDirectoryLease?
    private var handle: OpaquePointer?
    private var requestLeaseCount = 0

    init(kind: OmniXPCBatchKind, directoryLease: OmniModelDirectoryLease) throws {
        guard Int(omni_core_abi_version()) == OmniXPCProtocolLimits.abiVersion else {
            throw OmniXPCFailure.error(.incompatibleService, "The Native Core ABI is incompatible.")
        }
        self.kind = kind
        self.directoryLease = directoryLease
        try Self.check(omni_batch_create(Int32(kind.rawValue), directoryLease.directory.path, &handle))
        guard handle != nil else { throw OmniXPCBatchFailure.error(.failed) }
    }

    func createRequest() throws -> OpaquePointer {
        guard let handle else { throw OmniXPCBatchFailure.error(.invalid) }
        var request: OpaquePointer?
        try Self.check(omni_batch_request_create(handle, &request))
        guard let request else { throw OmniXPCBatchFailure.error(.failed) }
        requestLeaseCount += 1
        return request
    }

    func releaseRequest() {
        precondition(requestLeaseCount > 0)
        requestLeaseCount -= 1
    }

    func close() throws {
        guard requestLeaseCount == 0 else { throw OmniXPCBatchFailure.error(.busy) }
        guard let handle else { return }
        try Self.check(omni_batch_destroy_checked(handle))
        self.handle = nil
        directoryLease = nil
    }

    static func check(_ status: Int32) throws {
        guard status == OMNI_BATCH_OK else {
            throw OmniXPCBatchFailure.error(OmniXPCBatchFailure.Code(rawValue: Int(status)) ?? .failed)
        }
    }

    deinit { precondition(handle == nil && requestLeaseCount == 0) }
}
#endif
