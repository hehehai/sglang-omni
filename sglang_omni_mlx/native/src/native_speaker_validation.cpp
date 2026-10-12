// SPDX-License-Identifier: Apache-2.0
#include "native_speaker_state.h"

#include <cmath>
#include <new>
#include <stdexcept>

namespace omni_native {

OmniBatchStatus SpeakerExceptionStatus() noexcept {
  try {
    throw;
  } catch (const std::bad_alloc &) {
    return OMNI_BATCH_OUT_OF_MEMORY;
  } catch (...) {
    return OMNI_BATCH_FAILED;
  }
}

bool SpeakerUtf8(std::string_view text) noexcept {
  for (size_t i = 0; i < text.size();) {
    const auto first = static_cast<unsigned char>(text[i++]);
    uint32_t codepoint = 0;
    uint32_t minimum = 0;
    size_t continuation = 0;
    if (first == 0) {
      return false;
    } else if (first < 0x80) {
      continue;
    } else if (first >= 0xc2 && first <= 0xdf) {
      codepoint = first & 0x1f;
      minimum = 0x80;
      continuation = 1;
    } else if (first >= 0xe0 && first <= 0xef) {
      codepoint = first & 0x0f;
      minimum = 0x800;
      continuation = 2;
    } else if (first >= 0xf0 && first <= 0xf4) {
      codepoint = first & 0x07;
      minimum = 0x10000;
      continuation = 3;
    } else {
      return false;
    }
    if (continuation > text.size() - i) {
      return false;
    } else {
    }
    for (size_t j = 0; j < continuation; ++j) {
      const auto next = static_cast<unsigned char>(text[i++]);
      if ((next & 0xc0) != 0x80) {
        return false;
      } else {
        codepoint = (codepoint << 6) | (next & 0x3f);
      }
    }
    if (codepoint < minimum || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
      return false;
    } else {
    }
  }
  return true;
}

OmniBatchStatus SpeakerInputString(const char *text, size_t maximum_bytes,
                                   std::optional<std::string> &copy) {
  if (text == nullptr) {
    copy.reset();
    return OMNI_BATCH_OK;
  } else {
  }
  size_t length = 0;
  while (length <= maximum_bytes && text[length] != '\0') {
    ++length;
  }
  if (length > maximum_bytes) {
    return OMNI_BATCH_LIMIT;
  } else if (!SpeakerUtf8(std::string_view(text, length))) {
    return OMNI_BATCH_INVALID;
  } else {
    copy.emplace(text, length);
    return OMNI_BATCH_OK;
  }
}

OmniBatchStatus
SpeakerValidateSettings(OmniSpeakerModelKind kind,
                        const OmniSpeakerRealtimeSettings *settings,
                        SpeakerSettings &copy) {
  if (settings == nullptr || settings->model_kind != kind) {
    return OMNI_BATCH_INVALID;
  } else if (kind == OMNI_SPEAKER_MOSS) {
    const auto status =
        SpeakerInputString(settings->family.moss.prompt,
                           OMNI_SPEAKER_MAX_PROMPT_BYTES, copy.prompt);
    if (status != OMNI_BATCH_OK) {
      return status;
    } else {
      try {
        moss::ValidatePrompt(copy.prompt);
      } catch (const std::invalid_argument &) {
        return OMNI_BATCH_INVALID;
      }
      return OMNI_BATCH_OK;
    }
  } else if (kind == OMNI_SPEAKER_NEMOTRON) {
    const auto &family = settings->family.nemotron;
    if (family.has_chunk < 0 || family.has_chunk > 1 ||
        !std::isfinite(family.chunk_milliseconds) ||
        (family.has_chunk == 0 && family.chunk_milliseconds != 0) ||
        (family.has_chunk == 1 && family.chunk_milliseconds <= 0)) {
      return OMNI_BATCH_INVALID;
    } else if (family.chunk_milliseconds > 120000) {
      return OMNI_BATCH_LIMIT;
    } else {
      if (family.has_chunk != 0) {
        copy.chunk_milliseconds = family.chunk_milliseconds;
      } else {
      }
      return SpeakerInputString(family.language,
                                OMNI_SPEAKER_MAX_METADATA_BYTES, copy.language);
    }
  } else {
    return OMNI_BATCH_INVALID;
  }
}

namespace {

bool AccountString(const std::string &text, size_t maximum_bytes,
                   size_t &string_bytes) {
  if (text.size() > maximum_bytes || !SpeakerUtf8(text) ||
      text.size() + 1 > OMNI_SPEAKER_MAX_EVENT_STRING_BYTES - string_bytes) {
    return false;
  } else {
    string_bytes += text.size() + 1;
    return true;
  }
}

bool AccountString(const std::optional<std::string> &text, size_t maximum_bytes,
                   size_t &string_bytes) {
  return !text || AccountString(*text, maximum_bytes, string_bytes);
}

} // namespace

OmniBatchStatus SpeakerEventBytes(const qwen3_asr::SpeakerRealtimeEvent &event,
                                  size_t &string_bytes) {
  const std::string *text = nullptr;
  const std::vector<qwen3_asr::SpeakerSegment> *segments = nullptr;
  if (const auto *segment =
          std::get_if<qwen3_asr::SpeakerRealtimeSegment>(&event)) {
    if (segment->segment_id < 0 ||
        segment->is_final != segment->segments.has_value()) {
      return OMNI_BATCH_LIMIT;
    } else {
      text = &segment->text;
      segments = segment->segments ? &*segment->segments : nullptr;
    }
  } else if (const auto *completed =
                 std::get_if<qwen3_asr::SpeakerRealtimeCompleted>(&event)) {
    text = &completed->text;
    segments = &completed->segments;
  } else {
    return OMNI_BATCH_OK;
  }
  if (!AccountString(*text, OMNI_SPEAKER_MAX_TEXT_BYTES, string_bytes)) {
    return OMNI_BATCH_LIMIT;
  } else if (segments == nullptr) {
    return OMNI_BATCH_OK;
  } else if (segments->size() > OMNI_SPEAKER_MAX_SEGMENTS) {
    return OMNI_BATCH_LIMIT;
  } else {
  }
  for (const auto &segment : *segments) {
    if (!std::isfinite(segment.start_seconds) ||
        !std::isfinite(segment.end_seconds) || segment.start_seconds < 0 ||
        segment.end_seconds < segment.start_seconds ||
        !AccountString(segment.text, OMNI_SPEAKER_MAX_TEXT_BYTES,
                       string_bytes) ||
        !AccountString(segment.speaker, OMNI_SPEAKER_MAX_METADATA_BYTES,
                       string_bytes) ||
        !AccountString(segment.language, OMNI_SPEAKER_MAX_METADATA_BYTES,
                       string_bytes) ||
        !AccountString(segment.emotion, OMNI_SPEAKER_MAX_METADATA_BYTES,
                       string_bytes) ||
        !AccountString(segment.event, OMNI_SPEAKER_MAX_METADATA_BYTES,
                       string_bytes)) {
      return OMNI_BATCH_LIMIT;
    } else {
    }
  }
  return OMNI_BATCH_OK;
}

} // namespace omni_native

OmniBatchStatus
omni_speaker_settings_default(OmniSpeakerModelKind kind,
                              OmniSpeakerRealtimeSettings *settings) {
  if (settings == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *settings = {};
    if (kind != OMNI_SPEAKER_MOSS && kind != OMNI_SPEAKER_NEMOTRON) {
      return OMNI_BATCH_INVALID;
    } else {
      settings->model_kind = kind;
      return OMNI_BATCH_OK;
    }
  }
}
