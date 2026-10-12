// SPDX-License-Identifier: Apache-2.0
#include "native_speaker_state.h"

#include <filesystem>
#include <utility>

void OmniSpeakerRealtime::Cancel() {
  cancel->store(true);
  Fail(OMNI_BATCH_CANCELLED);
  std::lock_guard lock(engine_mutex);
  if (moss_engine) {
    moss_engine->Close();
  } else if (nemotron_engine) {
    nemotron_engine->Close();
  } else {
  }
}

OmniBatchStatus OmniSpeakerRealtime::Drain() {
  Cancel();
  std::lock_guard command_lock(command_mutex);
  if (is_drained) {
    return OMNI_BATCH_OK;
  } else {
    // Note (OpenAI): Close is only a sink barrier. This queued job also waits
    // for callback weak-self locals and captured stream references to expire.
    model->worker->Transcribe(
        [this](const std::atomic<bool> &) {
          std::lock_guard engine_lock(engine_mutex);
          mlx::core::synchronize();
          moss_engine.reset();
          nemotron_engine.reset();
          mlx::core::clear_cache();
          mlx::core::synchronize();
          return qwen3_asr::TranscriptionResult{};
        },
        qwen3_asr::NewCancelFlag());
    is_drained = true;
    return OMNI_BATCH_OK;
  }
}

OmniBatchStatus omni_speaker_create(OmniSpeakerModelKind kind,
                                    const char *model_directory,
                                    OmniSpeakerHandle **handle) {
  if (handle == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *handle = nullptr;
  }
  OmniSpeakerHandle *created = nullptr;
  try {
    if (kind != OMNI_SPEAKER_MOSS && kind != OMNI_SPEAKER_NEMOTRON) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    std::optional<std::string> directory;
    const auto status = omni_native::SpeakerInputString(
        model_directory, OMNI_SPEAKER_MAX_PROMPT_BYTES, directory);
    if (status != OMNI_BATCH_OK) {
      return status;
    } else if (!directory || directory->empty()) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    const std::filesystem::path path(*directory);
    std::error_code error;
    if (!std::filesystem::is_directory(path, error) || error) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    created = new OmniSpeakerHandle(kind);
    // Note (OpenAI): an empty initial load keeps worker-constructor faults free
    // of GPU ownership; actual loading is a caught job on that same thread.
    created->worker =
        std::make_unique<qwen3_asr::TranscriptionWorker>([] {}, false);
    created->worker->Transcribe(
        [created, &path](const std::atomic<bool> &) {
          if (created->kind == OMNI_SPEAKER_MOSS) {
            created->moss_model = std::make_unique<moss::MossTranscriber>(path);
          } else {
            created->nemotron_model =
                std::make_unique<nemotron::NemotronTranscriber>(path);
          }
          return qwen3_asr::TranscriptionResult{};
        },
        qwen3_asr::NewCancelFlag());
    *handle = created;
    return OMNI_BATCH_OK;
  } catch (...) {
    const auto status = omni_native::SpeakerExceptionStatus();
    if (omni_speaker_destroy_checked(created) != OMNI_BATCH_OK) {
      *handle = created;
    } else {
    }
    return status;
  }
}

void omni_speaker_cancel(OmniSpeakerHandle *handle) {
  if (handle == nullptr) {
    return;
  } else {
    handle->is_cancelled.store(true);
  }
  try {
    std::lock_guard lock(handle->lease_mutex);
    if (handle->lease != nullptr) {
      handle->lease->Cancel();
    } else {
    }
  } catch (...) {
    // Note (OpenAI): the sticky admission flag survives a failed cancellation.
  }
}

OmniBatchStatus omni_speaker_destroy_checked(OmniSpeakerHandle *handle) {
  if (handle == nullptr) {
    return OMNI_BATCH_OK;
  } else {
  }
  try {
    {
      std::lock_guard lock(handle->lease_mutex);
      if (handle->lease != nullptr) {
        return OMNI_BATCH_BUSY;
      } else {
        handle->is_cancelled.store(true);
      }
    }
    if (handle->worker) {
      handle->worker->Transcribe(
          [handle](const std::atomic<bool> &) {
            mlx::core::synchronize();
            handle->moss_model.reset();
            handle->nemotron_model.reset();
            mlx::core::clear_cache();
            mlx::core::synchronize();
            return qwen3_asr::TranscriptionResult{};
          },
          qwen3_asr::NewCancelFlag());
      handle->worker.reset();
    } else {
    }
    delete handle;
    return OMNI_BATCH_OK;
  } catch (...) {
    return omni_native::SpeakerExceptionStatus();
  }
}

OmniBatchStatus
omni_speaker_realtime_create(OmniSpeakerHandle *handle, uint64_t session_id,
                             const OmniSpeakerRealtimeSettings *settings,
                             OmniSpeakerRealtime **stream) {
  if (stream == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *stream = nullptr;
  }
  OmniSpeakerRealtime *created = nullptr;
  OmniBatchStatus status = OMNI_BATCH_OK;
  try {
    if (handle == nullptr || session_id == 0) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    omni_native::SpeakerSettings copied_settings;
    {
      std::unique_lock lock(handle->lease_mutex, std::try_to_lock);
      if (!lock.owns_lock() || handle->lease != nullptr) {
        return OMNI_BATCH_BUSY;
      } else if (handle->is_cancelled.load()) {
        return OMNI_BATCH_CANCELLED;
      } else {
      }
      status = omni_native::SpeakerValidateSettings(handle->kind, settings,
                                                    copied_settings);
      if (status != OMNI_BATCH_OK) {
        return status;
      } else {
        created = new OmniSpeakerRealtime(handle, session_id);
        handle->lease = created;
      }
    }
    handle->worker->Transcribe(
        [created, &copied_settings](const std::atomic<bool> &) {
          std::lock_guard lock(created->engine_mutex);
          auto *model = created->model;
          auto receive =
              [created](const qwen3_asr::SpeakerRealtimeEvent &event) {
                created->Receive(event);
              };
          if (model->kind == OMNI_SPEAKER_MOSS) {
            created->moss_engine = std::make_shared<moss::MossRealtimeEngine>(
                *model->worker, *model->moss_model, receive, created->cancel);
            created->moss_engine->UpdatePrompt(copied_settings.prompt);
          } else {
            created->nemotron_engine =
                std::make_shared<nemotron::NemotronRealtimeEngine>(
                    *model->worker, *model->nemotron_model, receive,
                    created->cancel);
            created->nemotron_engine->UpdateSettings(
                copied_settings.language, copied_settings.chunk_milliseconds);
            created->nemotron_engine->PrepareStream();
          }
          return qwen3_asr::TranscriptionResult{};
        },
        qwen3_asr::NewCancelFlag());
    status = created->status.load();
  } catch (...) {
    status = omni_native::SpeakerExceptionStatus();
  }
  if (status == OMNI_BATCH_OK) {
    *stream = created;
  } else if (omni_speaker_realtime_destroy_checked(created) != OMNI_BATCH_OK) {
    *stream = created;
  } else {
  }
  return status;
}

void omni_speaker_realtime_cancel(OmniSpeakerRealtime *stream) {
  if (stream == nullptr) {
    return;
  } else {
    stream->cancel->store(true);
  }
  try {
    stream->Cancel();
  } catch (...) {
    // Note (OpenAI): cancellation never proves cleanup, even if Close fails.
  }
}

OmniBatchStatus omni_speaker_realtime_drain(OmniSpeakerRealtime *stream) {
  if (stream == nullptr) {
    return OMNI_BATCH_OK;
  } else {
    try {
      return stream->Drain();
    } catch (...) {
      return omni_native::SpeakerExceptionStatus();
    }
  }
}

OmniBatchStatus
omni_speaker_realtime_destroy_checked(OmniSpeakerRealtime *stream) {
  if (stream == nullptr) {
    return OMNI_BATCH_OK;
  } else {
  }
  try {
    const auto status = stream->Drain();
    if (status != OMNI_BATCH_OK) {
      return status;
    } else {
      std::lock_guard lock(stream->model->lease_mutex);
      stream->model->lease = nullptr;
      delete stream;
      return OMNI_BATCH_OK;
    }
  } catch (...) {
    return omni_native::SpeakerExceptionStatus();
  }
}
