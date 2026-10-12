// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "transcriber.h"

namespace qwen3_asr {

struct SpeakerRealtimeUpdated {};
struct SpeakerRealtimeSegment {
  int segment_id;
  std::string text;
  bool is_final;
  std::optional<std::vector<SpeakerSegment>> segments = std::nullopt;
};
struct SpeakerRealtimeCompleted {
  std::string text;
  std::vector<SpeakerSegment> segments;
};
struct SpeakerRealtimeFailure {
  std::string type = "server_error";
  std::string code = "transcription_failed";
  std::string message = "Transcription failed.";
};
using SpeakerRealtimeEvent =
    std::variant<SpeakerRealtimeUpdated, SpeakerRealtimeSegment,
                 SpeakerRealtimeCompleted, SpeakerRealtimeFailure>;

} // namespace qwen3_asr
