/// Bounded Silero stream RPC admission, one-batch replay, and terminal Native barriers.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSileroInferenceEngine {
    func startStream(
        streamID: String, modelID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard streams.count < OmniXPCSileroLimits.maximumStreamCount else {
                    throw OmniXPCFailure.error(.busy, "The Silero model has reached its live stream limit.")
                }
                try requireUnusedRequestID(requestedID, lifetime: lifetime)
                let stream = OmniSileroStream(
                    id: requestedID, modelID: requestedModelID, ownerID: lifetime.id,
                    lease: SileroCoreStreamLease(model: model!)
                )
                streams[requestedID] = stream
                requestIDs[requestedID] = .stream
                queue.async { [self] in
                    do {
                        try stream.lease.create()
                        try lock.withLock {
                            guard lifetime.isActive, stream.state == .creating else {
                                throw OmniXPCFailure.error(.cancelled, "The Silero stream creation was cancelled.")
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
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero audio sequence must be positive.")
                }
                if sequence == stream.lastSequence {
                    guard audio == stream.lastAudio, let lastReply = stream.lastReply else {
                        throw OmniXPCFailure.error(.invalidRequest, "A Silero retry must contain the identical last audio bytes.")
                    }
                    return lastReply
                }
                guard stream.lastSequence < Int.max, sequence == stream.lastSequence + 1 else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero audio sequence is out of order.")
                }
                let samples = try OmniXPCRequestValidation.audioSamples(
                    audio: audio, maximumSampleCount: OmniXPCSileroLimits.maximumChunkSampleCount
                )
                let receivedSampleCount = try stream.nextReceivedSampleCount(adding: samples.count)
                let frameSampleCount = UInt64(OmniXPCSileroLimits.frameSampleCount)
                let processedSampleCount = receivedSampleCount / frameSampleCount * frameSampleCount
                let previousProcessedSampleCount = stream.processedSampleCount
                stream.isBusy = true
                stream.lastAudio = nil
                stream.lastReply = nil
                queue.async { [self] in
                    do {
                        let probabilities = try stream.lease.push(
                            samples: samples, sequence: sequence, previousProcessedSampleCount: previousProcessedSampleCount,
                            expectedProcessedSampleCount: processedSampleCount
                        )
                        let response = try OmniXPCSileroProbabilityBatch(
                            serviceInstanceID: OmniServiceIdentity.instanceID, modelID: requestedModelID,
                            streamID: requestedID, audioSequence: sequence, processedSampleCount: processedSampleCount,
                            probabilities: probabilities, isFinal: false
                        ).encoded()
                        try lock.withLock {
                            guard lifetime.isActive, stream.state == .ready else {
                                throw OmniXPCFailure.error(.cancelled, "The Silero audio command was cancelled.")
                            }
                            stream.receivedSampleCount = receivedSampleCount
                            stream.processedSampleCount = processedSampleCount
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
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            let replay = try lock.withLock { () throws -> Data? in
                try requireOwner(lifetime, modelID: requestedModelID)
                if let completed = lastCompletedStream,
                   completed.streamID == requestedID, completed.modelID == requestedModelID,
                   completed.ownerID == lifetime.id {
                    return completed.encodedBatch
                }
                let stream = try requireStream(requestedID, modelID: requestedModelID, lifetime: lifetime)
                try stream.requireReady()
                let processedSampleCount = try stream.finalProcessedSampleCount(
                    receivedSampleCount: stream.receivedSampleCount
                )
                let previousProcessedSampleCount = stream.processedSampleCount
                let sequence = stream.lastSequence
                stream.isBusy = true
                queue.async { [self] in
                    do {
                        let probabilities = try stream.lease.finish(
                            previousProcessedSampleCount: previousProcessedSampleCount,
                            expectedProcessedSampleCount: processedSampleCount
                        )
                        let response = try OmniXPCSileroProbabilityBatch(
                            serviceInstanceID: OmniServiceIdentity.instanceID, modelID: requestedModelID,
                            streamID: requestedID, audioSequence: sequence, processedSampleCount: processedSampleCount,
                            probabilities: probabilities, isFinal: true
                        ).encoded()
                        try stream.lease.drainAndDestroy()
                        try lock.withLock {
                            guard lifetime.isActive, stream.state == .ready else {
                                throw OmniXPCFailure.error(.cancelled, "The Silero stream finalization was cancelled.")
                            }
                            lastCompletedStream = OmniSileroStream.CompletedReply(
                                streamID: requestedID, modelID: requestedModelID, ownerID: lifetime.id,
                                encodedBatch: response
                            )
                            streams.removeValue(forKey: requestedID)
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

    func closeStream(
        streamID: String, modelID: String, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(streamID)
            let requestedModelID = try identifier(modelID)
            var cancellingLease: SileroCoreStreamLease?
            let isRetired = try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard requestIDs[requestedID] == .stream else {
                    throw OmniXPCFailure.error(.invalidRequest, "The Silero stream ID has not been registered.")
                }
                guard let stream = streams[requestedID] else { return true }
                guard !stream.isClosePending else {
                    throw OmniXPCFailure.error(.busy, "The Silero stream already has a pending close command.")
                }
                stream.isClosePending = true
                stream.state = .cancelled
                cancellingLease = stream.lease
                queue.async { [self] in
                    do {
                        // note (assistant): The queue may reach this barrier before the caller signals cancellation below.
                        stream.lease.cancel()
                        try stream.lease.drainAndDestroy()
                        lock.withLock { _ = streams.removeValue(forKey: requestedID) }
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
    ) throws -> OmniSileroStream {
        try requireOwner(lifetime, modelID: modelID)
        guard let stream = streams[streamID] else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero stream is stale or has already drained.")
        }
        return stream
    }

    private func failStream(_ stream: OmniSileroStream, lifetime: ConnectionLifetime, failure: Error) -> NSError {
        let cancelled = lock.withLock {
            let cancelled = !lifetime.isActive || stream.state == .cancelled
            stream.state = cancelled ? .cancelled : .failed
            stream.isBusy = false
            stream.lastAudio = nil
            stream.lastReply = nil
            return cancelled
        }
        stream.lease.cancel()
        return cancelled ? OmniXPCFailure.error(.cancelled, "The Silero stream command was cancelled.") : failure as NSError
    }
}
#endif
