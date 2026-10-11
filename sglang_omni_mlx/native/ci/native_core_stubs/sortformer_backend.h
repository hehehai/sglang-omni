// SPDX-License-Identifier: Apache-2.0
// Explicit model controls: no inference or cache-compression algorithm
// stand-in.
#pragma once

#include "sortformer.h"
#include "transcriber.h"

namespace omni_test {

enum class SortformerOutputFault {
  None,
  NegativeFrames,
  HugeFrames,
  WrongFrames,
  WrongSpeakers,
  WrongCount,
  NanProbability,
  NegativeProbability,
  LargeProbability,
  NanStart,
  InfiniteEnd,
  NegativeStart,
  ReversedTime,
  LateEnd,
  Unsorted,
  WrongSpeaker,
  TooManySegments,
  WrongCounter,
  LargeCache,
  LargeFifo
};

struct SortformerBackendState {
  std::mutex mutex;
  std::condition_variable changed;
  sortformer::Config config;
  float frame_duration_seconds = 0.08f;
  Failure load_failure = Failure::kNone;
  Failure init_failure = Failure::kNone;
  Failure feed_failure = Failure::kNone;
  SortformerOutputFault output_fault = SortformerOutputFault::None;
  bool block_feed = false;
  bool release_feed = false;
  bool block_init = false;
  bool release_init = false;
  int load_count = 0;
  int destruction_count = 0;
  int feed_count = 0;
  int init_count = 0;
  int active_count = 0;
  int live_array_count = 0;
  int initial_frame_count = 0;
  size_t last_sample_count = 0;
  sortformer::FeedOptions last_options;
  std::thread::id loading_thread;
  std::thread::id destruction_thread;
};

__attribute__((visibility("default"))) SortformerBackendState &
SortformerState();
void RunSortformerCase(const std::string &test);
void RunSortformerFailureCase(const std::string &test);
void RunSortformerLifecycleCase(const std::string &test);

} // namespace omni_test
