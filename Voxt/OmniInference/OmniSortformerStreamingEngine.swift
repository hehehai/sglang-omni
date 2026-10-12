/// Bounded Sortformer stream commands, exact last-batch replay, and terminal Native barriers.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSortformerInferenceEngine {
    func startStream(
        streamID: String, modelID: String, settings: Data, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard streams.count < OmniXPCSortformerLimits.maximumStreamCount else {
                    throw OmniXPCFailure.error(.busy, "The Sortformer model has reached its live stream limit.")
                }
                try requireUnusedRequestID(requestedID, lifetime: lifetime)
                let decodedSettings = try OmniXPCSortformerSettings.decode(settings)
                let stream = OmniSortformerStream(
                    id: requestedID, modelID: requestedModelID, ownerID: lifetime.id,
                    lease: SortformerCoreStreamLease(model: model!)
                )
                streams[requestedID] = stream
                requestIDs[requestedID] = .registered
                queue.async { [self] in
                    do {
                        try stream.lease.create(settings: decodedSettings)
                        try lock.withLock {
                            guard lifetime.isActive, stream.state == .creating else {
                                throw OmniXPCFailure.error(.cancelled, "The Sortformer stream creation was cancelled.")
                            }
                            stream.state = .ready
                            stream.isBusy = false
                        }
                        reply(requestedID.uuidString, nil)
                    } catch {
                        reply(nil, failStream(stream, lifetime: lifetime, failure: error))
                    }
                }
            }
        } catch {
            reply(nil, error as NSError)
        }
    }

    func pushStream(
        streamID: String, modelID: String, sequence: Int, audio: Data, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            let replay = try lock.withLock { () throws -> Data? in
                let stream = try requireStream(requestedID, modelID: requestedModelID, lifetime: lifetime)
                try stream.requireReady()
                guard sequence > 0 else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer audio sequence must be positive.")
                }
                if sequence == stream.lastSequence {
                    guard audio == stream.lastAudio, let lastReply = stream.lastReply else {
                        throw OmniXPCFailure.error(.invalidRequest, "A Sortformer retry must contain identical last audio bytes.")
                    }
                    return lastReply
                }
                guard stream.lastSequence < Int.max, sequence == stream.lastSequence + 1 else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer audio sequence is out of order.")
                }
                let sampleByteCount = MemoryLayout<UInt32>.size
                guard !audio.isEmpty,
                      audio.count <= OmniXPCSortformerLimits.maximumChunkSampleCount * sampleByteCount,
                      audio.count % sampleByteCount == 0 else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer audio exceeds validation limits.")
                }
                let sampleCount = audio.count / sampleByteCount
                let featureFrameCount = 1 + sampleCount / OmniXPCSortformerLimits.featureHopSampleCount
                let subsamplingFactor = OmniXPCSortformerLimits.subsamplingFactor
                let frameCount = (featureFrameCount + subsamplingFactor - 1) / subsamplingFactor
                let previousProcessedFrameCount = stream.processedFrameCount
                guard previousProcessedFrameCount <= OmniXPCSortformerLimits.maximumProcessedFrameCount - UInt64(frameCount) else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer processed frame counter is full.")
                }
                let processedFrameCount = previousProcessedFrameCount + UInt64(frameCount)
                // note (assistant): Reject nonfinite wire samples before constructing any owned Float array.
                try audio.withUnsafeBytes { bytes in
                    for offset in stride(from: 0, to: audio.count, by: sampleByteCount) {
                        let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        guard Float(bitPattern: bits).isFinite else {
                            throw OmniXPCFailure.error(.invalidRequest, "Audio samples must be finite Float32 values.")
                        }
                    }
                }
                let samples = try OmniXPCRequestValidation.audioSamples(
                    audio: audio, maximumSampleCount: OmniXPCSortformerLimits.maximumChunkSampleCount
                )
                stream.isBusy = true
                stream.lastAudio = nil
                stream.lastReply = nil
                queue.async { [self] in
                    do {
                        let response = try stream.lease.push(
                            samples: samples, sequence: sequence,
                            previousProcessedFrameCount: previousProcessedFrameCount,
                            expectedProcessedFrameCount: processedFrameCount,
                            serviceInstanceID: OmniServiceIdentity.instanceID,
                            modelID: requestedModelID, streamID: requestedID
                        ).encoded()
                        try lock.withLock {
                            guard lifetime.isActive, stream.state == .ready else {
                                throw OmniXPCFailure.error(.cancelled, "The Sortformer audio command was cancelled.")
                            }
                            stream.processedFrameCount = processedFrameCount
                            stream.lastSequence = sequence
                            stream.lastAudio = audio
                            stream.lastReply = response
                            stream.isBusy = false
                        }
                        reply(response, nil)
                    } catch {
                        reply(nil, failStream(stream, lifetime: lifetime, failure: error))
                    }
                }
                return nil
            }
            if let replay { reply(replay, nil) }
        } catch {
            reply(nil, error as NSError)
        }
    }

    func finishStream(
        streamID: String, modelID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            let isFinished = try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                if requestIDs[requestedID] == .finished { return true }
                let stream = try requireStream(requestedID, modelID: requestedModelID, lifetime: lifetime)
                try stream.requireReady()
                stream.isBusy = true
                stream.lastAudio = nil
                stream.lastReply = nil
                queue.async { [self] in
                    do {
                        try stream.lease.finish()
                        try stream.lease.drainAndDestroy()
                        try lock.withLock {
                            guard lifetime.isActive, stream.state == .ready else {
                                throw OmniXPCFailure.error(.cancelled, "The Sortformer stream finalization was cancelled.")
                            }
                            requestIDs[requestedID] = .finished
                            streams.removeValue(forKey: requestedID)
                        }
                        reply(nil)
                    } catch {
                        reply(failStream(stream, lifetime: lifetime, failure: error))
                    }
                }
                return false
            }
            if isFinished { reply(nil) }
        } catch {
            reply(error as NSError)
        }
    }

    func closeStream(
        streamID: String, modelID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            var cancellingLease: SortformerCoreStreamLease?
            let isRetired = try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard requestIDs[requestedID] != nil else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream ID has not been registered.")
                }
                guard let stream = streams[requestedID] else { return true }
                guard !stream.isClosePending else {
                    throw OmniXPCFailure.error(.busy, "The Sortformer stream already has a pending close command.")
                }
                stream.isClosePending = true
                stream.state = .cancelled
                stream.lastAudio = nil
                stream.lastReply = nil
                cancellingLease = stream.lease
                queue.async { [self] in
                    do {
                        // note (assistant): The queue can reach this barrier before the caller signals cancellation below.
                        stream.lease.cancel()
                        try stream.lease.drainAndDestroy()
                        lock.withLock {
                            streams.removeValue(forKey: requestedID)
                            requestIDs[requestedID] = .closed
                        }
                        reply(nil)
                    } catch {
                        lock.withLock { stream.isClosePending = false }
                        reply(error as NSError)
                    }
                }
                return false
            }
            cancellingLease?.cancel()
            if isRetired { reply(nil) }
        } catch {
            reply(error as NSError)
        }
    }

    private func requireStream(
        _ streamID: UUID, modelID: UUID, lifetime: ConnectionLifetime
    ) throws -> OmniSortformerStream {
        try requireOwner(lifetime, modelID: modelID)
        guard let stream = streams[streamID], stream.modelID == modelID, stream.ownerID == lifetime.id else {
            throw OmniXPCFailure.error(.invalidRequest, "The Sortformer stream is stale or has already drained.")
        }
        return stream
    }

    private func failStream(_ stream: OmniSortformerStream, lifetime: ConnectionLifetime, failure: Error) -> NSError {
        let cancelled = lock.withLock {
            let cancelled = !lifetime.isActive || stream.state == .cancelled
            stream.state = cancelled ? .cancelled : .failed
            stream.isBusy = false
            stream.lastAudio = nil
            stream.lastReply = nil
            return cancelled
        }
        stream.lease.cancel()
        return cancelled ? OmniXPCFailure.error(.cancelled, "The Sortformer stream command was cancelled.") : failure as NSError
    }
}
#endif
