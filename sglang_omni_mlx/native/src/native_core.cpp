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

#include "transcriber.h"
#include "worker.h"

struct OmniQwenHandle {
  std::mutex mutex;
  bool is_cancelled = false;
  qwen3_asr::Qwen3ASRTranscriber *transcriber = nullptr;
  std::unique_ptr<qwen3_asr::TranscriptionWorker> worker;
};

namespace {

constexpr size_t MAXIMUM_SAMPLE_COUNT = 16000 * 30;
constexpr int MAXIMUM_TOKEN_COUNT = 4096;

char *CopyString(const std::string &string) {
  char *copy = static_cast<char *>(std::malloc(string.size() + 1));
  if (copy == nullptr) {
    throw std::bad_alloc();
  } else {
    std::memcpy(copy, string.c_str(), string.size() + 1);
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

} // namespace

unsigned int omni_core_abi_version(void) { return 1; }

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
      // Note (Codex): Run retains load until worker exit; only that callback
      // owns the model, so its last release stays on the loading thread.
      handle->worker = std::make_unique<qwen3_asr::TranscriptionWorker>(
          [pointer = handle.get(),
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

int omni_qwen_transcribe(OmniQwenHandle *handle, const float *samples,
                         size_t sample_count, const char *language,
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
    if (handle == nullptr || result == nullptr || samples == nullptr ||
        sample_count == 0 || sample_count > MAXIMUM_SAMPLE_COUNT ||
        maximum_token_count < 1 || maximum_token_count > MAXIMUM_TOKEN_COUNT) {
      SetError(error_message, "Invalid transcription input.");
      return 0;
    } else {
      std::future<qwen3_asr::TranscriptionResult> future;
      {
        std::lock_guard<std::mutex> lock(handle->mutex);
        if (handle->is_cancelled) {
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
        // Note (Codex): after Submit, this call owns only its future;
        // destroy may join the worker without invalidating any caller-side
        // handle use.
        handle->worker->Submit(
            [transcriber = handle->transcriber,
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
            qwen3_asr::NewCancelFlag(),
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
      const auto transcription = future.get();
      std::unique_ptr<char, decltype(&std::free)> text(
          CopyString(transcription.text), &std::free);
      std::unique_ptr<char, decltype(&std::free)> detected_language(
          transcription.language ? CopyString(*transcription.language)
                                 : nullptr,
          &std::free);
      *result = {text.release(), detected_language.release(),
                 transcription.generated_token_count,
                 transcription.finish_reason == qwen3_asr::FinishReason::kLength
                     ? 1
                     : 0};
      return 1;
    }
  } catch (const qwen3_asr::TranscriptionCancelled &) {
    SetError(error_message, "Transcription cancelled.");
    return 0;
  } catch (...) {
    SetError(error_message, "Transcription failed.");
    return 0;
  }
}

void omni_qwen_cancel(OmniQwenHandle *handle) {
  try {
    if (handle != nullptr) {
      std::lock_guard<std::mutex> lock(handle->mutex);
      handle->is_cancelled = true;
      handle->worker->CancelAll();
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore cancellation failed.\n", stderr);
  }
}

void omni_qwen_destroy(OmniQwenHandle *handle) {
  try {
    if (handle != nullptr) {
      {
        std::lock_guard<std::mutex> lock(handle->mutex);
        handle->worker.reset();
      }
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
