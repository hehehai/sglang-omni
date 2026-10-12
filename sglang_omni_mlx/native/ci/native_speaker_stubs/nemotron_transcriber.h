// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "model_options.h"
#include "script.h"
namespace sortformer {
struct ProcessorConfig {
  int sampling_rate = 16000;
};
} // namespace sortformer
namespace nemotron {
class NemotronTranscriber {
public:
  explicit NemotronTranscriber(const std::filesystem::path &model_directory);
  ~NemotronTranscriber();
  const sortformer::ProcessorConfig &front_end() const {
    return front_end_config;
  }
  double frame_seconds() const { return native_test::script.frame_seconds; }

private:
  sortformer::ProcessorConfig front_end_config;
};
class NemotronStream {
public:
  NemotronStream(const NemotronTranscriber &transcriber,
                 const NemotronOptions &options);
  ~NemotronStream();
  void Append(const std::vector<float> &samples,
              const std::atomic<bool> &cancel);
  void Finish(const std::vector<float> &samples,
              const std::atomic<bool> &cancel);
  std::string Text() const;
  qwen3_asr::TranscriptionResult Result() const;

private:
  std::vector<float> ordered_samples;
  qwen3_asr::TranscriptionResult last_result;
};
} // namespace nemotron
