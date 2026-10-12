// SPDX-License-Identifier: Apache-2.0
#include "support.h"

namespace speaker_test {
Gate preview_serialization;
std::atomic<bool> observes_preview_serialization{false};
} // namespace speaker_test

namespace qwen3_asr {
nlohmann::ordered_json
UnobservedSpeakerRealtimeEventJson(const SpeakerRealtimeEvent &event);

nlohmann::ordered_json
SpeakerRealtimeEventJson(const SpeakerRealtimeEvent &event) {
  if (const auto *segment = std::get_if<SpeakerRealtimeSegment>(&event);
      segment != nullptr && !segment->is_final &&
      speaker_test::observes_preview_serialization.load()) {
    std::lock_guard<std::mutex> lock(speaker_test::preview_serialization.mutex);
    speaker_test::preview_serialization.entered = true;
    speaker_test::preview_serialization.changed.notify_all();
  } else {
  }
  return UnobservedSpeakerRealtimeEventJson(event);
}
} // namespace qwen3_asr
