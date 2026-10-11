// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "sortformer.h"

#include <fstream>
#include <nlohmann/json.hpp>

namespace omni_test {

inline nlohmann::json ConfigJson(const sortformer::Config &config) {
  const auto &f = config.fc_encoder;
  const auto &t = config.tf_encoder;
  const auto &m = config.modules;
  const auto &p = config.processor;
  return {{"num_speakers", config.num_speakers},
          {"fc_encoder_config",
           {{"hidden_size", f.hidden_size},
            {"num_hidden_layers", f.num_hidden_layers},
            {"num_attention_heads", f.num_attention_heads},
            {"intermediate_size", f.intermediate_size},
            {"num_mel_bins", f.num_mel_bins},
            {"conv_kernel_size", f.conv_kernel_size},
            {"subsampling_factor", f.subsampling_factor},
            {"subsampling_conv_channels", f.subsampling_conv_channels},
            {"subsampling_conv_kernel_size", f.subsampling_conv_kernel_size},
            {"subsampling_conv_stride", f.subsampling_conv_stride},
            {"attention_bias", f.attention_bias},
            {"scale_input", f.scale_input}}},
          {"tf_encoder_config",
           {{"d_model", t.d_model},
            {"encoder_layers", t.encoder_layers},
            {"encoder_attention_heads", t.encoder_attention_heads},
            {"encoder_ffn_dim", t.encoder_ffn_dim},
            {"layer_norm_eps", t.layer_norm_eps},
            {"max_source_positions", t.max_source_positions},
            {"k_proj_bias", t.k_proj_bias}}},
          {"modules_config",
           {{"num_speakers", m.num_speakers},
            {"fc_d_model", m.fc_d_model},
            {"tf_d_model", m.tf_d_model},
            {"subsampling_factor", m.subsampling_factor},
            {"chunk_len", m.chunk_len},
            {"fifo_len", m.fifo_len},
            {"spkcache_len", m.spkcache_len},
            {"spkcache_update_period", m.spkcache_update_period},
            {"chunk_left_context", m.chunk_left_context},
            {"chunk_right_context", m.chunk_right_context},
            {"spkcache_sil_frames_per_spk", m.spkcache_sil_frames_per_spk},
            {"pred_score_threshold", m.pred_score_threshold},
            {"max_index", m.max_index},
            {"scores_boost_latest", m.scores_boost_latest},
            {"sil_threshold", m.sil_threshold},
            {"strong_boost_rate", m.strong_boost_rate},
            {"weak_boost_rate", m.weak_boost_rate},
            {"min_pos_scores_rate", m.min_pos_scores_rate},
            {"use_aosc", m.use_aosc}}},
          {"processor_config",
           {{"feature_size", p.feature_size},
            {"sampling_rate", p.sampling_rate},
            {"hop_length", p.hop_length},
            {"n_fft", p.fft_size},
            {"win_length", p.window_length},
            {"preemphasis", p.preemphasis}}}};
}

inline void WriteSortformerConfig(const sortformer::Config &config) {
  std::ofstream("config.json") << ConfigJson(config).dump();
}

} // namespace omni_test
