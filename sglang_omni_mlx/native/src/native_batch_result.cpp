// SPDX-License-Identifier: Apache-2.0
#include "native_batch_worker.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <new>
#include <optional>
#include <string>

#include "transcriber.h"

namespace omni_native {
namespace {

bool AccountString(const std::string &text, size_t maximum_bytes,
                   size_t &total_bytes) {
  if (text.size() > maximum_bytes || text.find('\0') != std::string::npos ||
      text.size() + 1 > OMNI_BATCH_MAX_RESULT_STRING_BYTES - total_bytes) {
    return false;
  } else {
    total_bytes += text.size() + 1;
    return true;
  }
}

bool AccountString(const std::optional<std::string> &text, size_t maximum_bytes,
                   size_t &total_bytes) {
  return !text || AccountString(*text, maximum_bytes, total_bytes);
}

char *CopyBatchString(const std::string &text) {
  auto *copy = static_cast<char *>(std::malloc(text.size() + 1));
  if (copy == nullptr) {
    throw std::bad_alloc();
  } else {
    std::memcpy(copy, text.c_str(), text.size() + 1);
    return copy;
  }
}

char *CopyBatchString(const std::optional<std::string> &text) {
  return text ? CopyBatchString(*text) : nullptr;
}

} // namespace

OmniBatchStatus CopyBatchResult(const qwen3_asr::TranscriptionResult &source,
                                OmniBatchResult *result) {
  size_t total_bytes = 0;
  if (source.generated_token_count < 0 ||
      source.generated_token_count > OMNI_BATCH_MAX_TOKENS ||
      source.segments.size() > OMNI_BATCH_MAX_SEGMENTS ||
      !AccountString(source.text, OMNI_BATCH_MAX_TEXT_BYTES, total_bytes) ||
      !AccountString(source.language, OMNI_BATCH_MAX_LANGUAGE_BYTES,
                     total_bytes)) {
    return OMNI_BATCH_LIMIT;
  } else if (source.finish_reason != qwen3_asr::FinishReason::kStop &&
             source.finish_reason != qwen3_asr::FinishReason::kLength) {
    return OMNI_BATCH_FAILED;
  } else {
  }
  for (const auto &segment : source.segments) {
    if (!std::isfinite(segment.start_seconds) ||
        !std::isfinite(segment.end_seconds) || segment.start_seconds < 0 ||
        segment.end_seconds < segment.start_seconds) {
      return OMNI_BATCH_FAILED;
    } else if (!AccountString(segment.text, OMNI_BATCH_MAX_TEXT_BYTES,
                              total_bytes) ||
               !AccountString(segment.speaker, OMNI_BATCH_MAX_LANGUAGE_BYTES,
                              total_bytes) ||
               !AccountString(segment.language, OMNI_BATCH_MAX_LANGUAGE_BYTES,
                              total_bytes) ||
               !AccountString(segment.emotion, OMNI_BATCH_MAX_LANGUAGE_BYTES,
                              total_bytes) ||
               !AccountString(segment.event, OMNI_BATCH_MAX_LANGUAGE_BYTES,
                              total_bytes)) {
      return OMNI_BATCH_LIMIT;
    } else {
    }
  }
  OmniBatchResult snapshot{};
  try {
    snapshot.text = CopyBatchString(source.text);
    snapshot.language = CopyBatchString(source.language);
    snapshot.generated_token_count = source.generated_token_count;
    snapshot.finish_reason =
        source.finish_reason == qwen3_asr::FinishReason::kStop
            ? OMNI_BATCH_STOP
            : OMNI_BATCH_LENGTH;
    if (!source.segments.empty()) {
      snapshot.segments = static_cast<OmniBatchSegment *>(
          std::calloc(source.segments.size(), sizeof(OmniBatchSegment)));
      if (snapshot.segments == nullptr) {
        throw std::bad_alloc();
      } else {
        snapshot.segment_count = source.segments.size();
      }
    } else {
    }
    for (size_t i = 0; i < source.segments.size(); ++i) {
      const auto &segment = source.segments[i];
      auto &copy = snapshot.segments[i];
      copy.start_seconds = segment.start_seconds;
      copy.end_seconds = segment.end_seconds;
      copy.text = CopyBatchString(segment.text);
      copy.speaker = CopyBatchString(segment.speaker);
      copy.language = CopyBatchString(segment.language);
      copy.emotion = CopyBatchString(segment.emotion);
      copy.event = CopyBatchString(segment.event);
    }
    *result = snapshot;
    return OMNI_BATCH_OK;
  } catch (...) {
    omni_batch_result_free(&snapshot);
    throw;
  }
}

} // namespace omni_native

void omni_batch_result_free(OmniBatchResult *result) {
  if (result != nullptr) {
    for (size_t i = 0; i < result->segment_count; ++i) {
      std::free(result->segments[i].text);
      std::free(result->segments[i].speaker);
      std::free(result->segments[i].language);
      std::free(result->segments[i].emotion);
      std::free(result->segments[i].event);
    }
    std::free(result->segments);
    std::free(result->text);
    std::free(result->language);
    *result = {};
  } else {
  }
}
