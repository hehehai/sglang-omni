// SPDX-License-Identifier: Apache-2.0
// Test-only backend/MLX stubs; no weights, tokenization, or GPU validation.
#pragma once

#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace mlx::core {
void synchronize();
void clear_cache();
} // namespace mlx::core

namespace qwen3_asr {

enum class AudioLayout { kReference, kVoxtSwift };
enum class FinishReason { kStop, kLength };

struct TranscriptionOptions {
  std::optional<std::string> language;
  std::optional<std::string> context;
  std::optional<int> max_new_tokens;
  bool stop_at_end_of_text = false;
  bool stop_on_token_loop = false;
  AudioLayout layout = AudioLayout::kReference;
  std::vector<int> prefix_token_ids;
  std::string prefix_text;
};

struct SpeakerSegment {
  double start_seconds = 0.0;
  double end_seconds = 0.0;
  std::string speaker;
  std::string text;
};

struct TranscriptionResult {
  std::string text;
  std::optional<std::string> language;
  int generated_token_count = 0;
  FinishReason finish_reason = FinishReason::kLength;
  std::vector<SpeakerSegment> segments;
};

class TranscriptionCancelled : public std::runtime_error {
public:
  TranscriptionCancelled() : std::runtime_error("transcription cancelled") {}
};

std::optional<std::string> NormalizeLanguage(const std::string &language);

class Qwen3ASRTranscriber {
public:
  explicit Qwen3ASRTranscriber(const std::filesystem::path &model_directory);
  ~Qwen3ASRTranscriber();
  TranscriptionResult Transcribe(const std::vector<float> &samples,
                                 const TranscriptionOptions &options,
                                 const std::atomic<bool> &cancel) const;

private:
  std::thread::id loading_thread_;
};

} // namespace qwen3_asr

namespace omni_test {

enum class Failure { kNone, kStandard, kNonstandard };

struct BackendState {
  std::mutex mutex;
  std::condition_variable changed;
  Failure load_failure = Failure::kNone;
  Failure infer_failure = Failure::kNone;
  bool block_inference = false;
  bool release_inference = false;
  bool cancellation_seen = false;
  bool return_language = true;
  bool return_empty_text = false;
  qwen3_asr::FinishReason finish_reason = qwen3_asr::FinishReason::kStop;
  int load_count = 0;
  int normalization_count = 0;
  int inference_count = 0;
  int active_count = 0;
  int destruction_count = 0;
  std::atomic<int> malloc_failure_after{-1};
  std::thread::id loading_thread;
  std::thread::id destruction_thread;
  std::vector<float> samples;
  qwen3_asr::TranscriptionOptions options;
};

__attribute__((visibility("default"))) BackendState &State();
void RunRequestCase(const std::string &test);

} // namespace omni_test
