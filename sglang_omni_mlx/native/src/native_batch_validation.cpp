// SPDX-License-Identifier: Apache-2.0
#include "native_batch_worker.h"

#include <cmath>
#include <optional>
#include <string>

#include "moss_transcriber.h"

namespace omni_native {

bool BatchStringFits(const char *text, size_t maximum_bytes) noexcept {
  if (text == nullptr) {
    return true;
  } else {
    for (size_t i = 0; i <= maximum_bytes; ++i) {
      if (text[i] == '\0') {
        return true;
      } else {
      }
    }
    return false;
  }
}

OmniBatchStatus ValidateBatchInput(OmniBatchModelKind model_kind,
                                   const float *samples, size_t sample_count,
                                   const OmniBatchOptions *options) {
  if (samples == nullptr || sample_count == 0 ||
      sample_count > OMNI_BATCH_MAX_SAMPLES || options == nullptr ||
      options->model_kind != model_kind) {
    return OMNI_BATCH_INVALID;
  } else {
  }
  const char *language = nullptr;
  const auto &family = options->family;
  switch (model_kind) {
  case OMNI_BATCH_WHISPER:
    language = family.whisper.language;
    if (family.whisper.maximum_token_count < 0 ||
        family.whisper.maximum_token_count > OMNI_BATCH_MAX_TOKENS ||
        !std::isfinite(family.whisper.temperature) ||
        family.whisper.temperature < 0) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    break;
  case OMNI_BATCH_COHERE:
    language = family.cohere.language;
    if (family.cohere.use_punctuation < 0 ||
        family.cohere.use_punctuation > 1 ||
        family.cohere.maximum_token_count < 0 ||
        family.cohere.maximum_token_count > OMNI_BATCH_MAX_TOKENS ||
        !std::isfinite(family.cohere.temperature) ||
        family.cohere.temperature < 0 ||
        !std::isfinite(family.cohere.chunk_duration_seconds) ||
        family.cohere.chunk_duration_seconds < 1 ||
        family.cohere.chunk_duration_seconds > 1200 ||
        !std::isfinite(family.cohere.minimum_chunk_duration_seconds) ||
        family.cohere.minimum_chunk_duration_seconds < 0 ||
        family.cohere.minimum_chunk_duration_seconds > 30 ||
        family.cohere.minimum_chunk_duration_seconds >
            family.cohere.chunk_duration_seconds) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    break;
  case OMNI_BATCH_MOSS:
    if (!BatchStringFits(family.moss.prompt, OMNI_BATCH_MAX_PROMPT_BYTES) ||
        family.moss.maximum_token_count < -1 ||
        family.moss.maximum_token_count > OMNI_BATCH_MAX_TOKENS ||
        family.moss.stop_at_end_of_text < 0 ||
        family.moss.stop_at_end_of_text > 1 ||
        family.moss.stop_on_token_loop < 0 ||
        family.moss.stop_on_token_loop > 1) {
      return OMNI_BATCH_INVALID;
    } else {
      moss::ValidatePrompt(
          family.moss.prompt == nullptr
              ? std::nullopt
              : std::optional<std::string>(family.moss.prompt));
    }
    break;
  case OMNI_BATCH_NEMOTRON:
    language = family.nemotron.language;
    if (family.nemotron.chunk_frame_count < 0 ||
        family.nemotron.chunk_frame_count > 4096) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    break;
  case OMNI_BATCH_PARAKEET:
    if (!std::isfinite(family.parakeet.chunk_duration_seconds) ||
        family.parakeet.chunk_duration_seconds < 2 ||
        (family.parakeet.chunk_duration_seconds > 300 &&
         family.parakeet.chunk_duration_seconds < 1199) ||
        family.parakeet.chunk_duration_seconds > 1200) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    break;
  case OMNI_BATCH_SENSEVOICE:
    language = family.sensevoice.language;
    if (family.sensevoice.use_inverse_text_normalization < 0 ||
        family.sensevoice.use_inverse_text_normalization > 1) {
      return OMNI_BATCH_INVALID;
    } else {
    }
    break;
  default:
    return OMNI_BATCH_INVALID;
  }
  if (!BatchStringFits(language, OMNI_BATCH_MAX_LANGUAGE_BYTES)) {
    return OMNI_BATCH_INVALID;
  } else {
    for (size_t i = 0; i < sample_count; ++i) {
      if (!std::isfinite(samples[i])) {
        return OMNI_BATCH_INVALID;
      } else {
      }
    }
    return OMNI_BATCH_OK;
  }
}

} // namespace omni_native

OmniBatchStatus omni_batch_options_default(OmniBatchModelKind model_kind,
                                           OmniBatchOptions *options) {
  if (options == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *options = {};
    options->model_kind = model_kind;
    switch (model_kind) {
    case OMNI_BATCH_WHISPER:
    case OMNI_BATCH_NEMOTRON:
    case OMNI_BATCH_SENSEVOICE:
      return OMNI_BATCH_OK;
    case OMNI_BATCH_COHERE:
      options->family.cohere.use_punctuation = 1;
      options->family.cohere.chunk_duration_seconds = 1200;
      options->family.cohere.minimum_chunk_duration_seconds = 1;
      return OMNI_BATCH_OK;
    case OMNI_BATCH_MOSS:
      options->family.moss.maximum_token_count = -1;
      return OMNI_BATCH_OK;
    case OMNI_BATCH_PARAKEET:
      options->family.parakeet.chunk_duration_seconds = 1200;
      return OMNI_BATCH_OK;
    default:
      *options = {};
      return OMNI_BATCH_INVALID;
    }
  }
}
