// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstddef>

namespace mlx::core {
inline void synchronize() {}
inline void clear_cache() {}
} // namespace mlx::core

namespace qwen3_asr {
inline constexpr int kSampleRate = 16000;
enum class AudioLayout { kReference, kVoxtSwift };
bool PeakIsSilent(const float *samples, size_t sample_count,
                  float peak_threshold);
} // namespace qwen3_asr
