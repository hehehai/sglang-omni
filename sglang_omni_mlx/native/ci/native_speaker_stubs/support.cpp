// SPDX-License-Identifier: Apache-2.0
#include "support.h"
#include <iostream>
namespace native_test {
void expect_status(OmniBatchStatus actual, OmniBatchStatus expected,
                   const std::string &operation) {
  require(actual == expected, operation + ": expected status " +
                                  std::to_string(expected) + ", got " +
                                  std::to_string(actual));
}
Fixture::Fixture(OmniSpeakerModelKind kind, bool creates_stream) {
  script.output = result("typed transcript");
  expect_status(omni_speaker_settings_default(kind, &settings), OMNI_BATCH_OK,
                "defaults");
  expect_status(omni_speaker_create(kind, ".", &model), OMNI_BATCH_OK,
                "model create");
  require(model != nullptr, "Create returned NULL on OK");
  if (creates_stream) {
    create_stream();
  } else {
  }
}
Fixture::~Fixture() {
  script.load_gate.release();
  script.decode_gate.release();
  script.sync_gate.release();
  script.callback_gate.release();
  script.finish_gate.release();
  script.sink_gate.release();
  script.sync_failures = 0;
  script.fail_sync_call = 0;
  script.cache_failures = 0;
  fail_new_after = -1;
  fail_malloc_after = -1;
  const auto stream_status = omni_speaker_realtime_destroy_checked(stream);
  const auto model_status = omni_speaker_destroy_checked(model);
  if (stream_status != OMNI_BATCH_OK || model_status != OMNI_BATCH_OK) {
    std::cerr << "Fixture cleanup failed " << stream_status << '/'
              << model_status << '\n';
    std::terminate();
  } else {
  }
}
void Fixture::create_stream() {
  ++session_id;
  next_audio_sequence = 1;
  next_event_sequence = 1;
  expect_status(
      omni_speaker_realtime_create(model, session_id, &settings, &stream),
      OMNI_BATCH_OK, "stream create");
  require(stream != nullptr, "Create returned NULL lease");
}
void Fixture::push(const std::vector<float> &samples) {
  uint64_t accepted_sequence = 999;
  expect_status(omni_speaker_realtime_push(stream, next_audio_sequence,
                                           samples.data(), samples.size(),
                                           &accepted_sequence),
                OMNI_BATCH_OK, "push");
  require(accepted_sequence == next_audio_sequence, "ACK sequence mismatch");
  ++next_audio_sequence;
}
OmniSpeakerRealtimeEvent Fixture::poll() {
  OmniSpeakerRealtimeEvent event{};
  const int status = omni_speaker_realtime_poll(stream, &event);
  require(status >= 0,
          "Poll failed status " + std::to_string(event.failure_status));
  if (status == 1) {
    require(event.event_sequence == next_event_sequence++,
            "Event lost, duplicated, or reordered");
    require(event.session_id == session_id, "Session ID changed");
  } else {
    require(event.kind == 0 && event.text == nullptr &&
                event.segment_count == 0 &&
                event.failure_status == OMNI_BATCH_OK,
            "Empty poll not zeroed");
  }
  return event;
}
OmniSpeakerRealtimeEvent Fixture::wait_segment() {
  const auto deadline = std::chrono::steady_clock::now() + TIMEOUT_SECONDS;
  while (std::chrono::steady_clock::now() < deadline) {
    auto event = poll();
    if (event.kind == OMNI_SPEAKER_SEGMENT ||
        event.kind == OMNI_SPEAKER_FAILED) {
      return event;
    } else {
      omni_speaker_realtime_event_free(&event);
      std::this_thread::yield();
    }
  }
  throw std::runtime_error("Timed out waiting for actual worker event");
}
nlohmann::ordered_json event_json(const OmniSpeakerRealtimeEvent &event) {
  nlohmann::ordered_json segments = nullptr;
  if (event.has_segments) {
    segments = nlohmann::ordered_json::array();
    for (size_t i = 0; i < event.segment_count; ++i) {
      const auto &segment = event.segments[i];
      segments.push_back(
          {{"start", segment.start_seconds},
           {"end", segment.end_seconds},
           {"speaker", segment.speaker},
           {"text", segment.text},
           {"language", segment.language ? nlohmann::json(segment.language)
                                         : nlohmann::json(nullptr)},
           {"emotion", segment.emotion ? nlohmann::json(segment.emotion)
                                       : nlohmann::json(nullptr)},
           {"event", segment.event ? nlohmann::json(segment.event)
                                   : nlohmann::json(nullptr)}});
    }
  } else {
  }
  return {{"kind", event.kind},
          {"segment_id", event.segment_id},
          {"is_final", event.is_final},
          {"text",
           event.text ? nlohmann::json(event.text) : nlohmann::json(nullptr)},
          {"segments", segments},
          {"failure_status", event.failure_status}};
}
nlohmann::ordered_json Fixture::events() {
  nlohmann::ordered_json snapshots = nlohmann::ordered_json::array();
  while (true) {
    auto event = poll();
    if (event.kind == 0) {
      break;
    } else {
    }
    snapshots.push_back(event_json(event));
    omni_speaker_realtime_event_free(&event);
    require(event.kind == 0 && event.text == nullptr &&
                event.segments == nullptr && event.segment_count == 0 &&
                event.session_id == 0 && event.failure_status == 0,
            "event_free did not zero snapshot");
    omni_speaker_realtime_event_free(&event);
  }
  return snapshots;
}
void Fixture::close() {
  expect_status(omni_speaker_realtime_destroy_checked(stream), OMNI_BATCH_OK,
                "stream destroy");
  stream = nullptr;
  expect_status(omni_speaker_destroy_checked(model), OMNI_BATCH_OK,
                "model destroy");
  model = nullptr;
  require(script.live_models == 0 && script.live_streams == 0,
          "Reader/model owner leaked");
  check_threads();
}
} // namespace native_test
