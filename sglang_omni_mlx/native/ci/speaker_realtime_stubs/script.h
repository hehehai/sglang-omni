// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <chrono>
#include <condition_variable>
#include <mutex>

#include "transcriber.h"

namespace speaker_test {
inline constexpr std::chrono::seconds TIMEOUT_SECONDS{5};
struct Gate {
  std::mutex mutex;
  std::condition_variable changed;
  bool entered = false;
  bool released = false;
  void block();
  void wait();
  void release();
};
struct DecodeStep {
  qwen3_asr::TranscriptionResult result;
  bool should_fail = false;
  bool is_blocked = false;
  bool ignores_cancellation = false;
};
class DecodeScript {
public:
  std::mutex mutex;
  std::vector<DecodeStep> steps;
  nlohmann::ordered_json calls = nlohmann::ordered_json::array();
  Gate model_gate;
  int next_stream_id = 0;
  size_t decode_count = 0;
  bool fails_construction = false;
  bool throws_bad_alloc = false;
  qwen3_asr::TranscriptionResult decode(nlohmann::ordered_json call,
                                        const std::atomic<bool> &cancel);
  void record(nlohmann::ordered_json call);
  nlohmann::ordered_json snapshot();
};
void require(bool condition, const std::string &message);
qwen3_asr::TranscriptionResult result(const std::string &text,
                                      double offset_seconds = 0.0);
} // namespace speaker_test
