/// Single-request offline Silero inference shares the stream queue and bounded request history.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniSileroInferenceEngine {
    func speechTimestamps(
        requestID: String, modelID: String, audio: Data, settings: Data, lifetime: ConnectionLifetime,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        do {
            let requestedID = try identifier(requestID)
            let requestedModelID = try identifier(modelID)
            let options = try OmniXPCSileroSettings.decode(settings)
            try lock.withLock {
                try requireOwner(lifetime, modelID: requestedModelID)
                guard activeRequest == nil else {
                    throw OmniXPCFailure.error(.busy, "The Silero model already has an active offline request.")
                }
                try requireUnusedRequestID(requestedID, lifetime: lifetime)
                let samples = try OmniXPCRequestValidation.audioSamples(
                    audio: audio, maximumSampleCount: OmniXPCProtocolLimits.maximumSampleCount
                )
                let loaded = model!
                try loaded.prepareRequest(requestID: requestedID)
                // note (assistant): Only successful admission consumes history, including cancellation before execution.
                requestIDs[requestedID] = .offline
                activeRequest = Request(id: requestedID)
                queue.async { [self] in
                    var response: Data?
                    var failure: NSError?
                    do {
                        let timestamps = try loaded.speechTimestamps(
                            requestID: requestedID, samples: samples, settings: options
                        )
                        response = try OmniXPCSileroTimestampBatch(
                            serviceInstanceID: OmniServiceIdentity.instanceID, modelID: requestedModelID,
                            requestID: requestedID, sampleCount: samples.count, timestamps: timestamps
                        ).encoded()
                    } catch {
                        failure = error as NSError
                    }
                    let cancelled = lock.withLock {
                        precondition(activeRequest?.id == requestedID)
                        let cancelled = !lifetime.isActive || activeRequest!.isCancelled
                        activeRequest = nil
                        return cancelled
                    }
                    if cancelled {
                        reply(nil, OmniXPCFailure.error(.cancelled, "The Silero request was cancelled."))
                    } else {
                        reply(response, failure)
                    }
                }
            }
        } catch {
            reply(nil, error as NSError)
        }
    }
}
#endif
