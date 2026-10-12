// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>

namespace batch_test {

enum class OutputMode {
  Normal,
  Empty,
  Throw,
  OutOfMemory,
  TextLimit,
  LanguageLimit,
  SegmentLimit,
  TokenLimit,
  NegativeTokens,
  InvalidTime,
  ReversedTime,
  MetadataLimit,
  AggregateLimit,
  EmbeddedNull,
  InvalidFinish,
  Boundary
};

extern std::atomic<int> load_count;
extern std::atomic<int> destroy_count;
extern std::atomic<int> transcribe_count;
extern std::atomic<bool> should_fail_load;
extern std::atomic<bool> should_fail_load_allocation;
extern std::atomic<OutputMode> output_mode;
extern std::mutex block_mutex;
extern std::condition_variable block_condition;
extern bool should_block;
extern bool has_entered;
extern bool can_return;
extern std::thread::id loading_thread;
extern std::thread::id execution_thread;
extern std::thread::id destruction_thread;
extern int last_model_kind;
extern std::string last_language;
extern bool has_language;
extern std::string last_prompt;
extern bool has_prompt;
extern int last_maximum_token_count;
extern bool has_maximum_token_count;
extern float last_temperature;
extern bool last_punctuation;
extern bool last_end_stop;
extern bool last_loop_stop;
extern double last_chunk_duration_seconds;
extern float last_minimum_chunk_duration_seconds;
extern int last_chunk_frame_count;
extern bool has_chunk_frame_count;
extern bool last_inverse_text_normalization;
extern size_t last_sample_count;
extern float last_sample;

class Model {
public:
  explicit Model(const std::filesystem::path &model_directory);
  ~Model();
  std::thread::id owner_thread;
};

void BlockNextTranscription();
void WaitForTranscription();
void ReleaseTranscription();

} // namespace batch_test
