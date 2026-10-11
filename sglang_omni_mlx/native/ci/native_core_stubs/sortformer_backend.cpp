// SPDX-License-Identifier: Apache-2.0
// Explicit MLX/model stand-ins; production model headers and segment algorithm.
#include "sortformer_backend.h"

#include <cassert>
#include <chrono>
#include <limits>
#include <utility>

namespace omni_test {

SortformerBackendState &SortformerState() {
  static SortformerBackendState state;
  return state;
}

struct SortformerArrayLifetime {
  bool is_model;
  std::thread::id owner_thread = std::this_thread::get_id();

  explicit SortformerArrayLifetime(bool is_model) : is_model(is_model) {
    auto &backend = SortformerState();
    std::lock_guard<std::mutex> lock(backend.mutex);
    assert(owner_thread == backend.loading_thread);
    ++backend.live_array_count;
  }

  ~SortformerArrayLifetime() {
    auto &backend = SortformerState();
    std::lock_guard<std::mutex> lock(backend.mutex);
    assert(owner_thread == std::this_thread::get_id());
    assert(backend.active_count == 0);
    --backend.live_array_count;
    if (is_model) {
      ++backend.destruction_count;
      backend.destruction_thread = owner_thread;
    } else {
    }
    backend.changed.notify_all();
  }
};

} // namespace omni_test

namespace mlx::core {
array::array(bool is_model, std::vector<int> dimensions)
    : sortformer_lifetime(
          std::make_shared<omni_test::SortformerArrayLifetime>(is_model)),
      dimensions(std::move(dimensions)) {}
} // namespace mlx::core

namespace sortformer {

FeatureExtractor::FeatureExtractor(const ProcessorConfig &config)
    : config_(config) {
  omni_test::SortformerState().loading_thread = std::this_thread::get_id();
  mel_filters_array_ = mlx::core::array(false, {257, 80});
  window_array_ = mlx::core::array(false, {512});
}

SortformerModel::SortformerModel(const std::filesystem::path &model_directory,
                                 const Config &config)
    : config_(config), features_(config.processor) {
  auto &backend = omni_test::SortformerState();
  assert(std::filesystem::is_directory(model_directory));
  ++backend.load_count;
  weights_.insert_or_assign("test_model_lifetime", mlx::core::array(true, {1}));
  if (backend.load_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE /private/model/path");
  } else if (backend.load_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
  }
}

float SortformerModel::frame_duration() const {
  return omni_test::SortformerState().frame_duration_seconds;
}

StreamingState SortformerModel::InitStreamingState() const {
  auto &backend = omni_test::SortformerState();
  std::unique_lock<std::mutex> lock(backend.mutex);
  assert(backend.loading_thread == std::this_thread::get_id());
  ++backend.init_count;
  backend.changed.notify_all();
  assert(backend.changed.wait_for(lock, std::chrono::seconds(10), [&] {
    return !backend.block_init || backend.release_init;
  }));
  if (backend.init_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE state initialization");
  } else if (backend.init_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
  }
  lock.unlock();
  return {
      mlx::core::array(false, {1, 0, 512}), mlx::core::array(false, {1, 0, 4}),
      mlx::core::array(false, {1, 0, 512}), mlx::core::array(false, {1, 0, 4}),
      backend.initial_frame_count,          mlx::core::array(false, {1, 512}),
      mlx::core::array(false, {1})};
}

FeedResult SortformerModel::Feed(const std::vector<float> &samples,
                                 StreamingState &state,
                                 const FeedOptions &options) const {
  auto &backend = omni_test::SortformerState();
  std::unique_lock<std::mutex> lock(backend.mutex);
  assert(backend.loading_thread == std::this_thread::get_id());
  assert(backend.active_count == 0);
  ++backend.active_count;
  ++backend.feed_count;
  backend.last_sample_count = samples.size();
  backend.last_options = options;
  backend.changed.notify_all();
  assert(backend.changed.wait_for(lock, std::chrono::seconds(10), [&] {
    return !backend.block_feed || backend.release_feed;
  }));
  --backend.active_count;
  if (backend.feed_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE audio /private/model/path");
  } else if (backend.feed_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
  }
  FeedResult result;
  result.frame_count = static_cast<int>((1 + samples.size() / 160 + 7) / 8);
  result.speaker_count = 4;
  result.probabilities.assign(static_cast<size_t>(result.frame_count) * 4,
                              0.75f);
  result.segments = ProbabilitiesToSegments(
      result.probabilities, result.frame_count, 4, frame_duration(),
      options.threshold, options.min_duration, options.merge_gap);
  const float offset_seconds =
      static_cast<float>(state.frames_processed) * frame_duration();
  for (auto &segment : result.segments) {
    segment.start += offset_seconds;
    segment.end += offset_seconds;
  }
  state.frames_processed += result.frame_count;
  using Fault = omni_test::SortformerOutputFault;
  switch (backend.output_fault) {
  case Fault::None:
    break;
  case Fault::NegativeFrames:
    result.frame_count = -1;
    break;
  case Fault::HugeFrames:
    result.frame_count = std::numeric_limits<int>::max();
    break;
  case Fault::WrongFrames:
    ++result.frame_count;
    break;
  case Fault::WrongSpeakers:
    result.speaker_count = std::numeric_limits<int>::max();
    break;
  case Fault::WrongCount:
    result.probabilities.pop_back();
    break;
  case Fault::NanProbability:
    result.probabilities[0] = std::numeric_limits<float>::quiet_NaN();
    break;
  case Fault::NegativeProbability:
    result.probabilities[0] = -0.01f;
    break;
  case Fault::LargeProbability:
    result.probabilities[0] = 1.01f;
    break;
  case Fault::NanStart:
    result.segments[0].start = std::numeric_limits<float>::quiet_NaN();
    break;
  case Fault::InfiniteEnd:
    result.segments[0].end = std::numeric_limits<float>::infinity();
    break;
  case Fault::NegativeStart:
    result.segments[0].start = -0.01f;
    break;
  case Fault::ReversedTime:
    result.segments[0].end = -0.01f;
    break;
  case Fault::LateEnd:
    result.segments[0].end += 0.01f;
    break;
  case Fault::Unsorted:
    result.segments[0].start = 0.01f + offset_seconds;
    break;
  case Fault::WrongSpeaker:
    result.segments[0].speaker = 4;
    break;
  case Fault::TooManySegments:
    result.segments.resize(105);
    break;
  case Fault::WrongCounter:
    ++state.frames_processed;
    break;
  case Fault::LargeCache:
    lock.unlock();
    state.spkcache = mlx::core::array(false, {1, 4097, 512});
    break;
  case Fault::LargeFifo:
    lock.unlock();
    state.fifo = mlx::core::array(false, {1, 4097, 512});
    break;
  }
  return result;
}

} // namespace sortformer
