// SPDX-License-Identifier: Apache-2.0
// Test-only backend/MLX stubs; no weights, tokenization, or GPU validation.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
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
  std::optional<std::string> language;
  std::optional<std::string> emotion;
  std::optional<std::string> event;
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
bool IsUnicodeSpace(uint32_t code_point);
std::vector<uint32_t> CodePoints(const std::string &text);
std::string StripUnicodeWhitespace(const std::string &text);

class Qwen3ASRTranscriber {
public:
  explicit Qwen3ASRTranscriber(const std::filesystem::path &model_directory);
  ~Qwen3ASRTranscriber();
  TranscriptionResult Transcribe(const std::vector<float> &samples,
                                 const TranscriptionOptions &options,
                                 const std::atomic<bool> &cancel) const;
  std::pair<std::vector<int>, std::string>
  RetainedPrefix(const std::string &text, int rollback_token_count) const;

private:
  std::thread::id loading_thread_;
};

} // namespace qwen3_asr

namespace omni_test {

enum class Failure { kNone, kStandard, kNonstandard };
inline constexpr int SYNCHRONIZE_ALWAYS_FAIL = -2;

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
  bool ignores_cancellation = false;
  std::deque<std::string> scripted_texts;
  std::unordered_set<const qwen3_asr::Qwen3ASRTranscriber *> live_models;
  std::vector<size_t> inference_sample_counts;
  int prefix_count = 0;
  qwen3_asr::FinishReason finish_reason = qwen3_asr::FinishReason::kStop;
  int load_count = 0;
  int normalization_count = 0;
  int inference_count = 0;
  int active_count = 0;
  int destruction_count = 0;
  std::atomic<int> malloc_failure_after{-1};
  std::atomic<int> synchronize_failure_after{-1};
  std::thread::id loading_thread;
  std::thread::id destruction_thread;
  std::vector<float> samples;
  qwen3_asr::TranscriptionOptions options;
};

extern std::atomic<size_t> new_failure_byte_count;
__attribute__((visibility("default"))) BackendState &State();
void RunRequestCase(const std::string &test);
void RunRealtimeCase(const std::string &test);
void RunRealtimeLifecycleCase(const std::string &test);
void RunRealtimeQueueCase(const std::string &test);

} // namespace omni_test
