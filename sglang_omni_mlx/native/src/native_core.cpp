// SPDX-License-Identifier: Apache-2.0
#include "omni_native_core.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <future>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "native_core_internal.h"
#include "transcriber.h"
#include "worker.h"

struct OmniQwenRequest {
  std::mutex mutex;
  bool is_used = false;
  qwen3_asr::CancelFlag cancel = qwen3_asr::NewCancelFlag();
};

namespace omni_native {

char *CopyString(std::string_view string) {
  char *copy = static_cast<char *>(std::malloc(string.size() + 1));
  if (copy == nullptr) {
    throw std::bad_alloc();
  } else {
    std::memcpy(copy, string.data(), string.size());
    copy[string.size()] = '\0';
    return copy;
  }
}

void SetError(char **error_message, const char *message) noexcept {
  if (error_message != nullptr) {
    const size_t byte_count = std::strlen(message) + 1;
    *error_message = static_cast<char *>(std::malloc(byte_count));
    if (*error_message != nullptr) {
      std::memcpy(*error_message, message, byte_count);
    } else {
    }
  } else {
  }
}

} // namespace omni_native

using omni_native::CopyString;
using omni_native::SetError;

unsigned int omni_core_abi_version(void) { return 9; }

OmniQwenHandle *omni_qwen_create(const char *model_directory,
                                 char **error_message) {
  if (error_message != nullptr) {
    *error_message = nullptr;
  } else {
  }
  try {
    if (model_directory == nullptr || model_directory[0] == '\0' ||
        !std::filesystem::is_directory(model_directory)) {
      SetError(error_message, "Invalid model directory.");
      return nullptr;
    } else {
      auto handle = std::make_unique<OmniQwenHandle>();
      handle->state = std::make_shared<omni_native::ModelState>();
      // Note (Codex): Run retains load until worker exit; only that callback
      // owns the model, so its last release stays on the loading thread.
      handle->state->worker = std::make_unique<qwen3_asr::TranscriptionWorker>(
          [pointer = handle->state.get(),
           directory = std::filesystem::path(model_directory),
           transcriber =
               std::shared_ptr<qwen3_asr::Qwen3ASRTranscriber>()]() mutable {
            transcriber =
                std::make_shared<qwen3_asr::Qwen3ASRTranscriber>(directory);
            pointer->transcriber = transcriber.get();
          });
      return handle.release();
    }
  } catch (...) {
    SetError(error_message, "Model initialization failed.");
    return nullptr;
  }
}

namespace {

constexpr size_t MAXIMUM_SAMPLE_COUNT = 16000 * 30;
constexpr int MAXIMUM_TOKEN_COUNT = 4096;

int Transcribe(OmniQwenHandle *handle, OmniQwenRequest *request,
               const float *samples, size_t sample_count, const char *language,
               const char *context, int maximum_token_count,
               OmniQwenResult *result, char **error_message) {
  if (result != nullptr) {
    *result = {};
  } else {
  }
  if (error_message != nullptr) {
    *error_message = nullptr;
  } else {
  }
  try {
    std::future<qwen3_asr::TranscriptionResult> future;
    {
      std::unique_lock<std::mutex> request_lock;
      qwen3_asr::CancelFlag cancel;
      if (request != nullptr) {
        request_lock = std::unique_lock<std::mutex>(request->mutex);
        if (request->is_used) {
          SetError(error_message, "Request already used.");
          return 0;
        } else {
          request->is_used = true;
          cancel = request->cancel;
        }
      } else {
        cancel = qwen3_asr::NewCancelFlag();
      }
      if (handle == nullptr || result == nullptr || samples == nullptr ||
          sample_count == 0 || sample_count > MAXIMUM_SAMPLE_COUNT ||
          maximum_token_count < 1 ||
          maximum_token_count > MAXIMUM_TOKEN_COUNT) {
        SetError(error_message, "Invalid transcription input.");
        return 0;
      } else {
        auto *const state = handle->state.get();
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->is_cancelled || cancel->load()) {
          throw qwen3_asr::TranscriptionCancelled();
        } else {
        }
        if (!std::all_of(samples, samples + sample_count,
                         [](float sample) { return std::isfinite(sample); })) {
          SetError(error_message, "Audio samples must be finite.");
          return 0;
        } else {
        }
        qwen3_asr::TranscriptionOptions options;
        options.language =
            qwen3_asr::NormalizeLanguage(language == nullptr ? "" : language);
        options.context = context == nullptr
                              ? std::nullopt
                              : std::optional<std::string>(context);
        options.max_new_tokens = maximum_token_count;
        options.stop_at_end_of_text = true;
        options.stop_on_token_loop = true;
        options.layout = qwen3_asr::AudioLayout::kVoxtSwift;
        auto promise =
            std::make_shared<std::promise<qwen3_asr::TranscriptionResult>>();
        future = promise->get_future();
        // Note (Codex): locks cover submission; afterwards only the future
        // is used, so model/token destruction cannot invalidate caller state.
        state->worker->Submit(
            [transcriber = state->transcriber,
             audio_samples =
                 std::vector<float>(samples, samples + sample_count),
             options = std::move(options)](const std::atomic<bool> &cancel) {
              auto transcription =
                  transcriber->Transcribe(audio_samples, options, cancel);
              if (cancel.load()) {
                throw qwen3_asr::TranscriptionCancelled();
              } else {
                return transcription;
              }
            },
            std::move(cancel),
            [promise](
                std::optional<qwen3_asr::TranscriptionResult> transcription,
                std::exception_ptr error) {
              if (error) {
                promise->set_exception(error);
              } else {
                promise->set_value(std::move(*transcription));
              }
            });
      }
    }
    const auto transcription = future.get();
    std::unique_ptr<char, decltype(&std::free)> text(
        CopyString(transcription.text), &std::free);
    std::unique_ptr<char, decltype(&std::free)> detected_language(
        transcription.language ? CopyString(*transcription.language) : nullptr,
        &std::free);
    *result = {text.release(), detected_language.release(),
               transcription.generated_token_count,
               transcription.finish_reason == qwen3_asr::FinishReason::kLength
                   ? 1
                   : 0};
    return 1;
  } catch (const qwen3_asr::TranscriptionCancelled &) {
    SetError(error_message, "Transcription cancelled.");
    return 0;
  } catch (...) {
    SetError(error_message, "Transcription failed.");
    return 0;
  }
}

} // namespace

int omni_qwen_transcribe(OmniQwenHandle *handle, const float *samples,
                         size_t sample_count, const char *language,
                         const char *context, int maximum_token_count,
                         OmniQwenResult *result, char **error_message) {
  return Transcribe(handle, nullptr, samples, sample_count, language, context,
                    maximum_token_count, result, error_message);
}

OmniQwenRequest *omni_qwen_request_create(void) {
  try {
    return new OmniQwenRequest();
  } catch (...) {
    return nullptr;
  }
}

void omni_qwen_request_cancel(OmniQwenRequest *request) {
  try {
    if (request != nullptr) {
      std::lock_guard<std::mutex> lock(request->mutex);
      request->cancel->store(true);
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore request cancellation failed.\n", stderr);
  }
}

void omni_qwen_request_destroy(OmniQwenRequest *request) {
  try {
    if (request != nullptr) {
      {
        std::lock_guard<std::mutex> lock(request->mutex);
        request->cancel->store(true);
      }
      delete request;
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore request shutdown failed.\n", stderr);
  }
}

int omni_qwen_transcribe_request(OmniQwenHandle *handle,
                                 OmniQwenRequest *request, const float *samples,
                                 size_t sample_count, const char *language,
                                 const char *context, int maximum_token_count,
                                 OmniQwenResult *result, char **error_message) {
  if (request == nullptr) {
    if (result != nullptr) {
      *result = {};
    } else {
    }
    SetError(error_message, "Invalid transcription request.");
    return 0;
  } else {
    return Transcribe(handle, request, samples, sample_count, language, context,
                      maximum_token_count, result, error_message);
  }
}

void omni_qwen_cancel(OmniQwenHandle *handle) {
  try {
    if (handle != nullptr) {
      handle->state->Stop(false);
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore cancellation failed.\n", stderr);
  }
}

void omni_qwen_destroy(OmniQwenHandle *handle) {
  try {
    if (handle != nullptr) {
      handle->state->Stop(true);
      delete handle;
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore shutdown failed.\n", stderr);
  }
}

void omni_qwen_result_free(OmniQwenResult *result) {
  if (result != nullptr) {
    std::free(result->text);
    std::free(result->language);
    *result = {};
  } else {
  }
}

void omni_string_free(char *string) { std::free(string); }
