// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "script.h"

namespace moss {
struct MossOptions {
  std::optional<std::string> prompt;
  std::optional<int> max_new_tokens;
  bool stop_at_end_of_text = false;
  bool stop_on_token_loop = false;
  std::optional<double> window_offset_seconds;
};
class MossTranscriber {
public:
  explicit MossTranscriber(speaker_test::DecodeScript &script)
      : script_(script) {}
  qwen3_asr::TranscriptionResult
  Transcribe(const std::vector<float> &samples, const MossOptions &options,
             const std::atomic<bool> &cancel) const;

private:
  speaker_test::DecodeScript &script_;
};
void ValidatePrompt(const std::optional<std::string> &prompt);
} // namespace moss
