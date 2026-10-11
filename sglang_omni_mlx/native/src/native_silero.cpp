// SPDX-License-Identifier: Apache-2.0
#include "native_silero_worker.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>

using omni_native::ClearSileroError;
using omni_native::SetError;
using omni_native::SileroCommand;
using omni_native::SileroOperation;

OmniSileroHandle *omni_silero_create(const char *model_directory,
                                     char **error_message) {
  ClearSileroError(error_message);
  try {
    if (model_directory == nullptr || model_directory[0] == '\0' ||
        !std::filesystem::is_directory(model_directory)) {
      SetError(error_message, "Invalid model directory.");
      return nullptr;
    } else {
      auto handle = std::make_unique<OmniSileroHandle>();
      handle->worker =
          std::make_shared<omni_native::SileroWorker>(model_directory);
      return handle.release();
    }
  } catch (...) {
    SetError(error_message, "Silero initialization failed.");
    return nullptr;
  }
}

void omni_silero_cancel(OmniSileroHandle *handle) {
  if (handle != nullptr) {
    handle->worker->is_cancelled.store(true);
  } else {
  }
}

void omni_silero_destroy(OmniSileroHandle *handle) {
  try {
    if (handle != nullptr) {
      const auto worker = handle->worker;
      worker->is_cancelled.store(true);
      {
        std::lock_guard<std::mutex> lock(worker->command_mutex);
        SileroCommand command{.operation = SileroOperation::DrainAll};
        worker->Execute(command);
      }
      delete handle;
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore Silero shutdown failed; model retained.\n", stderr);
  }
}

OmniSileroRequest *omni_silero_request_create(void) {
  try {
    return new OmniSileroRequest();
  } catch (...) {
    return nullptr;
  }
}

void omni_silero_request_cancel(OmniSileroRequest *request) {
  if (request != nullptr) {
    request->cancel->store(true);
  } else {
  }
}

void omni_silero_request_destroy(OmniSileroRequest *request) {
  omni_silero_request_cancel(request);
  delete request;
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
  try {
    if (request == nullptr) {
      SetError(error_message, "Invalid Silero request.");
      return 0;
    } else if (request->is_used.exchange(true)) {
      SetError(error_message, "Request already used.");
      return 0;
    } else {
    }
    const auto cancel = request->cancel;
    if (handle == nullptr || result == nullptr || settings == nullptr ||
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
