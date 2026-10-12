// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "script.h"

namespace sortformer {
struct ProcessorConfig {
  int sampling_rate = 16000;
};
} // namespace sortformer
namespace nemotron {
struct NemotronOptions {
  std::optional<std::string> language;
  std::optional<int> chunk_frames;
};
class NemotronTranscriber {
public:
  explicit NemotronTranscriber(speaker_test::DecodeScript &script,
                               int sampling_rate = 16000,
                               double frame_seconds = 0.08)
      : script(script), front_end_{sampling_rate},
        frame_seconds_(frame_seconds) {}
  const sortformer::ProcessorConfig &front_end() const { return front_end_; }
  double frame_seconds() const { return frame_seconds_; }
  speaker_test::DecodeScript &script;

private:
  sortformer::ProcessorConfig front_end_;
  double frame_seconds_;
};
class NemotronStream {
public:
  NemotronStream(const NemotronTranscriber &transcriber,
                 const NemotronOptions &options);
  void Append(const std::vector<float> &samples,
              const std::atomic<bool> &cancel);
  void Finish(const std::vector<float> &samples,
              const std::atomic<bool> &cancel);
  std::string Text() const;
  qwen3_asr::TranscriptionResult Result() const;

private:
  speaker_test::DecodeScript &script_;
  int stream_id_;
  std::vector<float> ordered_samples_;
  qwen3_asr::TranscriptionResult result_;
};
} // namespace nemotron
