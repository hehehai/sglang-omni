/// Realtime RPC admission and serial Native commands; cancellation never waits for this queue.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniFinalSessionEngine {
    func startRealtime(
        sessionID: String, modelID: String, language: String?, context: String?, maximumTokenCount: Int,
        decodeIntervalSamples: Int, firstDecodeSamples: Int, maximumSegmentSamples: Int,
        lifetime: OmniConnectionLifetime, reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            try OmniXPCRequestValidation.realtimeOptions(
                language: language, context: context, maximumTokenCount: maximumTokenCount
            )
            let settings = try OmniXPCRealtimeSettings(
                decodeIntervalSamples: decodeIntervalSamples, firstDecodeSamples: firstDecodeSamples,
                maximumSegmentSamples: maximumSegmentSamples
            )
            try lock.withLock {
                try requireSessionAdmission(requestedSessionID, modelID: requestedModelID, lifetime: lifetime)
                let active = OmniRealtimeSession(
                    sessionID: requestedSessionID, modelID: requestedModelID, ownerID: lifetime.id,
                    lease: QwenCoreRealtimeLease(model: model!, nativeSessionID: UInt64(sessionIDs.count + 1))
                )
                realtimeSession = active
                sessionIDs.insert(requestedSessionID)
                queue.async { [self] in
                    do {
                        try active.lease.create(
                            settings: settings, language: language, context: context, maximumTokenCount: maximumTokenCount
                        )
                    } catch {
                        lock.withLock {
                            if realtimeSession === active { realtimeSession = nil }
                        }
                        reply(nil, error as NSError)
                        return
                    }
                    let isActive = lock.withLock { lifetime.isActive }
                    if isActive {
                        reply(OmniServiceIdentity.instanceID.uuidString, nil)
                    } else {
                        reply(nil, OmniXPCFailure.error(.cancelled, "The realtime connection was closed during creation."))
                    }
                }
            }
        } catch {
            reply(nil, error as NSError)
        }
    }

    func pushRealtime(
        sessionID: String, modelID: String, sequence: Int, audio: Data, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (Int, NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            guard sequence > 0, UInt64(exactly: sequence) != nil, !audio.isEmpty,
                  audio.count <= OmniXPCProtocolLimits.maximumChunkAudioByteCount,
                  audio.count % MemoryLayout<UInt32>.size == 0 else {
                throw OmniXPCFailure.error(.invalidRequest, "The realtime audio chunk exceeds admission limits.")
            }
            try lock.withLock {
                let active = try requireRealtimeSession(requestedSessionID, modelID: requestedModelID, lifetime: lifetime)
                guard !active.isClosing,
                      audio.count <= OmniXPCProtocolLimits.maximumAudioByteCount - active.reservedAudioByteCount else {
                    throw OmniXPCFailure.error(.invalidRequest, "The realtime session is closing or its audio budget is full.")
                }
                active.reservedAudioByteCount += audio.count
                queue.async { [self] in
                    do {
                        try lock.withLock {
                            _ = try requireRealtimeSession(requestedSessionID, modelID: requestedModelID, lifetime: lifetime)
                        }
                        reply(try active.push(audio: audio, sequence: sequence), nil)
                    } catch {
                        lock.withLock { active.reservedAudioByteCount -= audio.count }
                        reply(0, error as NSError)
                    }
                }
            }
        } catch {
            reply(0, error as NSError)
        }
    }

    func finishRealtime(
        sessionID: String, modelID: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                let active = try requireRealtimeSession(requestedSessionID, modelID: requestedModelID, lifetime: lifetime)
                guard !active.isClosing else {
                    throw OmniXPCFailure.error(.invalidRequest, "The realtime session is closing.")
                }
                queue.async { [self] in
                    do {
                        try lock.withLock {
                            _ = try requireRealtimeSession(requestedSessionID, modelID: requestedModelID, lifetime: lifetime)
                        }
                        try active.lease.finish()
                        reply(nil)
                    } catch {
                        reply(error as NSError)
                    }
                }
            }
        } catch {
            reply(error as NSError)
        }
    }

    func pollRealtime(
        sessionID: String, modelID: String, acknowledgedEventSequence: Int, maximumEventCount: Int,
        lifetime: OmniConnectionLifetime, reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            guard acknowledgedEventSequence >= 0,
                  (1...OmniXPCProtocolLimits.maximumRealtimeEventsPerBatch).contains(maximumEventCount) else {
                throw OmniXPCFailure.error(.invalidRequest, "The realtime poll ACK or count is invalid.")
            }
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                queue.async { [self] in
                    do {
                        let (active, drained) = try lock.withLock { () -> (OmniRealtimeSession?, OmniRealtimeSession.DrainedIdentity?) in
                            try requireOwner(lifetime, modelID: requestedModelID)
                            if realtimeSession?.sessionID == requestedSessionID {
                                return (realtimeSession, nil)
                            } else if let drained = lastDrainedRealtime,
                                      drained.sessionID == requestedSessionID, drained.modelID == requestedModelID,
                                      drained.ownerID == lifetime.id {
                                return (nil, drained)
                            } else {
                                throw OmniXPCFailure.error(.invalidRequest, "The realtime session identity is stale.")
                            }
                        }
                        if let drained {
                            guard acknowledgedEventSequence == drained.acknowledgedEventSequence else {
                                throw OmniXPCFailure.error(.invalidRequest, "The drained realtime ACK is invalid.")
                            }
                            reply(drained.encodedBatch, nil)
                        } else {
                            let encodedBatch = try active!.poll(
                                acknowledgedEventSequence: acknowledgedEventSequence, maximumEventCount: maximumEventCount
                            )
                            if let drained = active!.drainedIdentity {
                                lock.withLock {
                                    precondition(realtimeSession === active)
                                    lastDrainedRealtime = drained
                                    realtimeSession = nil
                                }
                            }
                            reply(encodedBatch, nil)
                        }
                    } catch {
                        reply(nil, error as NSError)
                    }
                }
            }
        } catch {
            reply(nil, error as NSError)
        }
    }

    func closeRealtime(
        sessionID: String, modelID: String, lifetime: OmniConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let requestedSessionID = try identifier(sessionID)
            let requestedModelID = try identifier(modelID)
            var leaseToCancel: QwenCoreRealtimeLease?
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                if let active = realtimeSession, active.sessionID == requestedSessionID {
                    active.isClosing = true
                    leaseToCancel = active.lease
                    queue.async { [self] in
                        do {
                            active.lease.cancel()
                            let drained = try active.drain()
                            lock.withLock {
                                if realtimeSession === active {
                                    lastDrainedRealtime = drained
                                    realtimeSession = nil
                                }
                            }
                            reply(nil)
                        } catch {
                            reply(error as NSError)
                        }
                    }
                } else if let drained = lastDrainedRealtime,
                          drained.sessionID == requestedSessionID, drained.modelID == requestedModelID,
                          drained.ownerID == lifetime.id {
                    queue.async { reply(nil) }
                } else {
                    throw OmniXPCFailure.error(.invalidRequest, "The realtime session identity is stale.")
                }
            }
            leaseToCancel?.cancel()
        } catch {
            reply(error as NSError)
        }
    }

    private func requireRealtimeSession(
        _ sessionID: UUID, modelID: UUID, lifetime: OmniConnectionLifetime
    ) throws -> OmniRealtimeSession {
        try requireOwner(lifetime, modelID: modelID)
        guard let active = realtimeSession, active.sessionID == sessionID else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime session is stale or has already drained.")
        }
        return active
    }
}
#endif
