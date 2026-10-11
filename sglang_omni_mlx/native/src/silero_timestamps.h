// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <algorithm>
#include <vector>

namespace silero_vad {

inline constexpr int kSampleRate = 16000;
inline constexpr int kChunkSamples = 512;

struct Timestamp {
  long start = 0;
  long end = 0;
};

struct TimestampOptions {
  float threshold = 0.5f;
  int min_speech_ms = 250;
  int min_silence_ms = 100;
  int speech_pad_ms = 30;
};

// Speech segments from per-chunk probabilities, as Swift probsToTimestamps.
// clang-format off
inline std::vector<Timestamp>
ProbabilitiesToTimestamps(const std::vector<float> &probabilities,
                          long sample_count, const TimestampOptions &options) {
  const float min_speech_samples = static_cast<float>(kSampleRate) *
                                   static_cast<float>(options.min_speech_ms) /
                                   1000;
  const float min_silence_samples = static_cast<float>(kSampleRate) *
                                    static_cast<float>(options.min_silence_ms) /
                                    1000;
  const long pad_samples =
      static_cast<long>(static_cast<float>(kSampleRate) *
                        static_cast<float>(options.speech_pad_ms) / 1000);
  const float negative_threshold = std::max(options.threshold - 0.15f, 0.01f);
  std::vector<Timestamp> speeches;
  bool triggered = false;
  long current_start = 0;
  long temp_end = 0;
  for (size_t index = 0; index < probabilities.size(); ++index) {
    const float probability = probabilities[index];
    const long chunk_start = static_cast<long>(index) * kChunkSamples;
    if (probability >= options.threshold && !triggered) {
      triggered = true;
      current_start = chunk_start;
      temp_end = 0;
    } else if (triggered && probability >= options.threshold) {
      temp_end = 0;
    } else if (triggered && probability < negative_threshold) {
      if (temp_end == 0)
        temp_end = chunk_start;
      if (static_cast<float>(chunk_start - temp_end) >= min_silence_samples) {
        if (static_cast<float>(temp_end - current_start) >=
            min_speech_samples) {
          speeches.push_back({current_start, temp_end});
        } else {
        }
        triggered = false;
        temp_end = 0;
      } else {
      }
    } else {
    }
  }
  if (triggered) {
    const long end = std::min(
        sample_count, static_cast<long>(probabilities.size()) * kChunkSamples);
    if (static_cast<float>(end - current_start) >= min_speech_samples) {
      speeches.push_back({current_start, end});
    } else {
    }
  } else {
  }
  std::vector<Timestamp> padded;
  for (const Timestamp &speech : speeches) {
    const long start = std::max(0L, speech.start - pad_samples);
    const long end = std::min(sample_count, speech.end + pad_samples);
    if (!padded.empty() && start <= padded.back().end) {
      padded.back().end = std::max(padded.back().end, end);
    } else {
      padded.push_back({start, end});
    }
  }
  return padded;
}
// clang-format on

} // namespace silero_vad
