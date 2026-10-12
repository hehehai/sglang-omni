// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "transcriber.h"
#include <array>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <thread>

namespace native_test {
inline constexpr auto TIMEOUT_SECONDS = std::chrono::seconds(5);
void require(bool condition, const std::string &message);
struct Gate {
  std::mutex mutex;
  std::condition_variable changed;
  bool entered = false;
  bool released = false;
  void block();
  void wait();
  void release();
};
struct ThreadObservation {
  const char *operation = nullptr;
  std::thread::id thread;
};
struct Script {
  std::mutex mutex;
  std::condition_variable changed;
  nlohmann::ordered_json calls = nlohmann::ordered_json::array();
  qwen3_asr::TranscriptionResult output;
  Gate load_gate;
  Gate decode_gate;
  Gate sync_gate;
  Gate callback_gate;
  Gate finish_gate;
  Gate sink_gate;
  std::atomic<bool> blocks_sink{false};
  std::atomic<bool> blocks_finish{false};
  std::atomic<bool> blocks_callback{false};
  std::atomic<int> finished_callbacks{0};
  std::atomic<int> sync_failures{0};
  std::atomic<int> fail_sync_call{0};
  std::atomic<int> cache_failures{0};
  std::atomic<int> sync_count{0};
  std::atomic<int> cache_count{0};
  std::atomic<int> live_models{0};
  std::atomic<int> live_streams{0};
  std::atomic<int> decode_count{0};
  std::atomic<bool> blocks_load{false};
  std::atomic<bool> blocks_decode{false};
  std::atomic<bool> blocks_sync{false};
  bool fails_load = false;
  bool fails_stream = false;
  bool fails_decode = false;
  bool fails_allocation = false;
  bool varies_text = false;
  double frame_seconds = 0.08;
  std::array<ThreadObservation, 8192> threads{};
  size_t thread_count = 0;
  void record_thread(const char *operation) noexcept;
  void record(nlohmann::ordered_json call);
  nlohmann::ordered_json snapshot();
  qwen3_asr::TranscriptionResult decode(nlohmann::ordered_json call,
                                        const std::atomic<bool> &cancel);
};
extern Script script;
void observe_thread(const char *operation) noexcept;
void callback_finished();
void finish_checkpoint();
void sink_checkpoint(bool is_segment);
void wait_callbacks(int expected_count);
struct CallbackObservation {
  ~CallbackObservation() { callback_finished(); }
};
qwen3_asr::TranscriptionResult result(const std::string &text);
std::vector<float> audio(size_t sample_count, size_t offset_samples = 0);
void check_threads();
} // namespace native_test
