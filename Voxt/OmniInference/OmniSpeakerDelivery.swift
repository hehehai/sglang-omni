import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSpeakerInferenceEngine {
    nonisolated final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var lastAcknowledged: UInt64 = 0
        private var lastDelivered: UInt64 = 0
        private var nativeConsumed: UInt64 = 0
        private var lastBatch: Data?
        private var pending: [OmniXPCSpeakerEvent] = []
        private var pendingStringByteCount = 0
        private var hasTerminal = false
        private var snapshotFailure: NSError?
        private var isRetired = false

        func retire() {
            lock.withLock {
                isRetired = true
                lastBatch = nil
                pending.removeAll()
                pendingStringByteCount = 0
                snapshotFailure = nil
            }
        }

        func poll(reference: OmniXPCSpeakerSessionReference, stream: SpeakerCoreStream?,
                  acknowledgedSequence: UInt64, maximumEventCount: Int) throws -> Data {
            try lock.withLock {
                guard acknowledgedSequence == lastAcknowledged || acknowledgedSequence == lastDelivered else {
                    throw SpeakerCoreModel.error(.invalid)
                }
                if isRetired {
                    return try OmniXPCSpeakerBatch(session: reference, events: [], isDrained: true).encoded()
                }
                if acknowledgedSequence == lastAcknowledged, lastDelivered > lastAcknowledged, let lastBatch {
                    return lastBatch
                }
                if let snapshotFailure { throw snapshotFailure }
                guard let stream else { throw SpeakerCoreModel.error(.invalid) }
                // note (assistant): Half the string budget reserves the complete prior reply during failed next polls.
                let pendingBudget = OmniXPCSpeakerLimits.maximumBatchStringByteCount / 2
                while pending.count < maximumEventCount && !hasTerminal
                    && pendingStringByteCount <= pendingBudget - OmniXPCSpeakerLimits.maximumEventStringByteCount {
                    guard let result = try stream.poll(session: reference) else { break }
                    let event: OmniXPCSpeakerEvent
                    do {
                        event = try result.get()
                        guard nativeConsumed < UInt64.max, event.eventSequence == nativeConsumed + 1 else {
                            throw SpeakerCoreModel.error(.failed)
                        }
                    } catch {
                        snapshotFailure = error as NSError
                        throw error
                    }
                    nativeConsumed = event.eventSequence
                    pending.append(event)
                    pendingStringByteCount += Self.stringByteCount(event)
                    switch event.kind {
                    case .completed, .cancelled, .failed: hasTerminal = true
                    case .updated, .segment: break
                    }
                }
                let events = Array(pending.prefix(maximumEventCount))
                let encoded = try OmniXPCSpeakerBatch(session: reference, events: events, isDrained: false).encoded()
                // note (assistant): No ACK or replay state changes until the entire immutable wire snapshot exists.
                lastAcknowledged = acknowledgedSequence
                lastDelivered = events.last?.eventSequence ?? acknowledgedSequence
                lastBatch = encoded
                pending.removeFirst(events.count)
                pendingStringByteCount -= events.reduce(0) { $0 + Self.stringByteCount($1) }
                return encoded
            }
        }

        private static func stringByteCount(_ event: OmniXPCSpeakerEvent) -> Int {
            let textByteCount = event.text.map { $0.utf8.count + 1 } ?? 0
            return textByteCount + (event.segments ?? []).reduce(0) { total, segment in
                total + [segment.text, segment.speaker, segment.language, segment.emotion, segment.event]
                    .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count + 1 }
            }
        }
    }

    func poll(sessionReference: Data, acknowledgedEventSequence: UInt64, maximumEventCount: Int,
              lifetime: ConnectionLifetime, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        do {
            guard (1...Self.maximumPollEventCount).contains(maximumEventCount) else {
                throw SpeakerCoreModel.error(.invalid)
            }
            let reference = try OmniXPCSpeakerSessionReference.decode(sessionReference)
            try lock.withLock {
                guard lifetime.isActive, let record = lifetime.sessions[reference.sessionID],
                      record.reference == reference else { throw SpeakerCoreModel.error(.invalid) }
                guard record.isClosed || (!record.isClosing && record.isStarted && modelState == .ready) else {
                    throw SpeakerCoreModel.error(.cancelled)
                }
                guard !record.commandPending else { throw SpeakerCoreModel.error(.busy) }
                record.commandPending = true
                queue.async { [self] in
                    do {
                        let stream = try lock.withLock { () throws -> SpeakerCoreStream? in
                            guard lifetime.isActive,
                                  record.isClosed || (!record.isClosing && modelState == .ready) else {
                                throw SpeakerCoreModel.error(.cancelled)
                            }
                            return record.stream
                        }
                        let encoded = try record.delivery.poll(
                            reference: reference, stream: stream, acknowledgedSequence: acknowledgedEventSequence,
                            maximumEventCount: maximumEventCount
                        )
                        try lock.withLock {
                            record.commandPending = false
                            guard lifetime.isActive, record.isClosed || !record.isClosing else {
                                throw SpeakerCoreModel.error(.cancelled)
                            }
                        }
                        reply(encoded, nil)
                    } catch {
                        lock.withLock { record.commandPending = false }
                        reply(nil, error as NSError)
                    }
                }
            }
        } catch { reply(nil, error as NSError) }
    }
}
#endif
