import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniInferenceSession {
    func loadSortformer(
        operationID: String, modelDirectory: String,
        withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void
    ) {
        do {
            try admission.admitLoad {
                try sortformerEngine.admitLoad(
                    operationID: operationID, modelDirectory: modelDirectory, lifetime: sortformerLifetime, reply: reply
                )
            }
        } catch {
            reply(nil, nil, error as NSError)
        }
    }

    func unloadSortformer(
        operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        sortformerEngine.unload(operationID: operationID, modelID: modelID, lifetime: sortformerLifetime, reply: reply)
    }

    func startSortformerStream(
        streamID: String, modelID: String, settings: Data, withReply reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        sortformerEngine.startStream(
            streamID: streamID, modelID: modelID, settings: settings, lifetime: sortformerLifetime, reply: reply
        )
    }

    func pushSortformerAudio(
        streamID: String, modelID: String, sequence: Int, audio: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        sortformerEngine.pushStream(
            streamID: streamID, modelID: modelID, sequence: sequence, audio: audio, lifetime: sortformerLifetime, reply: reply
        )
    }

    func finishSortformerStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        sortformerEngine.finishStream(streamID: streamID, modelID: modelID, lifetime: sortformerLifetime, reply: reply)
    }

    func closeSortformerStream(
        streamID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        sortformerEngine.closeStream(streamID: streamID, modelID: modelID, lifetime: sortformerLifetime, reply: reply)
    }

    func cancelSortformerRequest(
        requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        do {
            try sortformerEngine.cancel(requestID: requestID, modelID: modelID, lifetime: sortformerLifetime)
            reply(nil)
        } catch {
            reply(error as NSError)
        }
    }
}
#endif
