// SPDX-License-Identifier: Apache-2.0
#include "native_sortformer_validation.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace omni_native {

namespace {

bool InRange(float value, float minimum, float maximum) {
  return std::isfinite(value) && value >= minimum && value <= maximum;
}

} // namespace

size_t ValidateSortformerConfig(const sortformer::Config &config) {
  const auto &processor = config.processor;
  const auto &conformer = config.fc_encoder;
  const auto &transformer = config.tf_encoder;
  const auto &modules = config.modules;
  // Note (OpenAI): only the initial checkpoint architecture is advertised;
  // reject dimensions before FeatureExtractor/weight allocation or int math.
  if (config.num_speakers != OMNI_SORTFORMER_MAX_SPEAKERS ||
      modules.num_speakers != OMNI_SORTFORMER_MAX_SPEAKERS ||
      !modules.use_aosc ||
      processor.sampling_rate != OMNI_SORTFORMER_SAMPLE_RATE ||
      processor.hop_length != 160 || processor.feature_size != 80 ||
      processor.fft_size != 512 || processor.window_length != 400 ||
      !InRange(processor.preemphasis, 0, 1) ||
      conformer.subsampling_factor != 8 || modules.subsampling_factor != 8 ||
      conformer.hidden_size != 512 || conformer.num_hidden_layers != 18 ||
      conformer.num_attention_heads != 8 ||
      conformer.intermediate_size != 2048 || conformer.num_mel_bins != 80 ||
      conformer.conv_kernel_size != 9 ||
      conformer.subsampling_conv_channels != 256 ||
      conformer.subsampling_conv_kernel_size != 3 ||
      conformer.subsampling_conv_stride != 2 || transformer.d_model != 192 ||
      transformer.encoder_layers != 18 ||
      transformer.encoder_attention_heads != 8 ||
      transformer.encoder_ffn_dim != 768 ||
      !InRange(transformer.layer_norm_eps, 1e-12f, 1.0f) ||
      modules.fc_d_model != conformer.hidden_size ||
      modules.tf_d_model != transformer.d_model ||
      transformer.max_source_positions < 1 ||
      transformer.max_source_positions > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      modules.chunk_len < 1 ||
      modules.chunk_len > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      modules.fifo_len < 0 ||
      modules.fifo_len > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      modules.spkcache_len < 1 ||
      modules.spkcache_len > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      modules.spkcache_update_period < 1 ||
      modules.spkcache_update_period > modules.spkcache_len ||
      modules.chunk_left_context < 0 ||
      modules.chunk_left_context > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      modules.chunk_right_context < 0 ||
      modules.chunk_right_context > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      modules.spkcache_sil_frames_per_spk < 0 ||
      modules.spkcache_sil_frames_per_spk >
          modules.spkcache_len / modules.num_speakers ||
      !InRange(modules.pred_score_threshold, 1e-12f, 1.0f) ||
      !InRange(modules.scores_boost_latest, 0, 1) ||
      !InRange(modules.sil_threshold, 0, 4) ||
      !InRange(modules.strong_boost_rate, 0, 1) ||
      !InRange(modules.weak_boost_rate, 0, 1) ||
      !InRange(modules.min_pos_scores_rate, 0, 1)) {
    throw std::invalid_argument("Unsupported Sortformer configuration.");
  } else {
  }
  const int64_t default_frames = int64_t{modules.spkcache_len} +
                                 modules.fifo_len + modules.chunk_left_context +
                                 modules.spkcache_update_period;
  if (default_frames > transformer.max_source_positions ||
      modules.max_index <=
          (int64_t{modules.spkcache_len} + modules.spkcache_update_period +
           modules.spkcache_sil_frames_per_spk) *
              modules.num_speakers) {
    throw std::invalid_argument("Invalid Sortformer compression bounds.");
  } else {
  }
  const uint64_t samples_per_frame =
      static_cast<uint64_t>(processor.hop_length) *
      static_cast<uint64_t>(conformer.subsampling_factor);
  const uint64_t update_sample_count =
      static_cast<uint64_t>(modules.spkcache_update_period) * samples_per_frame;
  return static_cast<size_t>(std::min(
      uint64_t{OMNI_SORTFORMER_MAX_CHUNK_SAMPLES}, update_sample_count - 1));
}

void ValidateSortformerSettings(const OmniSortformerSettings &settings,
                                const sortformer::Config &config) {
  if (!InRange(settings.threshold, 0, 1) ||
      !InRange(settings.minimum_duration_seconds, 0, 3600) ||
      !InRange(settings.merge_gap_seconds, 0, 3600) ||
      settings.speaker_cache_max_frames < 1 ||
      settings.speaker_cache_max_frames > OMNI_SORTFORMER_MAX_STATE_FRAMES ||
      settings.fifo_max_frames < 0 ||
      settings.fifo_max_frames > OMNI_SORTFORMER_MAX_STATE_FRAMES) {
    throw std::invalid_argument("Invalid Sortformer settings.");
  } else {
  }
  const auto &modules = config.modules;
  const int64_t cache_frames =
      std::max(settings.speaker_cache_max_frames, modules.spkcache_len);
  const int64_t encoder_frames = cache_frames + settings.fifo_max_frames +
                                 modules.chunk_left_context +
                                 modules.spkcache_update_period;
  // Note (OpenAI): TopIndices must fill spkcache_len even on the first
  // compression; its flattened candidate count includes silence pad frames.
  const int64_t first_compression_candidates =
      (int64_t{settings.speaker_cache_max_frames} + 1 +
       modules.spkcache_sil_frames_per_spk) *
      modules.num_speakers;
  if (encoder_frames > config.tf_encoder.max_source_positions ||
      first_compression_candidates < modules.spkcache_len ||
      (cache_frames + modules.spkcache_update_period +
       modules.spkcache_sil_frames_per_spk) *
              modules.num_speakers >=
          modules.max_index) {
    throw std::invalid_argument(
        "Sortformer settings exceed model state bounds.");
  } else {
  }
}

void ValidateSortformerResult(const sortformer::FeedResult &result,
                              int expected_frame_count,
                              uint64_t previous_frame_count,
                              float frame_duration_seconds) {
  if (result.frame_count < 1 ||
      result.frame_count > OMNI_SORTFORMER_MAX_CHUNK_FRAMES ||
      result.frame_count != expected_frame_count ||
      result.speaker_count != OMNI_SORTFORMER_MAX_SPEAKERS ||
      result.probabilities.size() !=
          static_cast<size_t>(result.frame_count) *
              static_cast<size_t>(result.speaker_count) ||
      result.segments.size() > OMNI_SORTFORMER_MAX_SEGMENTS ||
      !std::all_of(
          result.probabilities.begin(), result.probabilities.end(),
          [](float probability) { return InRange(probability, 0, 1); })) {
    throw std::runtime_error("Invalid Sortformer probabilities.");
  } else {
  }
  // Note (OpenAI): use the model's float operation order before widening;
  // double recomputation rejects legitimate rounded absolute segment times.
  const float start_seconds =
      static_cast<float>(previous_frame_count) * frame_duration_seconds;
  const float end_seconds =
      static_cast<float>(result.frame_count) * frame_duration_seconds +
      start_seconds;
  float previous_start_seconds = start_seconds;
  for (const auto &segment : result.segments) {
    if (!InRange(segment.start, previous_start_seconds, end_seconds) ||
        !InRange(segment.end, segment.start, end_seconds) ||
        segment.speaker < 0 || segment.speaker >= result.speaker_count) {
      throw std::runtime_error("Invalid Sortformer segments.");
    } else {
      previous_start_seconds = segment.start;
    }
  }
}

} // namespace omni_native
