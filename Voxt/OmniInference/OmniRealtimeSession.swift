/// Serial-queue event retention: a terminal ACK releases the lease only after Native drain.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class OmniRealtimeSession: @unchecked Sendable {
    struct DrainedIdentity: Sendable {
        let sessionID: UUID
        let modelID: UUID
        let ownerID: UUID
        let acknowledgedEventSequence: Int
        let encodedBatch: Data
    }

    private struct PendingBatch {
        let encodedBatch: Data
        let eventCount: Int
        let lastEventSequence: Int
        let maximumEventCount: Int
        let containsTerminal: Bool
    }

    let sessionID: UUID
    let modelID: UUID
    let ownerID: UUID
    let lease: QwenCoreRealtimeLease
    // note (assistant): Only admission fields use the engine lock; event and ACK state belongs to its serial queue.
    var isClosing = false
    var reservedAudioByteCount = 0
    private(set) var lastAcceptedAudioSequence = 0
    private(set) var drainedIdentity: DrainedIdentity?
    var isDrained: Bool { drainedIdentity != nil }
    private var acknowledgedEventSequence = 0
    private var terminalAcknowledged = false
    private var retainedEvents: [OmniXPCRealtimeEvent] = []
    private var pendingBatch: PendingBatch?

    init(sessionID: UUID, modelID: UUID, ownerID: UUID, lease: QwenCoreRealtimeLease) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.ownerID = ownerID
        self.lease = lease
    }

    func push(audio: Data, sequence: Int) throws -> Int {
        guard !isDrained, lastAcceptedAudioSequence < Int.max, sequence == lastAcceptedAudioSequence + 1 else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime audio sequence is stale or out of order.")
        }
        let samples = try OmniXPCRequestValidation.samples(
            audio: audio, language: nil, context: nil, maximumTokenCount: 1
        )
        let acceptedSequence = try lease.push(samples: samples, sequence: sequence)
        lastAcceptedAudioSequence = acceptedSequence
        return acceptedSequence
    }

    func poll(acknowledgedEventSequence requestedACK: Int, maximumEventCount: Int) throws -> Data {
        guard !isDrained,
              (1...OmniXPCProtocolLimits.maximumRealtimeEventsPerBatch).contains(maximumEventCount) else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime poll count or session state is invalid.")
        }
        if let pendingBatch {
            if requestedACK == acknowledgedEventSequence {
                guard maximumEventCount == pendingBatch.maximumEventCount else {
                    throw OmniXPCFailure.error(.invalidRequest, "A pending realtime batch must be retried with the same count.")
                }
                return pendingBatch.encodedBatch
            } else if requestedACK == pendingBatch.lastEventSequence {
                acknowledgedEventSequence = requestedACK
                terminalAcknowledged = pendingBatch.containsTerminal
                retainedEvents.removeFirst(pendingBatch.eventCount)
                self.pendingBatch = nil
            } else {
                throw OmniXPCFailure.error(.invalidRequest, "The realtime ACK must acknowledge exactly the pending batch.")
            }
        } else {
            guard requestedACK == acknowledgedEventSequence else {
                throw OmniXPCFailure.error(.invalidRequest, "The realtime ACK is stale or ahead of delivered events.")
            }
        }
        if terminalAcknowledged {
            return try drain().encodedBatch
        }
        if retainedEvents.isEmpty {
            for _ in 0..<maximumEventCount {
                guard let event = try lease.poll() else { break }
                retainedEvents.append(event)
                if event.kind == .completed || event.kind == .cancelled || event.kind == .failed { break }
            }
        }
        guard !retainedEvents.isEmpty else {
            return try encode(events: [], isDrained: false)
        }
        // note (assistant): JSON escaping can exceed the wire budget; never drop already-polled suffix events.
        var eventCount = min(retainedEvents.count, maximumEventCount)
        while true {
            do {
                let events = Array(retainedEvents.prefix(eventCount))
                let encodedBatch = try encode(events: events, isDrained: false)
                let last = events.last!
                pendingBatch = PendingBatch(
                    encodedBatch: encodedBatch, eventCount: eventCount, lastEventSequence: last.sequence,
                    maximumEventCount: maximumEventCount,
                    containsTerminal: last.kind == .completed || last.kind == .cancelled || last.kind == .failed
                )
                return encodedBatch
            } catch {
                guard eventCount > 1 else { throw error }
                eventCount -= 1
            }
        }
    }

    func drain() throws -> DrainedIdentity {
        if let drainedIdentity { return drainedIdentity }
        let encodedBatch = try encode(events: [], isDrained: true)
        try lease.drainAndDestroy()
        let identity = DrainedIdentity(
            sessionID: sessionID, modelID: modelID, ownerID: ownerID,
            acknowledgedEventSequence: acknowledgedEventSequence, encodedBatch: encodedBatch
        )
        drainedIdentity = identity
        pendingBatch = nil
        retainedEvents.removeAll(keepingCapacity: false)
        return identity
    }

    private func encode(events: [OmniXPCRealtimeEvent], isDrained: Bool) throws -> Data {
        try OmniXPCRealtimeCodec.encode(OmniXPCRealtimeBatch(
            sessionID: sessionID, modelID: modelID, serviceInstanceID: OmniFinalSessionEngine.serviceInstanceID,
            events: events, isDrained: isDrained
        ))
    }
}
#endif
