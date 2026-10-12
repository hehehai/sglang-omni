import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension OmniInferenceSession {
    func loadBatch(operationID: String, kind: Int, modelDirectory: String,
                   withReply reply: @escaping @Sendable (String?, String?, NSError?) -> Void) {
        do {
            try admission.admitLoad {
                try batchEngine.admitLoad(operationID: operationID, kind: kind, modelDirectory: modelDirectory,
                                          lifetime: batchLifetime, reply: reply)
            }
        } catch { reply(nil, nil, error as NSError) }
    }

    func transcribeBatch(requestID: String, modelID: String, audio: Data, settings: Data,
                         withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        batchEngine.transcribe(requestID: requestID, modelID: modelID, audio: audio, settings: settings,
                               lifetime: batchLifetime, reply: reply)
    }

    func cancelBatchRequest(requestID: String, modelID: String?, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try batchEngine.cancel(requestID: requestID, modelID: modelID, lifetime: batchLifetime)
            reply(nil)
        } catch { reply(error as NSError) }
    }

    func drainBatchLoad(operationID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        batchEngine.drainLoad(operationID: operationID, lifetime: batchLifetime, reply: reply)
    }

    func unloadBatch(operationID: String, modelID: String, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        batchEngine.unload(operationID: operationID, modelID: modelID, lifetime: batchLifetime, reply: reply)
    }
}
#endif
