// SPDX-License-Identifier: Apache-2.0
// Test-only backend/MLX stubs; deliberate failures contain private sentinel
// text.
#include "transcriber.h"

#include <cassert>
#include <chrono>
#include <cstdlib>

namespace omni_test {

BackendState &State() {
  static BackendState state;
  return state;
}

} // namespace omni_test

#ifdef OMNI_ABI_WRAP_MALLOC
extern "C" void *__real_malloc(size_t byte_count);
extern "C" void *__wrap_malloc(size_t byte_count) {
  auto &failure_after = omni_test::State().malloc_failure_after;
  const int remaining = failure_after.load();
  if (remaining >= 0 && failure_after.fetch_sub(1) == 0) {
    return nullptr;
  } else {
    return __real_malloc(byte_count);
  }
}
#endif

namespace mlx::core {
void synchronize() {}
void clear_cache() {}
} // namespace mlx::core

namespace qwen3_asr {

std::optional<std::string> NormalizeLanguage(const std::string &language) {
  auto &state = omni_test::State();
  std::lock_guard<std::mutex> lock(state.mutex);
  ++state.normalization_count;
  state.changed.notify_all();
  if (language.empty() || language == " ") {
    return std::nullopt;
  } else {
    return language;
  }
}

Qwen3ASRTranscriber::Qwen3ASRTranscriber(
    const std::filesystem::path &model_directory)
    : loading_thread_(std::this_thread::get_id()) {
  auto &state = omni_test::State();
  std::lock_guard<std::mutex> lock(state.mutex);
  state.loading_thread = loading_thread_;
  ++state.load_count;
  assert(std::filesystem::is_directory(model_directory));
  if (state.load_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE model /private/path transcript");
  } else if (state.load_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
  }
}

Qwen3ASRTranscriber::~Qwen3ASRTranscriber() {
  auto &state = omni_test::State();
  std::lock_guard<std::mutex> lock(state.mutex);
  assert(loading_thread_ == std::this_thread::get_id());
  assert(state.active_count == 0);
  state.destruction_thread = std::this_thread::get_id();
  ++state.destruction_count;
}

TranscriptionResult
Qwen3ASRTranscriber::Transcribe(const std::vector<float> &samples,
                                const TranscriptionOptions &options,
                                const std::atomic<bool> &cancel) const {
  auto &state = omni_test::State();
  std::unique_lock<std::mutex> lock(state.mutex);
  assert(loading_thread_ == std::this_thread::get_id());
  assert(state.active_count == 0);
  ++state.inference_count;
  ++state.active_count;
  state.samples = samples;
  state.options = options;
  state.changed.notify_all();
  while (state.block_inference && !state.release_inference) {
    state.cancellation_seen = cancel.load();
    state.changed.notify_all();
    state.changed.wait_for(lock, std::chrono::milliseconds(1));
  }
  --state.active_count;
  if (cancel.load()) {
    throw TranscriptionCancelled();
  } else if (state.infer_failure == omni_test::Failure::kStandard) {
    throw std::runtime_error("PRIVATE transcript /private/model/path");
  } else if (state.infer_failure == omni_test::Failure::kNonstandard) {
    throw 42;
  } else {
    return {state.return_empty_text
                ? ""
                : "stub transcript \xE4\xBD\xA0\xE5\xA5\xBD",
            state.return_language ? std::optional<std::string>("English")
                                  : std::nullopt,
            7,
            state.finish_reason,
            {}};
  }
}

} // namespace qwen3_asr
