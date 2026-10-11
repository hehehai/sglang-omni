// SPDX-License-Identifier: Apache-2.0
#include "transcriber.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <map>

namespace qwen3_asr {
namespace {
constexpr std::chrono::seconds BARRIER_TIMEOUT_SECONDS{5};
}

namespace realtime_test {
void DecodeScript::wait_for_calls(size_t call_count) {
  std::unique_lock<std::mutex> lock(mutex);
  if (!changed.wait_for(lock, BARRIER_TIMEOUT_SECONDS,
                        [&] { return calls.size() >= call_count; })) {
    throw std::runtime_error("Timed out waiting for the model barrier");
  } else {
  }
}

void DecodeScript::release() {
  {
    std::lock_guard<std::mutex> lock(mutex);
    is_released = true;
  }
  changed.notify_all();
}
} // namespace realtime_test

TranscriptionResult
Qwen3ASRTranscriber::Transcribe(const std::vector<float> &samples,
                                const TranscriptionOptions &options,
                                const std::atomic<bool> &cancel) const {
  std::unique_lock<std::mutex> lock(script_.mutex);
  const size_t call_index = script_.calls.size();
  script_.calls.push_back({
      {"samples", samples},
      {"language", options.language ? nlohmann::json(*options.language)
                                    : nlohmann::json(nullptr)},
      {"context", options.context ? nlohmann::json(*options.context)
                                  : nlohmann::json(nullptr)},
      {"max_new_tokens", options.max_new_tokens
                             ? nlohmann::json(*options.max_new_tokens)
                             : nlohmann::json(nullptr)},
      {"stop_at_end_of_text", options.stop_at_end_of_text},
      {"stop_on_token_loop", options.stop_on_token_loop},
      {"layout",
       options.layout == AudioLayout::kReference ? "reference" : "swift"},
      {"prefix_token_ids", options.prefix_token_ids},
      {"prefix_text", options.prefix_text},
      {"cancelled", false},
  });
  script_.changed.notify_all();
  const realtime_test::DecodeStep step = script_.steps.at(call_index);
  if (step.is_blocked &&
      !script_.changed.wait_for(lock, BARRIER_TIMEOUT_SECONDS,
                                [&] { return script_.is_released; })) {
    throw std::runtime_error("Timed out waiting to release the model barrier");
  } else {
  }
  script_.calls[call_index]["cancelled"] = cancel.load();
  if (cancel.load() && !step.ignores_cancellation) {
    throw TranscriptionCancelled();
  } else if (step.should_fail) {
    throw std::runtime_error(
        "PRIVATE model failure containing audio/transcript");
  } else {
    return {step.text, step.language, 7, FinishReason::kStop, {}};
  }
}

std::pair<std::vector<int>, std::string>
Qwen3ASRTranscriber::RetainedPrefix(const std::string &text,
                                    int rollback_token_count) const {
  // Note (OpenAI): ASCII byte tokens stand in for Qwen tokenization.
  const size_t retained_bytes =
      text.size() > static_cast<size_t>(rollback_token_count)
          ? text.size() - rollback_token_count
          : 0;
  const std::string prefix_text = text.substr(0, retained_bytes);
  std::vector<int> token_ids(prefix_text.begin(), prefix_text.end());
  std::lock_guard<std::mutex> lock(script_.mutex);
  script_.prefixes.push_back({{"text", text},
                              {"rollback_token_count", rollback_token_count},
                              {"token_ids", token_ids},
                              {"prefix_text", prefix_text}});
  return {token_ids, prefix_text};
}

bool PeakIsSilent(const float *samples, size_t sample_count,
                  float peak_threshold) {
  for (size_t i = 0; i < sample_count; ++i) {
    if (std::fabs(samples[i]) >= peak_threshold) {
      return false;
    } else {
    }
  }
  return true;
}

bool IsUnicodeSpace(uint32_t code_point) {
  return code_point == ' ' || (code_point >= 0x09 && code_point <= 0x0D) ||
         (code_point >= 0x1C && code_point <= 0x1F) || code_point == 0x85 ||
         code_point == 0xA0 || code_point == 0x1680 ||
         (code_point >= 0x2000 && code_point <= 0x200A) ||
         code_point == 0x2028 || code_point == 0x2029 || code_point == 0x202F ||
         code_point == 0x205F || code_point == 0x3000;
}

std::vector<uint32_t> CodePoints(const std::string &text) {
  std::vector<uint32_t> code_points;
  for (size_t i = 0; i < text.size();) {
    const uint8_t lead = static_cast<uint8_t>(text[i]);
    const size_t byte_count = lead >= 0xF0   ? 4
                              : lead >= 0xE0 ? 3
                              : lead >= 0xC0 ? 2
                                             : 1;
    uint32_t code_point =
        lead & (byte_count == 1 ? 0x7F : (0x7F >> byte_count));
    for (size_t j = 1; j < byte_count; ++j) {
      code_point =
          (code_point << 6) | (static_cast<uint8_t>(text.at(i + j)) & 0x3F);
    }
    code_points.push_back(code_point);
    i += byte_count;
  }
  return code_points;
}

std::string StripUnicodeWhitespace(const std::string &text) {
  const std::vector<uint32_t> code_points = CodePoints(text);
  size_t begin_byte = text.size();
  size_t end_byte = 0;
  size_t byte_offset = 0;
  for (const uint32_t code_point : code_points) {
    const size_t byte_count = code_point > 0xFFFF  ? 4
                              : code_point > 0x7FF ? 3
                              : code_point > 0x7F  ? 2
                                                   : 1;
    if (!IsUnicodeSpace(code_point)) {
      begin_byte = std::min(begin_byte, byte_offset);
      end_byte = byte_offset + byte_count;
    } else {
    }
    byte_offset += byte_count;
  }
  return begin_byte < end_byte ? text.substr(begin_byte, end_byte - begin_byte)
                               : "";
}

std::optional<std::string> NormalizeLanguage(const std::string &language) {
  const std::string stripped = StripUnicodeWhitespace(language);
  std::string lowercase = stripped;
  std::transform(
      lowercase.begin(), lowercase.end(), lowercase.begin(),
      [](unsigned char character) { return std::tolower(character); });
  // Note (OpenAI): the model language table is deliberately limited to this
  // suite.
  const std::map<std::string, std::string> languages = {
      {"en", "English"},      {"english", "English"}, {"zh", "Chinese"},
      {"chinese", "Chinese"}, {"de", "German"},       {"german", "German"}};
  if (lowercase.empty()) {
    return std::nullopt;
  } else if (lowercase == "cn" || lowercase.rfind("zh-", 0) == 0 ||
             lowercase.rfind("zh_", 0) == 0) {
    return "Chinese";
  } else if (languages.count(lowercase) != 0) {
    return languages.at(lowercase);
  } else {
    return stripped;
  }
}
} // namespace qwen3_asr
