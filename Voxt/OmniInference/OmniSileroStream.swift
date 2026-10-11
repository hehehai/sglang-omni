/// Engine-lock-owned stream state; counters describe received audio and inferred whole frames separately.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniSileroStream: @unchecked Sendable {
    enum State { case creating, ready, failed, cancelled }
    struct CompletedReply {
        let streamID: UUID
        let modelID: UUID
        let ownerID: UUID
        let encodedBatch: Data
    }

    let id: UUID
    let modelID: UUID
    let ownerID: UUID
    let lease: SileroCoreStreamLease
    var state: State = .creating
    var isBusy = true
    var isClosePending = false
    var lastSequence = 0
    var receivedSampleCount: UInt64 = 0
    var processedSampleCount: UInt64 = 0
    var lastAudio: Data?
    var lastReply: Data?

    init(id: UUID, modelID: UUID, ownerID: UUID, lease: SileroCoreStreamLease) {
        self.id = id
        self.modelID = modelID
        self.ownerID = ownerID
        self.lease = lease
    }

    func requireReady() throws {
        guard !isBusy, !isClosePending else {
            throw OmniXPCFailure.error(.busy, "The Silero stream already has a pending command.")
        }
        guard state == .ready else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream is not active; close it before continuing.")
        }
    }

    func nextReceivedSampleCount(adding sampleCount: Int) throws -> UInt64 {
        let (receivedSampleCount, overflow) = self.receivedSampleCount.addingReportingOverflow(UInt64(sampleCount))
        guard !overflow else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream sample counter is full.")
        }
        // note (assistant): Reserve the final padded frame before admitting audio, not after Native inference.
        _ = try finalProcessedSampleCount(receivedSampleCount: receivedSampleCount)
        return receivedSampleCount
    }

    func finalProcessedSampleCount(receivedSampleCount: UInt64) throws -> UInt64 {
        let frameSampleCount = UInt64(OmniXPCSileroLimits.frameSampleCount)
        let paddingSampleCount = (frameSampleCount - receivedSampleCount % frameSampleCount) % frameSampleCount
        let (processedSampleCount, overflow) = receivedSampleCount.addingReportingOverflow(paddingSampleCount)
        guard !overflow else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream padded sample counter is full.")
        }
        return processedSampleCount
    }
}
#endif
