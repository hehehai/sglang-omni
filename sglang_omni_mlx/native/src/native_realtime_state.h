// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "native_core_internal.h"
#include "omni_native_core.h"
#include "realtime_engine.h"

namespace omni_native {

struct QueuedEvent {
  uint64_t sequence = 0;
  OmniQwenRealtimeEventKind kind = 0;
  int32_t segment_id = 0;
  int32_t is_final = 0;
  std::string text;
  const char *error_message = nullptr;

  size_t StringBytes() const;
};

struct RealtimeState {
  explicit RealtimeState(std::shared_ptr<ModelState> model,
                         uint64_t session_id);

  void Receive(const qwen3_asr::RealtimeEvent &event) noexcept;
  void Cancel();
  void Fail(const char *message);
  bool Drain();
  void SetTerminalLocked(OmniQwenRealtimeEventKind kind, const char *message);

  const std::shared_ptr<ModelState> model;
  const uint64_t session_id;
  const qwen3_asr::CancelFlag cancel = qwen3_asr::NewCancelFlag();
  std::shared_ptr<qwen3_asr::RealtimeEngine> engine;
  std::mutex command_mutex;
  bool is_drained = false;
  uint64_t accepted_audio_sequence = 0;
  size_t admitted_sample_count = 0;

  std::mutex queue_mutex;
  std::array<QueuedEvent, OMNI_QWEN_REALTIME_MAX_QUEUED_EVENTS> events;
  size_t head = 0;
  size_t event_count = 0;
  size_t queued_string_bytes = 0;
  size_t final_segment_count = 0;
  size_t committed_transcript_bytes = 0;
  uint64_t next_event_sequence = 1;
  OmniQwenRealtimeEventKind terminal = 0;
};

} // namespace omni_native

struct OmniQwenRealtime {
  std::shared_ptr<omni_native::RealtimeState> state;
};
