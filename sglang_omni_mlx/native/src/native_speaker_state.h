// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>

#include "moss_realtime_engine.h"
#include "nemotron_realtime_engine.h"
#include "omni_native_speaker.h"

namespace omni_native {

struct SpeakerSettings {
  std::optional<std::string> prompt;
  std::optional<std::string> language;
  std::optional<double> chunk_milliseconds;
};

struct SpeakerQueuedEvent {
  uint64_t sequence = 0;
  OmniSpeakerRealtimeEventKind kind = OMNI_SPEAKER_UPDATED;
  OmniBatchStatus failure_status = OMNI_BATCH_OK;
  size_t string_bytes = 0;
  qwen3_asr::SpeakerRealtimeEvent source = qwen3_asr::SpeakerRealtimeUpdated{};
};

OmniBatchStatus SpeakerExceptionStatus() noexcept;
bool SpeakerUtf8(std::string_view text) noexcept;
OmniBatchStatus SpeakerInputString(const char *text, size_t maximum_bytes,
                                   std::optional<std::string> &copy);
OmniBatchStatus
SpeakerValidateSettings(OmniSpeakerModelKind kind,
                        const OmniSpeakerRealtimeSettings *settings,
                        SpeakerSettings &copy);
OmniBatchStatus SpeakerEventBytes(const qwen3_asr::SpeakerRealtimeEvent &event,
                                  size_t &string_bytes);
void SpeakerCopyEvent(const SpeakerQueuedEvent &source, uint64_t session_id,
                      OmniSpeakerRealtimeEvent &event);

} // namespace omni_native

struct OmniSpeakerHandle {
  explicit OmniSpeakerHandle(OmniSpeakerModelKind model_kind)
      : kind(model_kind) {}
  const OmniSpeakerModelKind kind;
  std::mutex lease_mutex;
  std::atomic<bool> is_cancelled{false};
  OmniSpeakerRealtime *lease = nullptr;
  std::unique_ptr<qwen3_asr::TranscriptionWorker> worker;
  std::unique_ptr<moss::MossTranscriber> moss_model;
  std::unique_ptr<nemotron::NemotronTranscriber> nemotron_model;
};

struct OmniSpeakerRealtime {
  OmniSpeakerRealtime(OmniSpeakerHandle *model, uint64_t session_id)
      : model(model), session_id(session_id) {}
  void Receive(const qwen3_asr::SpeakerRealtimeEvent &event) noexcept;
  void Fail(OmniBatchStatus status) noexcept;
  void FailLocked(OmniBatchStatus status);
  void Cancel();
  OmniBatchStatus Drain();

  OmniSpeakerHandle *const model;
  const uint64_t session_id;
  const qwen3_asr::CancelFlag cancel = qwen3_asr::NewCancelFlag();
  std::atomic<OmniBatchStatus> status{OMNI_BATCH_OK};
  std::mutex command_mutex;
  bool is_drained = false;
  bool is_finished = false;
  bool is_committed = false;
  size_t admitted_samples = 0;
  uint64_t audio_sequence = 0;

  // Note (OpenAI): only cancellation pins this guard through Close; sinks must
  // never acquire it, since Close waits for the sink to return.
  std::mutex engine_mutex;
  std::shared_ptr<moss::MossRealtimeEngine> moss_engine;
  std::shared_ptr<nemotron::NemotronRealtimeEngine> nemotron_engine;

  std::mutex event_mutex;
  std::array<omni_native::SpeakerQueuedEvent, OMNI_SPEAKER_MAX_QUEUED_EVENTS>
      events;
  size_t queue_head = 0;
  size_t queue_count = 0;
  size_t queued_string_bytes = 0;
  uint64_t next_event_sequence = 1;
  bool has_terminal = false;
};
