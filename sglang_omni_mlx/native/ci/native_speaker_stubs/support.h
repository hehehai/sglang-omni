// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "omni_native_speaker.h"
#include "script.h"
#include <future>
namespace native_test {
extern thread_local long fail_new_after;
extern thread_local long fail_malloc_after;
extern thread_local size_t new_count;
extern thread_local size_t malloc_count;
void expect_status(OmniBatchStatus actual, OmniBatchStatus expected,
                   const std::string &operation);
struct Fixture {
  OmniSpeakerHandle *model = nullptr;
  OmniSpeakerRealtime *stream = nullptr;
  OmniSpeakerRealtimeSettings settings{};
  uint64_t session_id = 72;
  uint64_t next_audio_sequence = 1;
  uint64_t next_event_sequence = 1;
  explicit Fixture(OmniSpeakerModelKind kind, bool creates_stream = true);
  ~Fixture();
  void create_stream();
  void push(const std::vector<float> &samples);
  OmniSpeakerRealtimeEvent poll();
  OmniSpeakerRealtimeEvent wait_segment();
  nlohmann::ordered_json events();
  void close();
};
nlohmann::ordered_json event_json(const OmniSpeakerRealtimeEvent &event);
void protocol_case(OmniSpeakerModelKind kind, const std::string &name);
void validation_case(OmniSpeakerModelKind kind, const std::string &name);
void output_case(OmniSpeakerModelKind kind, const std::string &name);
void lifetime_case(OmniSpeakerModelKind kind, const std::string &name);
void fault_case(OmniSpeakerModelKind kind, const std::string &name,
                int allocation_index);
nlohmann::ordered_json trace_case(OmniSpeakerModelKind kind,
                                  const std::string &name);
} // namespace native_test
