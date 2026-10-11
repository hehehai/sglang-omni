// SPDX-License-Identifier: Apache-2.0
#include "native_realtime_state.h"

#include <cstring>
#include <future>
#include <utility>

namespace omni_native {

size_t QueuedEvent::StringBytes() const {
  if (kind == OMNI_QWEN_REALTIME_SEGMENT ||
      kind == OMNI_QWEN_REALTIME_COMPLETED) {
    return text.size() + 1;
  } else if (error_message != nullptr) {
    return std::strlen(error_message) + 1;
  } else {
    return 0;
  }
}

RealtimeState::RealtimeState(std::shared_ptr<ModelState> model,
                             uint64_t session_id)
    : model(std::move(model)), session_id(session_id) {}

void RealtimeState::SetTerminalLocked(OmniQwenRealtimeEventKind kind,
                                      const char *message) {
  if (terminal != 0) {
    return;
  } else {
    QueuedEvent &event = events[(head + event_count) % events.size()];
    event.kind = kind;
    event.error_message = message;
    event.sequence = next_event_sequence++;
    queued_string_bytes += event.StringBytes();
    ++event_count;
    terminal = kind;
    cancel->store(true);
  }
}

void RealtimeState::Receive(const qwen3_asr::RealtimeEvent &received) noexcept {
  bool should_close = false;
  {
    std::lock_guard<std::mutex> lock(queue_mutex);
    if (terminal != 0) {
      return;
    } else {
    }
    try {
      QueuedEvent event;
      const std::string *text = nullptr;
      if (std::holds_alternative<qwen3_asr::RealtimeUpdated>(received)) {
        event.kind = OMNI_QWEN_REALTIME_UPDATED;
      } else if (const auto *segment =
                     std::get_if<qwen3_asr::RealtimeSegment>(&received)) {
        event.kind = OMNI_QWEN_REALTIME_SEGMENT;
        event.segment_id = segment->segment_id;
        event.is_final = segment->is_final ? 1 : 0;
        text = &segment->text;
      } else if (const auto *completed =
                     std::get_if<qwen3_asr::RealtimeCompleted>(&received)) {
        event.kind = OMNI_QWEN_REALTIME_COMPLETED;
        text = &completed->text;
      } else {
        SetTerminalLocked(OMNI_QWEN_REALTIME_FAILED,
                          "Realtime transcription failed.");
        should_close = true;
      }
      if (should_close) {
      } else if (text != nullptr &&
                 (text->size() > OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES ||
                  text->find('\0') != std::string::npos)) {
        SetTerminalLocked(OMNI_QWEN_REALTIME_FAILED,
                          "Realtime event text exceeds output limits.");
        should_close = true;
      } else {
        const bool is_completed = event.kind == OMNI_QWEN_REALTIME_COMPLETED;
        const size_t string_bytes = text == nullptr ? 0 : text->size() + 1;
        const bool is_final_segment =
            event.kind == OMNI_QWEN_REALTIME_SEGMENT && event.is_final != 0;
        const size_t transcript_bytes =
            !is_final_segment || text->empty()
                ? 0
                : text->size() + (committed_transcript_bytes == 0 ? 0 : 1);
        // Note (OpenAI): failure publication must remain allocation-free.
        constexpr size_t FAILURE_RESERVE_BYTES = 128;
        const size_t reserve_bytes = is_completed ? 0 : FAILURE_RESERVE_BYTES;
        if (is_final_segment &&
            (final_segment_count >= OMNI_QWEN_REALTIME_MAX_FINAL_SEGMENTS ||
             transcript_bytes > OMNI_QWEN_REALTIME_MAX_TRANSCRIPT_BYTES -
                                    committed_transcript_bytes)) {
          SetTerminalLocked(OMNI_QWEN_REALTIME_FAILED,
                            "Realtime transcript capacity exceeded.");
          should_close = true;
        } else if ((!is_completed && event_count >= events.size() - 1) ||
                   queued_string_bytes + string_bytes + reserve_bytes >
                       OMNI_QWEN_REALTIME_MAX_QUEUED_STRING_BYTES) {
          SetTerminalLocked(OMNI_QWEN_REALTIME_FAILED,
                            "Realtime event queue capacity exceeded.");
          should_close = true;
        } else {
          if (text != nullptr) {
            event.text = *text;
          } else {
          }
          event.sequence = next_event_sequence++;
          events[(head + event_count) % events.size()] = std::move(event);
          queued_string_bytes += string_bytes;
          ++event_count;
          if (is_final_segment) {
            ++final_segment_count;
            committed_transcript_bytes += transcript_bytes;
          } else {
          }
          if (is_completed) {
            terminal = OMNI_QWEN_REALTIME_COMPLETED;
          } else {
          }
        }
      }
    } catch (...) {
      SetTerminalLocked(OMNI_QWEN_REALTIME_FAILED,
                        "Realtime event allocation failed.");
      should_close = true;
    }
  }
  if (should_close) {
    engine->Close();
  } else {
  }
}

void RealtimeState::Cancel() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex);
    SetTerminalLocked(OMNI_QWEN_REALTIME_CANCELLED, nullptr);
    cancel->store(true);
  }
  engine->Close();
}

void RealtimeState::Fail(const char *message) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex);
    SetTerminalLocked(OMNI_QWEN_REALTIME_FAILED, message);
    cancel->store(true);
  }
  engine->Close();
}

bool RealtimeState::Drain() {
  std::lock_guard<std::mutex> command_lock(command_mutex);
  {
    std::lock_guard<std::mutex> queue_lock(queue_mutex);
    if (terminal == 0) {
      return false;
    } else {
    }
  }
  if (is_drained) {
    return true;
  } else {
  }
  engine->Close();
  // Note (OpenAI): a callback can have passed its cancel check before Close
  // and enqueue behind barrier one; barrier two drains that late submission.
  for (int i = 0; i < 2; ++i) {
    auto promise = std::make_shared<std::promise<void>>();
    auto completed = promise->get_future();
    model->worker->Submit(
        [](const std::atomic<bool> &) {
          return qwen3_asr::TranscriptionResult{};
        },
        qwen3_asr::NewCancelFlag(),
        [promise](std::optional<qwen3_asr::TranscriptionResult>,
                  std::exception_ptr) { promise->set_value(); });
    // Note (OpenAI): even a model-cancelled barrier must await its completion.
    completed.get();
  }
  is_drained = true;
  return true;
}

void ModelState::Stop(bool drain) {
  size_t session_count;
  {
    std::lock_guard<std::mutex> lock(mutex);
    is_cancelled = true;
    session_count = sessions.size();
  }
  worker->CancelAll();
  for (int pass = 0; pass < (drain ? 2 : 1); ++pass) {
    for (size_t i = 0; i < session_count; ++i) {
      std::shared_ptr<RealtimeState> session;
      {
        std::lock_guard<std::mutex> lock(mutex);
        session = sessions[i].lock();
      }
      if (session == nullptr) {
      } else if (pass == 0) {
        session->Cancel();
      } else {
        session->Drain();
      }
    }
  }
}

} // namespace omni_native
