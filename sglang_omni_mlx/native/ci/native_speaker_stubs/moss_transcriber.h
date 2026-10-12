// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "model_options.h"
#include "script.h"
namespace moss {
class MossTranscriber {
public:
  explicit MossTranscriber(const std::filesystem::path &model_directory);
  ~MossTranscriber();
  qwen3_asr::TranscriptionResult
  Transcribe(const std::vector<float> &samples, const MossOptions &options,
             const std::atomic<bool> &cancel) const;
};
void ValidatePrompt(const std::optional<std::string> &prompt);
} // namespace moss
