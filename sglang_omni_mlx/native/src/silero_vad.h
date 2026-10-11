// SPDX-License-Identifier: Apache-2.0
// Silero VAD v6 on MLX, as Voxt's Swift MLXAudioVAD computes it.
#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "mlx/mlx.h"

#include "silero_timestamps.h"

namespace silero_vad {

inline constexpr int kContextSamples = 64;

// One stream's state between 512-sample chunks.
struct StreamState {
  // LSTM (hidden, cell); none before the first chunk, as in the Swift port.
  std::optional<mlx::core::array> hidden;
  std::optional<mlx::core::array> cell;
  // The previous chunk's last 64 samples (zeros at the start).
  std::vector<float> context = std::vector<float>(kContextSamples, 0.0f);
};

class SileroVAD {
public:
  // Loads config.json and model.safetensors (16 kHz branch only).
  explicit SileroVAD(const std::filesystem::path &model_directory);

  // Speech probability of one 512-sample chunk; advances state.
  float Feed(const float *chunk, StreamState &state) const;
  // Per-chunk probabilities of a whole buffer: zero-padded to whole chunks,
  // fed in order from a fresh state (Swift predictProba).
  std::vector<float>
  PredictProbabilities(const std::vector<float> &samples) const;

  const TimestampOptions &defaults() const { return defaults_; }

private:
  mlx::core::array Conv1d(const mlx::core::array &x, const std::string &name,
                          int stride, int padding) const;
  const mlx::core::array &Weight(const std::string &name) const;

  std::unordered_map<std::string, mlx::core::array> weights_;
  int filter_length_ = 256;
  int hop_length_ = 128;
  int pad_ = 64;
  int cutoff_ = 129;
  TimestampOptions defaults_;
};

} // namespace silero_vad
