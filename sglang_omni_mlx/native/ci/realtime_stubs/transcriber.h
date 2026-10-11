// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
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

bool IsUnicodeSpace(uint32_t code_point);
std::vector<uint32_t> CodePoints(const std::string &text);
std::string StripUnicodeWhitespace(const std::string &text);
std::optional<std::string> NormalizeLanguage(const std::string &language);

namespace realtime_test {
struct DecodeStep {
  std::string text;
  std::optional<std::string> language = std::nullopt;
  bool should_fail = false;
  bool is_blocked = false;
  bool ignores_cancellation = false;
};
struct DecodeScript {
  std::mutex mutex;
  std::condition_variable changed;
  std::vector<DecodeStep> steps;
  nlohmann::json calls = nlohmann::json::array();
  nlohmann::json prefixes = nlohmann::json::array();
  bool is_released = false;

  void wait_for_calls(size_t call_count);
  void release();
};
} // namespace realtime_test

class Qwen3ASRTranscriber {
public:
  explicit Qwen3ASRTranscriber(realtime_test::DecodeScript &script)
      : script_(script) {}
  std::pair<std::vector<int>, std::string>
  RetainedPrefix(const std::string &text, int rollback_token_count) const;
  TranscriptionResult Transcribe(const std::vector<float> &samples,
                                 const TranscriptionOptions &options,
                                 const std::atomic<bool> &cancel) const;

private:
  realtime_test::DecodeScript &script_;
};
} // namespace qwen3_asr
