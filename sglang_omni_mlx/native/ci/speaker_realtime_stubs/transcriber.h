// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <atomic>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "audio.h"
#include "nlohmann/json.hpp"

namespace qwen3_asr {
enum class FinishReason { kStop, kLength };
struct TranscriptionOptions {
  std::optional<std::string> language;
  std::optional<std::string> context;
  std::optional<int> max_new_tokens;
  bool stop_at_end_of_text = false;
  bool stop_on_token_loop = false;
  AudioLayout layout = AudioLayout::kReference;
  std::vector<int> prefix_token_ids;
  std::string prefix_text;
};
struct SpeakerSegment {
  double start_seconds = 0.0;
  double end_seconds = 0.0;
  std::string speaker;
  std::string text;
  std::optional<std::string> language;
  std::optional<std::string> emotion;
  std::optional<std::string> event;
};
struct TranscriptionResult {
  std::string text;
  std::optional<std::string> language;
  int generated_token_count = 0;
  FinishReason finish_reason = FinishReason::kLength;
  std::vector<SpeakerSegment> segments;
};
class TranscriptionCancelled : public std::runtime_error {
public:
  TranscriptionCancelled() : std::runtime_error("transcription cancelled") {}
};
nlohmann::ordered_json
SpeakerSegmentsJson(const std::vector<SpeakerSegment> &segments);
bool IsUnicodeSpace(uint32_t code_point);
std::vector<uint32_t> CodePoints(const std::string &text);
std::string StripUnicodeWhitespace(const std::string &text);
std::optional<std::string> NormalizeLanguage(const std::string &language);
class Qwen3ASRTranscriber {
public:
  std::pair<std::vector<int>, std::string>
  RetainedPrefix(const std::string &text, int rollback_token_count) const;
  TranscriptionResult Transcribe(const std::vector<float> &samples,
                                 const TranscriptionOptions &options,
                                 const std::atomic<bool> &cancel) const;
};
} // namespace qwen3_asr
