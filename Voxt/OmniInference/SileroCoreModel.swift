/// Retained ABI4 Silero model with independently cancellable requests and registered stream leases.
import Foundation
import OmniXPCContracts
import OmniModelArtifacts

#if os(macOS)
nonisolated final class SileroCoreModel: @unchecked Sendable {
    private let lock = NSLock()
    private let directoryLease: OmniModelDirectoryLease
    private var handle: OpaquePointer?
    private var request: OpaquePointer?
    private var requestID: UUID?
    private var streamLeaseCount = 0

    init(directoryLease: OmniModelDirectoryLease) throws {
        guard Int(omni_core_abi_version()) == OmniXPCProtocolLimits.abiVersion else {
            throw OmniXPCFailure.error(.incompatibleService, "The Native Core ABI is incompatible.")
        }
        self.directoryLease = directoryLease
        var errorMessage: UnsafeMutablePointer<CChar>?
        handle = omni_silero_create(directoryLease.directory.path, &errorMessage)
        defer { omni_string_free(errorMessage) }
        guard handle != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native Silero model could not be loaded.")
        }
    }

    func prepareRequest(requestID: UUID) throws {
        try lock.withLock {
            precondition(handle != nil && request == nil)
            guard let token = omni_silero_request_create() else {
                throw OmniXPCFailure.error(.nativeFailure, "The Native Silero request could not be created.")
            }
            request = token
            self.requestID = requestID
        }
    }

    func cancelRequest(requestID: UUID) {
        lock.withLock {
            guard self.requestID == requestID, let request else { return }
            omni_silero_request_cancel(request)
        }
    }

    func speechTimestamps(
        requestID: UUID, samples: [Float], settings: OmniXPCSileroSettings
    ) throws -> [OmniXPCSileroTimestamp] {
        let (modelHandle, requestToken) = lock.withLock {
            precondition(handle != nil && request != nil && self.requestID == requestID)
            return (handle!, request!)
        }
        defer {
            lock.withLock {
                omni_silero_request_destroy(requestToken)
                request = nil
                self.requestID = nil
            }
        }
        try settings.validate()
        guard !samples.isEmpty, samples.count <= OmniXPCProtocolLimits.maximumSampleCount,
              samples.allSatisfy(\.isFinite) else {
            throw OmniXPCFailure.error(.invalidRequest, "The Silero audio exceeds validation limits.")
        }
        var nativeSettings = OmniSileroSettings(
            threshold: settings.threshold,
            minimum_speech_milliseconds: Int32(settings.minimumSpeechMilliseconds),
            minimum_silence_milliseconds: Int32(settings.minimumSilenceMilliseconds),
            speech_padding_milliseconds: Int32(settings.speechPaddingMilliseconds)
        )
        var result = OmniSileroResult()
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            omni_silero_result_free(&result)
            omni_string_free(errorMessage)
        }
        let success = samples.withUnsafeBufferPointer { buffer in
            omni_silero_speech_timestamps(
                modelHandle, requestToken, buffer.baseAddress, buffer.count,
                &nativeSettings, &result, &errorMessage
            )
        }
        guard success == 1,
              result.timestamp_count >= 0,
              result.timestamp_count <= OmniXPCSileroLimits.maximumTimestampCount,
              result.timestamp_count <= samples.count,
              result.timestamp_count == 0 || result.timestamps != nil else {
            throw OmniXPCFailure.error(.nativeFailure, "Native Silero timestamp inference failed.")
        }
        guard result.timestamp_count > 0 else { return [] }
        let timestamps = result.timestamps!
        var previousEndSample: Int64 = 0
        for index in 0..<result.timestamp_count {
            let timestamp = timestamps[index]
            guard timestamp.start_sample >= previousEndSample,
                  timestamp.start_sample < timestamp.end_sample,
                  timestamp.end_sample <= Int64(samples.count) else {
                throw OmniXPCFailure.error(.nativeFailure, "Native Silero returned invalid sample ranges.")
            }
            previousEndSample = timestamp.end_sample
        }
        return (0..<result.timestamp_count).map { index in
            OmniXPCSileroTimestamp(
                startSample: timestamps[index].start_sample, endSample: timestamps[index].end_sample
            )
        }
    }

    func registerStreamLease() -> OpaquePointer {
        lock.withLock {
            precondition(handle != nil && streamLeaseCount < OmniXPCSileroLimits.maximumStreamCount)
            streamLeaseCount += 1
            return handle!
        }
    }

    func releaseStreamLease() {
        lock.withLock {
            precondition(streamLeaseCount > 0)
            streamLeaseCount -= 1
        }
    }

    func close() {
        let releasedHandle = lock.withLock {
            precondition(request == nil && streamLeaseCount == 0)
            let releasedHandle = handle
            handle = nil
            return releasedHandle
        }
        if let releasedHandle { omni_silero_destroy(releasedHandle) }
    }

    deinit { close() }
}
#endif
