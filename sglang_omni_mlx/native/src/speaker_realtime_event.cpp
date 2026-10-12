// SPDX-License-Identifier: Apache-2.0
#include "realtime.h"

namespace qwen3_asr {

nlohmann::ordered_json
SpeakerRealtimeEventJson(const SpeakerRealtimeEvent &event) {
  if (const auto *segment = std::get_if<SpeakerRealtimeSegment>(&event)) {
    nlohmann::ordered_json message = {{"type", "transcription.segment"},
                                      {"segment_id", segment->segment_id},
                                      {"text", segment->text},
                                      {"is_final", segment->is_final}};
    if (segment->segments.has_value()) {
      message["segments"] = SpeakerSegmentsJson(*segment->segments);
    } else {
    }
    return message;
  } else if (const auto *completed =
                 std::get_if<SpeakerRealtimeCompleted>(&event)) {
    return {{"type", "transcription.completed"},
            {"text", completed->text},
            {"segments", SpeakerSegmentsJson(completed->segments)}};
  } else if (const auto *failure =
                 std::get_if<SpeakerRealtimeFailure>(&event)) {
    return {{"type", "error"},
            {"error",
             {{"type", failure->type},
              {"code", failure->code},
              {"message", failure->message}}}};
  } else {
    return {{"type", "transcription_session.updated"}};
  }
}

} // namespace qwen3_asr
