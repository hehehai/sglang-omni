/// Engine-lock-owned stream admission, processed-frame progress, and one exact-byte replay cache.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniSortformerStream: @unchecked Sendable {
    enum State { case creating, ready, failed, cancelled }

    let id: UUID
    let modelID: UUID
    let ownerID: UUID
    let lease: SortformerCoreStreamLease
    var state: State = .creating
    var isBusy = true
    var isClosePending = false
    var lastSequence = 0
    var processedFrameCount: UInt64 = 0
    var lastAudio: Data?
    var lastReply: Data?

    init(id: UUID, modelID: UUID, ownerID: UUID, lease: SortformerCoreStreamLease) {
        self.id = id
        self.modelID = modelID
        self.ownerID = ownerID
        self.lease = lease
    }

    func requireReady() throws {
        guard !isBusy, !isClosePending else {
            throw OmniXPCFailure.error(.busy, "The Sortformer stream already has a pending command.")
        }
        guard state == .ready else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream is not active; close it before continuing.")
        }
    }
}
#endif
