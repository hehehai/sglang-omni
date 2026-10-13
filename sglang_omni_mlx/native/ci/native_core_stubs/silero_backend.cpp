// SPDX-License-Identifier: Apache-2.0
// Explicit model/MLX stand-ins; timestamp conversion is production code.
#include "silero_backend.h"
#include "silero_vad.h"

#include <algorithm>
#include <cassert>
#include <chrono>

namespace omni_test {

SileroBackendState &SileroState() {
  static SileroBackendState state;
  return state;
}

struct ArrayLifetime {
  bool is_model;
  std::thread::id owner_thread = std::this_thread::get_id();

  explicit ArrayLifetime(bool is_model) : is_model(is_model) {
    auto &backend = SileroState();
    std::lock_guard<std::mutex> lock(backend.mutex);
    assert(owner_thread == backend.loading_thread);
    ++backend.live_array_count;
  }

  ~ArrayLifetime() {
    auto &backend = SileroState();
    std::lock_guard<std::mutex> lock(backend.mutex);
    assert(owner_thread == std::this_thread::get_id());
    assert(backend.active_count == 0);
    --backend.live_array_count;
    ++backend.array_destruction_count;
    if (is_model) {
      ++backend.destruction_count;
      backend.destruction_thread = std::this_thread::get_id();
    } else {
    }
    backend.changed.notify_all();
  }
};

} // namespace omni_test

namespace mlx::core {
array::array(bool is_model)
    : lifetime(std::make_shared<omni_test::ArrayLifetime>(is_model)) {}
} // namespace mlx::core

namespace silero_vad {

SileroVAD::SileroVAD(const std::filesystem::path &model_directory) {
  auto &backend = omni_test::SileroState();
  {
    std::unique_lock<std::mutex> lock(backend.mutex);
    assert(std::filesystem::is_directory(model_directory));
    backend.loading_thread = std::this_thread::get_id();
    ++backend.load_count;
    backend.changed.notify_all();
    assert(backend.changed.wait_for(lock, std::chrono::seconds(10), [&] {
      return !backend.block_load || backend.release_load;
    }));
  }
  weights_.insert_or_assign("test_model_lifetime", mlx::core::array(true));
  std::lock_guard lock(backend.mutex);
  if (backend.load_failure != omni_test::Failure::kNone) {
    ++backend.pending_constructor_work_count;
    ++backend.pending_constructor_cache_count;
  } else {
  }
  if (backend.load_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE model /private/model/path");
  } else if (backend.load_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
  }
}

float SileroVAD::Feed(const float *chunk, StreamState &state) const {
  auto &backend = omni_test::SileroState();
  std::unique_lock<std::mutex> lock(backend.mutex);
  assert(std::this_thread::get_id() == backend.loading_thread);
  assert(backend.active_count == 0);
  ++backend.active_count;
  std::array<float, kChunkSamples> frame;
  std::copy_n(chunk, kChunkSamples, frame.begin());
  backend.frames.push_back(frame);
  backend.changed.notify_all();
  assert(backend.changed.wait_for(lock, std::chrono::seconds(10), [&] {
    return !backend.block_feed || backend.release_feed;
  }));
  --backend.active_count;
  if (backend.feed_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE audio transcript /private/model/path");
  } else if (backend.feed_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
    const float history_probability = state.context[0] * 0.125f;
    float probability = std::clamp(chunk[0] + history_probability, 0.0f, 1.0f);
    if (!backend.scripted_probabilities.empty()) {
      probability = backend.scripted_probabilities.front();
      backend.scripted_probabilities.pop_front();
    } else {
    }
    state.context[0] += 1.0f;
    lock.unlock();
    if (!state.hidden) {
      state.hidden.emplace(false);
      state.cell.emplace(false);
    } else {
    }
    return probability;
  }
}

} // namespace silero_vad
