import Foundation
import OmniXPCContracts

#if os(macOS)
nonisolated extension SpeakerCoreStream {
    func poll(session: OmniXPCSpeakerSessionReference) throws -> Result<OmniXPCSpeakerEvent, NSError>? {
        var snapshot = OmniSpeakerRealtimeEvent()
        defer { omni_speaker_realtime_event_free(&snapshot) }
        let result = omni_speaker_realtime_poll(try commandHandle(allowCancelled: true), &snapshot)
        if result == 0 {
            return nil
        } else if result != 1 {
            try SpeakerCoreModel.check(snapshot.failure_status)
            throw SpeakerCoreModel.error(.failed)
        } else {
            do { return .success(try copiedEvent(snapshot, session: session)) }
            catch { return .failure(error as NSError) }
        }
    }

    private func copiedEvent(_ snapshot: OmniSpeakerRealtimeEvent,
                             session: OmniXPCSpeakerSessionReference) throws -> OmniXPCSpeakerEvent {
        guard snapshot.session_id == nativeSessionID,
              let kind = OmniXPCSpeakerEventKind(rawValue: snapshot.kind),
              let status = OmniXPCSpeakerStatus(rawValue: snapshot.failure_status),
              [0, 1].contains(snapshot.has_segments), [0, 1].contains(snapshot.is_final),
              snapshot.segment_count <= OmniXPCSpeakerLimits.maximumSegmentCount,
              snapshot.segment_count == 0 || snapshot.segments != nil else {
            throw SpeakerCoreModel.error(.failed)
        }
        let text = try Self.copyString(snapshot.text, maximumByteCount: OmniXPCSpeakerLimits.maximumTextByteCount)
        var segments: [OmniXPCBatchSegment]?
        if snapshot.has_segments == 1 {
            segments = []
            for index in 0..<snapshot.segment_count {
                let segment = snapshot.segments![index]
                guard let segmentText = try Self.copyString(
                    segment.text, maximumByteCount: OmniXPCSpeakerLimits.maximumTextByteCount
                ) else { throw SpeakerCoreModel.error(.failed) }
                let maximumByteCount = OmniXPCSpeakerLimits.maximumMetadataByteCount
                segments!.append(try OmniXPCBatchSegment(
                    startSeconds: segment.start_seconds, endSeconds: segment.end_seconds, text: segmentText,
                    speaker: Self.copyString(segment.speaker, maximumByteCount: maximumByteCount),
                    language: Self.copyString(segment.language, maximumByteCount: maximumByteCount),
                    emotion: Self.copyString(segment.emotion, maximumByteCount: maximumByteCount),
                    event: Self.copyString(segment.event, maximumByteCount: maximumByteCount)
                ))
            }
        } else {
            guard snapshot.segment_count == 0 else { throw SpeakerCoreModel.error(.failed) }
        }
        return try OmniXPCSpeakerEvent(
            session: session, eventSequence: snapshot.event_sequence, kind: kind,
            segmentID: kind == .segment ? snapshot.segment_id : nil, text: text,
            isFinal: kind == .segment ? snapshot.is_final == 1 : nil, segments: segments, failureStatus: status
        )
    }

    private static func copyString(_ pointer: UnsafeMutablePointer<CChar>?, maximumByteCount: Int) throws -> String? {
        guard let pointer else { return nil }
        let byteCount = strnlen(pointer, maximumByteCount + 1)
        guard byteCount <= maximumByteCount,
              let string = String(bytes: UnsafeRawBufferPointer(start: pointer, count: byteCount), encoding: .utf8) else {
            throw SpeakerCoreModel.error(.failed)
        }
        return string
    }
}
#endif
