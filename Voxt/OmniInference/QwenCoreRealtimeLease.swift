/// Retains the loaded model until the Native realtime command and worker barriers complete.
import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated final class QwenCoreRealtimeLease: @unchecked Sendable {
    let model: QwenCoreModel
    let nativeSessionID: UInt64
    private let handleLock = NSLock()
    private var handle: OpaquePointer?
    private var cancellationRequested = false
    private var pendingNativeEvent: OmniQwenRealtimeEvent?
    private var lastEventSequence = 0
    private var hasTerminalEvent = false
    private var isDestroyed = false

    init(model: QwenCoreModel, nativeSessionID: UInt64) {
        precondition(nativeSessionID > 0)
        self.model = model
        self.nativeSessionID = nativeSessionID
    }

    func create(settings: OmniXPCRealtimeSettings, language: String?, context: String?, maximumTokenCount: Int) throws {
        var nativeSettings = OmniQwenRealtimeSettings(
            decode_interval_samples: Int32(settings.decodeIntervalSamples),
            first_decode_samples: Int32(settings.firstDecodeSamples),
            maximum_segment_samples: Int32(settings.maximumSegmentSamples),
            maximum_token_count: Int32(maximumTokenCount)
        )
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        let languageBytes = language.map { Array($0.utf8CString) } ?? []
        let contextBytes = context.map { Array($0.utf8CString) } ?? []
        let created = languageBytes.withUnsafeBufferPointer { languageBuffer in
            contextBytes.withUnsafeBufferPointer { contextBuffer in
                omni_qwen_realtime_create(
                    model.realtimeModelHandle, nativeSessionID, &nativeSettings,
                    language == nil ? nil : languageBuffer.baseAddress,
                    context == nil ? nil : contextBuffer.baseAddress, &errorMessage
                )
            }
        }
        guard let created else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native realtime session could not be created.")
        }
        handleLock.withLock {
            precondition(handle == nil)
            handle = created
            if cancellationRequested { omni_qwen_realtime_cancel(created) }
        }
    }

    func cancel() {
        // note (assistant): Cancellation shares only handle lifetime, never the serial command queue or drain barrier.
        handleLock.withLock {
            cancellationRequested = true
            if let handle { omni_qwen_realtime_cancel(handle) }
        }
    }

    func push(samples: [Float], sequence: Int) throws -> Int {
        guard sequence > 0, let nativeSequence = UInt64(exactly: sequence) else {
            throw OmniXPCFailure.error(.invalidRequest, "The realtime audio sequence is invalid.")
        }
        let nativeHandle = try commandHandle()
        var acceptedSequence: UInt64 = 0
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        let status = samples.withUnsafeBufferPointer { buffer in
            omni_qwen_realtime_push(
                nativeHandle, nativeSequence, buffer.baseAddress, buffer.count, &acceptedSequence, &errorMessage
            )
        }
        guard status == 1, errorMessage == nil, acceptedSequence == nativeSequence,
              let accepted = Int(exactly: acceptedSequence) else {
            throw OmniXPCFailure.error(.nativeFailure, "Native realtime audio admission failed.")
        }
        return accepted
    }

    func finish() throws {
        let nativeHandle = try commandHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        guard omni_qwen_realtime_finish(nativeHandle, &errorMessage) == 1, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "Native realtime finalization did not complete; poll its terminal event.")
        }
    }

    func poll() throws -> OmniXPCRealtimeEvent? {
        guard !hasTerminalEvent else { return nil }
        if pendingNativeEvent == nil {
            var event = OmniQwenRealtimeEvent()
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer { omni_string_free(errorMessage) }
            let status = omni_qwen_realtime_poll(try commandHandle(), &event, &errorMessage)
            if status == 1 {
                pendingNativeEvent = event
            } else {
                omni_qwen_realtime_event_free(&event)
                guard status == 0, errorMessage == nil else {
                    throw OmniXPCFailure.error(.nativeFailure, "Native realtime event polling failed.")
                }
                return nil
            }
        }
        let event = pendingNativeEvent!
        guard event.session_id == nativeSessionID,
              let sequence = Int(exactly: event.event_sequence), lastEventSequence < Int.max,
              sequence == lastEventSequence + 1,
              let kind = OmniXPCRealtimeEventKind(rawValue: Int(event.kind)),
              event.is_final == 0 || event.is_final == 1 else {
            throw OmniXPCFailure.error(.nativeFailure, "Native realtime event identity or kind is invalid.")
        }
        let text = try boundedString(event.text)
        let failureMessage = try boundedString(event.error_message)
        let translated: OmniXPCRealtimeEvent
        switch kind {
        case .segment:
            guard event.segment_id >= 0, text != nil, failureMessage == nil else {
                throw OmniXPCFailure.error(.nativeFailure, "Native realtime segment fields are invalid.")
            }
            translated = OmniXPCRealtimeEvent(
                sequence: sequence, kind: kind, segmentID: Int(event.segment_id), text: text, isFinal: event.is_final == 1
            )
        case .completed:
            guard event.segment_id == 0, event.is_final == 0, text != nil, failureMessage == nil else {
                throw OmniXPCFailure.error(.nativeFailure, "Native realtime completion fields are invalid.")
            }
            translated = OmniXPCRealtimeEvent(sequence: sequence, kind: kind, text: text)
        case .failed:
            guard event.segment_id == 0, event.is_final == 0, text == nil, failureMessage?.isEmpty == false else {
                throw OmniXPCFailure.error(.nativeFailure, "Native realtime failure fields are invalid.")
            }
            translated = OmniXPCRealtimeEvent(
                sequence: sequence, kind: kind, failureMessage: "Native realtime transcription failed."
            )
        case .updated, .cancelled:
            guard event.segment_id == 0, event.is_final == 0, text == nil, failureMessage == nil else {
                throw OmniXPCFailure.error(.nativeFailure, "Native realtime event fields are invalid.")
            }
            translated = OmniXPCRealtimeEvent(sequence: sequence, kind: kind)
        }
        lastEventSequence = sequence
        hasTerminalEvent = kind == .completed || kind == .cancelled || kind == .failed
        omni_qwen_realtime_event_free(&pendingNativeEvent!)
        pendingNativeEvent = nil
        return translated
    }

    func drainAndDestroy() throws {
        if isDestroyed { return }
        let nativeHandle = try commandHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { omni_string_free(errorMessage) }
        guard omni_qwen_realtime_drain(nativeHandle, &errorMessage) == 1, errorMessage == nil else {
            throw OmniXPCFailure.error(.nativeFailure, "The Native realtime worker barrier did not drain.")
        }
        handleLock.withLock { handle = nil }
        omni_qwen_realtime_destroy(nativeHandle)
        isDestroyed = true
        if var event = pendingNativeEvent {
            omni_qwen_realtime_event_free(&event)
            pendingNativeEvent = nil
        }
    }

    private func commandHandle() throws -> OpaquePointer {
        try handleLock.withLock {
            guard let handle else {
                throw OmniXPCFailure.error(.invalidRequest, "The Native realtime session is not active.")
            }
            return handle
        }
    }

    private func boundedString(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String? {
        guard let pointer else { return nil }
        let maximumByteCount = OmniXPCProtocolLimits.maximumRealtimeEventStringByteCount
        for byteCount in 0...maximumByteCount {
            if pointer[byteCount] == 0 {
                let bytes = UnsafeRawBufferPointer(start: pointer, count: byteCount)
                guard let string = String(bytes: bytes, encoding: .utf8) else {
                    throw OmniXPCFailure.error(.nativeFailure, "Native realtime output is not valid UTF-8.")
                }
                return string
            }
        }
        throw OmniXPCFailure.error(.nativeFailure, "Native realtime output exceeds the string byte limit.")
    }

    deinit { precondition(handle == nil && pendingNativeEvent == nil) }
}
#endif
