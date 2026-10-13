// SPDX-License-Identifier: Apache-2.0
#include "native_silero_worker.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>

using omni_native::ClearSileroError;
using omni_native::SetError;
using omni_native::SileroCommand;
using omni_native::SileroOperation;

int omni_silero_create_checked(const char *model_directory,
                               OmniSileroHandle **handle,
                               char **error_message) {
  ClearSileroError(error_message);
  if (handle == nullptr) {
    SetError(error_message, "Missing Silero model output.");
    return 0;
  } else {
    *handle = nullptr;
  }
  try {
    if (model_directory == nullptr || model_directory[0] == '\0' ||
        !std::filesystem::is_directory(model_directory)) {
      SetError(error_message, "Invalid model directory.");
      return 0;
    } else {
      auto created = std::make_shared<OmniSileroHandle>();
      created->worker = std::make_shared<omni_native::SileroWorker>();
      *handle = omni_native::SileroHandles<OmniSileroHandle>::Insert(created);
      if (created->worker->Load(model_directory)) {
        return 1;
      } else {
        created->worker->is_cancelled.store(true);
        SetError(error_message, "Silero initialization failed.");
        return 0;
      }
    }
  } catch (...) {
    if (*handle != nullptr) {
      (*handle)->worker->is_cancelled.store(true);
    } else {
    }
    SetError(error_message, "Silero initialization failed.");
    return 0;
  }
}

OmniSileroHandle *omni_silero_create(const char *model_directory,
                                     char **error_message) {
  OmniSileroHandle *handle = nullptr;
  if (omni_silero_create_checked(model_directory, &handle, error_message) ==
      1) {
    return handle;
  } else {
    if (omni_silero_destroy_checked(handle, nullptr) != 1) {
      std::fputs(
          "OmniCore Silero failed load retirement failed; model retained.\n",
          stderr);
    } else {
    }
    return nullptr;
  }
}

void omni_silero_cancel(OmniSileroHandle *handle) {
  omni_native::SileroCall call(handle);
  if (call) {
    handle->worker->is_cancelled.store(true);
  } else {
  }
}

int omni_silero_destroy_checked(OmniSileroHandle *handle,
                                char **error_message) {
  ClearSileroError(error_message);
  if (handle == nullptr) {
    return 1;
  } else {
  }
  try {
    const auto retained =
        omni_native::SileroHandles<OmniSileroHandle>::Find(handle);
    if (!retained) {
      SetError(error_message, "Invalid Silero model.");
      return 0;
    } else {
    }
    retained->worker->is_cancelled.store(true);
    std::unique_lock gate(retained->call_mutex);
    if (retained->is_destroyed) {
      return 1;
    } else {
    }
    const auto worker = retained->worker;
    std::lock_guard lock(worker->command_mutex);
    if (std::any_of(worker->leased_slots.begin(), worker->leased_slots.end(),
                    [](bool leased) { return leased; })) {
      SetError(error_message, "Destroy Silero streams before the model.");
      return 0;
    } else {
    }
    SileroCommand command{.operation = SileroOperation::DrainAll};
    worker->Execute(command);
    if (command.error != nullptr) {
      SetError(error_message, command.error);
      return 0;
    } else {
      retained->is_destroyed = true;
      omni_native::SileroHandles<OmniSileroHandle>::Remove(handle);
      return 1;
    }
  } catch (...) {
    SetError(error_message, "Silero model destruction failed.");
    return 0;
  }
}

void omni_silero_destroy(OmniSileroHandle *handle) {
  if (omni_silero_destroy_checked(handle, nullptr) != 1) {
    std::fputs("OmniCore Silero shutdown failed; model retained.\n", stderr);
  } else {
  }
}

OmniSileroRequest *omni_silero_request_create(void) {
  try {
    return omni_native::SileroHandles<OmniSileroRequest>::Insert(
        std::make_shared<OmniSileroRequest>());
  } catch (...) {
    return nullptr;
  }
}

void omni_silero_request_cancel(OmniSileroRequest *request) {
  omni_native::SileroCall call(request);
  if (call) {
    request->cancel->store(true);
  } else {
  }
}

void omni_silero_request_destroy(OmniSileroRequest *request) {
  const auto retained =
      omni_native::SileroHandles<OmniSileroRequest>::Find(request);
  if (retained) {
    retained->cancel->store(true);
    std::unique_lock gate(retained->call_mutex);
    retained->is_destroyed = true;
    omni_native::SileroHandles<OmniSileroRequest>::Remove(request);
  } else {
  }
}

int omni_silero_speech_timestamps(OmniSileroHandle *handle,
                                  OmniSileroRequest *request,
                                  const float *samples, size_t sample_count,
                                  const OmniSileroSettings *settings,
                                  OmniSileroResult *result,
                                  char **error_message) {
  ClearSileroError(error_message);
  if (result != nullptr) {
    *result = {};
  } else {
  }
  omni_native::SileroCall model_call(handle);
  try {
    std::shared_ptr<std::atomic<bool>> cancel;
    {
      omni_native::SileroCall request_call(request);
      if (!request_call) {
        SetError(error_message, "Invalid Silero request.");
        return 0;
      } else if (request->is_used.exchange(true)) {
        SetError(error_message, "Request already used.");
        return 0;
      } else {
        cancel = request->cancel;
      }
    }
    if (!model_call || result == nullptr || settings == nullptr ||
        !omni_native::ValidSileroSamples(samples, sample_count,
                                         OMNI_SILERO_MAX_OFFLINE_SAMPLES)) {
      SetError(error_message, "Invalid Silero input.");
      return 0;
    } else if (!std::isfinite(settings->threshold) || settings->threshold < 0 ||
               settings->threshold > 1 ||
               settings->minimum_speech_milliseconds < 0 ||
               settings->minimum_speech_milliseconds >
                   OMNI_SILERO_MAX_OPTION_MILLISECONDS ||
               settings->minimum_silence_milliseconds < 0 ||
               settings->minimum_silence_milliseconds >
                   OMNI_SILERO_MAX_OPTION_MILLISECONDS ||
               settings->speech_padding_milliseconds < 0 ||
               settings->speech_padding_milliseconds >
                   OMNI_SILERO_MAX_OPTION_MILLISECONDS) {
      SetError(error_message, "Invalid Silero settings.");
      return 0;
    } else {
    }
    const auto worker = handle->worker;
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    SileroCommand command{.operation = SileroOperation::Offline,
                          .cancel = cancel};
    worker->CheckCancelled(command);
    command.options = {settings->threshold,
                       settings->minimum_speech_milliseconds,
                       settings->minimum_silence_milliseconds,
                       settings->speech_padding_milliseconds};
    command.audio_samples.assign(samples, samples + sample_count);
    worker->Execute(command);
    if (command.error != nullptr) {
      SetError(error_message, command.error);
      return 0;
    } else {
    }
    std::unique_ptr<OmniSileroTimestamp, decltype(&std::free)> timestamps(
        nullptr, &std::free);
    if (!command.timestamps.empty()) {
      timestamps.reset(static_cast<OmniSileroTimestamp *>(std::malloc(
          command.timestamps.size() * sizeof(OmniSileroTimestamp))));
      if (!timestamps) {
        throw std::bad_alloc();
      } else {
        for (size_t i = 0; i < command.timestamps.size(); ++i) {
          timestamps.get()[i] = {command.timestamps[i].start,
                                 command.timestamps[i].end};
        }
      }
    } else {
    }
    worker->CheckCancelled(command);
    *result = {timestamps.release(), command.timestamps.size()};
    return 1;
  } catch (const omni_native::SileroCancelled &) {
    SetError(error_message, "Silero operation cancelled.");
    return 0;
  } catch (...) {
    SetError(error_message, "Silero processing failed.");
    return 0;
  }
}

void omni_silero_result_free(OmniSileroResult *result) {
  if (result != nullptr) {
    std::free(result->timestamps);
    *result = {};
  } else {
  }
}
