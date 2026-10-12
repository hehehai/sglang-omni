import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSpeakerInferenceEngine {
    nonisolated final class SessionRecord: @unchecked Sendable {
        let reference: OmniXPCSpeakerSessionReference
        var stream: SpeakerCoreStream?
        var isStarted = false
        var isClosing = false
        var isCancelled = false
        var isClosed = false
        var closePending = false
        var commandPending = false
        let delivery = Delivery()

        init(reference: OmniXPCSpeakerSessionReference, stream: SpeakerCoreStream?) {
            self.reference = reference
            self.stream = stream
        }
    }

    func start(sessionID: String, modelReference: Data, settings: Data, lifetime: ConnectionLifetime,
               reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        do {
            let sessionID = try identifier(sessionID)
            let reference = try OmniXPCSpeakerModelReference.decode(modelReference)
            let settings = try OmniXPCSpeakerSettings.decode(settings)
            try settings.validate(for: reference)
            try lock.withLock {
                try requireOwner(lifetime, reference: reference)
                guard modelState == .ready, session == nil, let model else { throw SpeakerCoreModel.error(.busy) }
                guard nextNativeSessionID < UInt64.max else { throw SpeakerCoreModel.error(.limit) }
                try lifetime.recordBusiness(sessionID, kind: .session)
                let sessionReference = try OmniXPCSpeakerSessionReference(sessionID: sessionID, model: reference)
                let shell = SpeakerCoreStream(model: model, nativeSessionID: nextNativeSessionID)
                nextNativeSessionID += 1
                let record = SessionRecord(reference: sessionReference, stream: shell)
                lifetime.sessions[sessionID] = record
                session = record
                queue.async { [self] in
                    do {
                        guard lock.withLock({ lifetime.isActive && modelState == .ready && !record.isClosing && !record.isCancelled }) else {
                            throw SpeakerCoreModel.error(.cancelled)
                        }
                        try shell.start(settings: settings)
                        let encoded = try sessionReference.encoded()
                        try lock.withLock {
                            guard lifetime.isActive, modelState == .ready, !record.isClosing, !record.isCancelled else {
                                throw SpeakerCoreModel.error(.cancelled)
                            }
                            record.isStarted = true
                        }
                        reply(encoded, nil)
                    } catch {
                        lock.withLock { record.isClosing = true }
                        reply(nil, error as NSError)
                    }
                }
            }
        } catch { reply(nil, error as NSError) }
    }

    func closeSession(sessionReference: Data, lifetime: ConnectionLifetime,
                      reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            let reference = try OmniXPCSpeakerSessionReference.decode(sessionReference)
            let record = try lock.withLock { () throws -> SessionRecord in
                guard lifetime.isActive else { throw SpeakerCoreModel.error(.cancelled) }
                if let existing = lifetime.sessions[reference.sessionID] {
                    guard existing.reference == reference else { throw SpeakerCoreModel.error(.invalid) }
                    guard !existing.closePending else { throw SpeakerCoreModel.error(.busy) }
                    if !existing.isClosed { existing.closePending = true }
                    existing.isClosing = true
                    return existing
                } else {
                    try requireOwner(lifetime, reference: reference.model)
                    try lifetime.recordBusiness(reference.sessionID, kind: .session)
                    let tombstone = SessionRecord(reference: reference, stream: nil)
                    tombstone.isClosing = true
                    tombstone.isClosed = true
                    lifetime.sessions[reference.sessionID] = tombstone
                    return tombstone
                }
            }
            let stream = lock.withLock { record.stream }
            stream?.cancel()
            queue.async { [self] in
                do {
                    try retireSession(record)
                    guard lock.withLock({ lifetime.isActive }) else { throw SpeakerCoreModel.error(.cancelled) }
                    reply(nil)
                } catch {
                    lock.withLock { record.closePending = false }
                    reply(error as NSError)
                }
            }
        } catch { reply(error as NSError) }
    }

    func retireSession(_ record: SessionRecord) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let stream = lock.withLock { record.stream }
        try stream?.close()
        record.delivery.retire()
        lock.withLock {
            record.stream = nil
            record.isClosed = true
            record.isClosing = true
            record.closePending = false
            if session === record { session = nil }
        }
    }
}
#endif
