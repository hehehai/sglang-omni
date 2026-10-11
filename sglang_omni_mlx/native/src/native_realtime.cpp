// SPDX-License-Identifier: Apache-2.0
#include "omni_native_core.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "native_realtime_state.h"

using omni_native::CopyString;
using omni_native::SetError;

namespace {

bool IsBoundedString(const char *string, size_t maximum_bytes) {
  if (string == nullptr) {
    return true;
  } else {
    for (size_t i = 0; i <= maximum_bytes; ++i) {
      if (string[i] == '\0') {
        return true;
      } else {
      }
    }
    return false;
  }
}

void ClearError(char **error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  } else {
  }
}

const char *TerminalError(OmniQwenRealtimeEventKind terminal) {
  switch (terminal) {
  case OMNI_QWEN_REALTIME_COMPLETED:
    return "Realtime session is completed.";
  case OMNI_QWEN_REALTIME_CANCELLED:
    return "Realtime session is cancelled.";
  case OMNI_QWEN_REALTIME_FAILED:
    return "Realtime session has failed.";
  default:
    return "Realtime session is not terminal.";
  }
}

} // namespace

OmniQwenRealtime *
omni_qwen_realtime_create(OmniQwenHandle *handle, uint64_t session_id,
                          const OmniQwenRealtimeSettings *settings,
                          const char *language, const char *context,
                          char **error_message) {
  ClearError(error_message);
  try {
    if (handle == nullptr || session_id == 0 || settings == nullptr ||
        !IsBoundedString(language, OMNI_QWEN_REALTIME_MAX_LANGUAGE_BYTES) ||
        !IsBoundedString(context, OMNI_QWEN_REALTIME_MAX_CONTEXT_BYTES)) {
      SetError(error_message, "Invalid realtime input.");
      return nullptr;
    } else if (settings->decode_interval_samples < 1 ||
               settings->decode_interval_samples >
                   OMNI_QWEN_REALTIME_MAX_SESSION_SAMPLES ||
               settings->first_decode_samples < 1 ||
               settings->first_decode_samples >
                   OMNI_QWEN_REALTIME_MAX_SESSION_SAMPLES ||
               settings->maximum_segment_samples < 1 ||
               settings->maximum_segment_samples >
                   OMNI_QWEN_REALTIME_MAX_SESSION_SAMPLES ||
               settings->maximum_token_count < 1 ||
               settings->maximum_token_count >
                   OMNI_QWEN_REALTIME_MAX_TOKEN_COUNT) {
      SetError(error_message, "Invalid realtime settings.");
      return nullptr;
    } else {
    }
    const auto model = handle->state;
    auto session = std::make_unique<OmniQwenRealtime>();
    auto state =
        std::make_shared<omni_native::RealtimeState>(model, session_id);
    qwen3_asr::TranscriptionOptions options;
    options.language =
        qwen3_asr::NormalizeLanguage(language == nullptr ? "" : language);
    options.context =
        context == nullptr ? std::nullopt : std::optional<std::string>(context);
    options.max_new_tokens = settings->maximum_token_count;
    options.stop_at_end_of_text = true;
    options.stop_on_token_loop = true;
    options.layout = qwen3_asr::AudioLayout::kVoxtSwift;
    state->engine = std::make_shared<qwen3_asr::RealtimeEngine>(
        *model->worker, *model->transcriber,
        qwen3_asr::RealtimeSettings{settings->decode_interval_samples,
                                    settings->first_decode_samples,
                                    settings->maximum_segment_samples},
        [weak_state =
             std::weak_ptr(state)](const qwen3_asr::RealtimeEvent &event) {
          if (auto state = weak_state.lock()) {
            state->Receive(event);
          } else {
          }
        },
        state->cancel, options);
    std::lock_guard<std::mutex> command_lock(state->command_mutex);
    {
      std::lock_guard<std::mutex> model_lock(model->mutex);
      if (model->is_cancelled) {
        SetError(error_message, "Transcription cancelled.");
        return nullptr;
      } else {
        std::erase_if(model->sessions,
                      [](const auto &session) { return session.expired(); });
        model->sessions.push_back(state);
      }
    }
    state->engine->UpdateLanguage(options.language);
    session->state = std::move(state);
    return session.release();
  } catch (...) {
    SetError(error_message, "Realtime initialization failed.");
    return nullptr;
  }
}

int omni_qwen_realtime_push(OmniQwenRealtime *session, uint64_t audio_sequence,
                            const float *samples, size_t sample_count,
                            uint64_t *accepted_audio_sequence,
                            char **error_message) {
  ClearError(error_message);
  if (accepted_audio_sequence != nullptr) {
    *accepted_audio_sequence = 0;
  } else {
  }
  try {
    if (session == nullptr || accepted_audio_sequence == nullptr ||
        audio_sequence == 0 || samples == nullptr || sample_count == 0 ||
        sample_count > OMNI_QWEN_REALTIME_MAX_CHUNK_SAMPLES) {
      SetError(error_message, "Invalid realtime input.");
      return 0;
    } else if (!std::all_of(samples, samples + sample_count, [](float sample) {
                 return std::isfinite(sample);
               })) {
      SetError(error_message, "Audio samples must be finite.");
      return 0;
    } else {
    }
    const auto &state = session->state;
    std::lock_guard<std::mutex> command_lock(state->command_mutex);
    std::vector<float> audio_samples(samples, samples + sample_count);
    {
      std::scoped_lock admission_lock(state->model->mutex, state->queue_mutex);
      if (state->terminal != 0) {
        SetError(error_message, TerminalError(state->terminal));
        return 0;
      } else if (state->model->is_cancelled) {
        SetError(error_message, "Transcription cancelled.");
        return 0;
      } else if (audio_sequence != state->accepted_audio_sequence + 1) {
        SetError(error_message, "Invalid audio sequence.");
        return 0;
      } else if (sample_count > OMNI_QWEN_REALTIME_MAX_SESSION_SAMPLES -
                                    state->admitted_sample_count) {
        SetError(error_message, "Realtime sample limit exceeded.");
        return 0;
      } else if (state->event_count >= state->events.size() - 1) {
        SetError(error_message, "Realtime event queue backpressure.");
        return 0;
      } else {
        state->accepted_audio_sequence = audio_sequence;
        state->admitted_sample_count += sample_count;
        *accepted_audio_sequence = audio_sequence;
      }
    }
    try {
      state->engine->Append(std::move(audio_samples));
    } catch (...) {
      state->Fail("Realtime audio processing failed.");
    }
    return 1;
  } catch (...) {
    SetError(error_message, "Realtime audio admission failed.");
    return 0;
  }
}

int omni_qwen_realtime_finish(OmniQwenRealtime *session, char **error_message) {
  ClearError(error_message);
  try {
    if (session == nullptr) {
      SetError(error_message, "Invalid realtime input.");
      return 0;
    } else {
    }
    const auto &state = session->state;
    std::lock_guard<std::mutex> command_lock(state->command_mutex);
    try {
      state->engine->Finish();
    } catch (...) {
      state->Fail("Realtime finalization failed.");
    }
    std::lock_guard<std::mutex> queue_lock(state->queue_mutex);
    if (state->terminal == OMNI_QWEN_REALTIME_COMPLETED) {
      return 1;
    } else {
      SetError(error_message, TerminalError(state->terminal));
      return 0;
    }
  } catch (...) {
    SetError(error_message, "Realtime finalization failed.");
    return 0;
  }
}

int omni_qwen_realtime_poll(OmniQwenRealtime *session,
                            OmniQwenRealtimeEvent *event,
                            char **error_message) {
  ClearError(error_message);
  if (event != nullptr) {
    *event = {};
  } else {
  }
  try {
    if (session == nullptr || event == nullptr) {
      SetError(error_message, "Invalid realtime input.");
      return -1;
    } else {
    }
    const auto &state = session->state;
    std::lock_guard<std::mutex> queue_lock(state->queue_mutex);
    if (state->event_count == 0) {
      return 0;
    } else {
      auto &queued = state->events[state->head];
      const bool has_text = queued.kind == OMNI_QWEN_REALTIME_SEGMENT ||
                            queued.kind == OMNI_QWEN_REALTIME_COMPLETED;
      std::unique_ptr<char, decltype(&std::free)> text(
          has_text ? CopyString(queued.text) : nullptr, &std::free);
      std::unique_ptr<char, decltype(&std::free)> failure(
          queued.error_message == nullptr ? nullptr
                                          : CopyString(queued.error_message),
          &std::free);
      *event = {state->session_id, queued.sequence, queued.kind,
                queued.segment_id, queued.is_final, text.release(),
                failure.release()};
      state->queued_string_bytes -= queued.StringBytes();
      queued = {};
      state->head = (state->head + 1) % state->events.size();
      --state->event_count;
      return 1;
    }
  } catch (...) {
    SetError(error_message, "Realtime poll allocation failed.");
    return -1;
  }
}

void omni_qwen_realtime_cancel(OmniQwenRealtime *session) {
  try {
    if (session != nullptr) {
      session->state->Cancel();
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore realtime cancellation failed.\n", stderr);
  }
}

int omni_qwen_realtime_drain(OmniQwenRealtime *session, char **error_message) {
  ClearError(error_message);
  try {
    if (session == nullptr) {
      SetError(error_message, "Invalid realtime input.");
      return 0;
    } else if (!session->state->Drain()) {
      SetError(error_message, "Realtime session is not terminal.");
      return 0;
    } else {
      return 1;
    }
  } catch (...) {
    SetError(error_message, "Realtime drain failed.");
    return 0;
  }
}

void omni_qwen_realtime_destroy(OmniQwenRealtime *session) {
  try {
    if (session != nullptr) {
      session->state->Cancel();
      session->state->Drain();
      delete session;
    } else {
    }
  } catch (...) {
    // Note (OpenAI): retaining the lease is safer than freeing undrained work.
    std::fputs("OmniCore realtime shutdown failed; lease retained.\n", stderr);
  }
}

void omni_qwen_realtime_event_free(OmniQwenRealtimeEvent *event) {
  if (event != nullptr) {
    std::free(event->text);
    std::free(event->error_message);
    *event = {};
  } else {
  }
}
