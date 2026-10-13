// SPDX-License-Identifier: Apache-2.0
// Test-only model controls; Feed barriers deliberately cannot observe cancel.
#pragma once

#include "transcriber.h"

#include <array>

namespace omni_test {

struct SileroBackendState {
  std::mutex mutex;
  std::condition_variable changed;
  Failure load_failure = Failure::kNone;
  Failure feed_failure = Failure::kNone;
  bool block_load = false;
  bool release_load = false;
  bool block_feed = false;
  bool release_feed = false;
  int load_count = 0;
  int destruction_count = 0;
  int active_count = 0;
  int live_array_count = 0;
  int array_destruction_count = 0;
  int pending_constructor_work_count = 0;
  int pending_constructor_cache_count = 0;
  int synchronize_attempt_count = 0;
  int cache_clear_attempt_count = 0;
  bool fail_cache_clear = false;
  std::thread::id loading_thread;
  std::thread::id destruction_thread;
  std::vector<std::array<float, 512>> frames;
  std::deque<float> scripted_probabilities;
};

extern std::atomic<bool> fail_next_new;
__attribute__((visibility("default"))) SileroBackendState &SileroState();
void RunSileroOfflineCase(const std::string &test);
void RunSileroStreamCase(const std::string &test);
void RunSileroLifecycleCase(const std::string &test);
void RunSileroFailureCase(const std::string &test);

} // namespace omni_test
