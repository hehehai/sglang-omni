// SPDX-License-Identifier: Apache-2.0
// Public ABI tests against the real worker and explicitly stubbed backend/MLX.
#include "native_core_stubs/silero_backend.h"
#include "native_core_stubs/sortformer_backend.h"
#include "native_core_stubs/sortformer_config_fixture.h"
#include "omni_native_core.h"
#include "transcriber.h"

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <future>
#include <iostream>
#include <limits>
#include <new>
#include <string>
#include <vector>

namespace omni_test {
std::atomic<size_t> new_failure_byte_count{0};
std::atomic<bool> fail_next_new{false};
} // namespace omni_test

#ifdef OMNI_ABI_WRAP_MALLOC
// Note (Codex): interposition also covers string copies inside the C++ runtime.
void *operator new(size_t byte_count) {
  auto &failure_byte_count = omni_test::new_failure_byte_count;
  size_t expected_byte_count = byte_count;
  if (omni_test::fail_next_new.exchange(false) ||
      (byte_count != 0 &&
       failure_byte_count.compare_exchange_strong(expected_byte_count, 0))) {
    throw std::bad_alloc();
  } else {
    void *allocation = std::malloc(byte_count == 0 ? 1 : byte_count);
    if (allocation == nullptr) {
      throw std::bad_alloc();
    } else {
      return allocation;
    }
  }
}
void *operator new[](size_t byte_count) { return ::operator new(byte_count); }
// Note (OpenAI): stable_sort uses nothrow new; pair it with this fixture's
// malloc-backed delete instead of ASan's independent new allocator.
void *operator new(size_t byte_count, const std::nothrow_t &) noexcept {
  try {
    return ::operator new(byte_count);
  } catch (const std::bad_alloc &) {
    return nullptr;
  }
}
void *operator new[](size_t byte_count, const std::nothrow_t &tag) noexcept {
  return ::operator new(byte_count, tag);
}
void operator delete(void *allocation, const std::nothrow_t &) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, const std::nothrow_t &) noexcept {
  std::free(allocation);
}
void operator delete(void *allocation) noexcept { std::free(allocation); }
void operator delete[](void *allocation) noexcept { std::free(allocation); }
void operator delete(void *allocation, size_t) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, size_t) noexcept {
  std::free(allocation);
}
#endif

namespace {

const float SAMPLES[] = {0.25f, -0.5f, 0.0f};

void CheckZero(const OmniQwenResult &result) {
  assert(result.text == nullptr && result.language == nullptr);
  assert(result.generated_token_count == 0 && result.hit_length_limit == 0);
}

OmniQwenHandle *Create() {
  char *error = reinterpret_cast<char *>(1);
  auto *handle =
      omni_qwen_create(std::filesystem::current_path().c_str(), &error);
  assert(handle != nullptr && error == nullptr);
  assert(omni_test::State().loading_thread != std::this_thread::get_id());
  return handle;
}

int Transcribe(OmniQwenHandle *handle, OmniQwenResult *result, char **error) {
  return omni_qwen_transcribe(handle, SAMPLES, 3, nullptr, nullptr, 128, result,
                              error);
}

void CheckSuccess(OmniQwenHandle *handle) {
  OmniQwenResult result{};
  char *error = reinterpret_cast<char *>(1);
  assert(Transcribe(handle, &result, &error) == 1);
  assert(error == nullptr && result.text != nullptr);
  omni_qwen_result_free(&result);
  CheckZero(result);
  omni_qwen_result_free(&result);
}

void InvalidDirectories() {
  for (const char *directory : {static_cast<const char *>(nullptr), "",
                                "missing-private-model-directory", __FILE__}) {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_create(directory, &error) == nullptr);
    assert(error != nullptr);
    assert(std::strcmp(error, "Invalid model directory.") == 0);
    omni_string_free(error);
  }
  assert(omni_qwen_create(nullptr, nullptr) == nullptr);
}

void InvalidInputs() {
  auto *handle = Create();
  struct InvalidInput {
    OmniQwenHandle *handle;
    const float *samples;
    size_t sample_count;
    int maximum_token_count;
  };
  for (const auto &input : std::vector<InvalidInput>{
           {nullptr, SAMPLES, 3, 1},
           {handle, nullptr, 3, 1},
           {handle, SAMPLES, 0, 1},
           {handle, SAMPLES, 480001, 1},
           {handle, SAMPLES, std::numeric_limits<size_t>::max(), 1},
           {handle, SAMPLES, 3, 0},
           {handle, SAMPLES, 3, -1},
           {handle, SAMPLES, 3, 4097},
           {handle, SAMPLES, 3, std::numeric_limits<int>::max()}}) {
    OmniQwenResult result{reinterpret_cast<char *>(1),
                          reinterpret_cast<char *>(1), 9, 9};
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_transcribe(input.handle, input.samples, input.sample_count,
                                nullptr, nullptr, input.maximum_token_count,
                                &result, &error) == 0);
    CheckZero(result);
    assert(std::strcmp(error, "Invalid transcription input.") == 0);
    omni_string_free(error);
  }
  for (float nonfinite : {NAN, INFINITY, -INFINITY}) {
    for (size_t position = 0; position < 3; ++position) {
      std::vector<float> samples(3, 0.0f);
      samples[position] = nonfinite;
      OmniQwenResult result{};
      char *error = nullptr;
      assert(omni_qwen_transcribe(handle, samples.data(), samples.size(),
                                  nullptr, nullptr, 1, &result, &error) == 0);
      CheckZero(result);
      assert(std::strcmp(error, "Audio samples must be finite.") == 0);
      omni_string_free(error);
    }
  }
  char *error = nullptr;
  assert(Transcribe(handle, nullptr, &error) == 0);
  omni_string_free(error);
  assert(Transcribe(handle, nullptr, nullptr) == 0);
  assert(omni_test::State().inference_count == 0);
  omni_qwen_destroy(handle);
}

void OwnershipAndOptions() {
  auto *handle = Create();
  auto &state = omni_test::State();
  std::vector<float> samples(480000, 0.125f);
  OmniQwenResult first{};
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_transcribe(handle, samples.data(), samples.size(), "English",
                              "private context", 4096, &first, &error) == 1);
  assert(error == nullptr);
  assert(std::strcmp(first.text, "stub transcript \xE4\xBD\xA0\xE5\xA5\xBD") ==
         0);
  assert(std::strcmp(first.language, "English") == 0);
  assert(first.generated_token_count == 7 && first.hit_length_limit == 0);
  assert(state.samples == samples);
  assert(state.options.language == "English");
  assert(state.options.context == "private context");
  assert(state.options.max_new_tokens == 4096);
  assert(state.options.stop_at_end_of_text && state.options.stop_on_token_loop);
  assert(state.options.layout == qwen3_asr::AudioLayout::kVoxtSwift);
  assert(state.options.prefix_token_ids.empty() &&
         state.options.prefix_text.empty());

  OmniQwenResult second{};
  assert(omni_qwen_transcribe(handle, SAMPLES, 1, " ", nullptr, 1, &second,
                              nullptr) == 1);
  assert(!state.options.language && !state.options.context);
  assert(state.options.max_new_tokens == 1);
  assert(first.text != second.text && first.language != second.language);
  first.text[0] = 'X';
  assert(second.text[0] == 's');
  omni_qwen_result_free(&first);
  CheckZero(first);
  omni_qwen_result_free(&first);
  omni_qwen_result_free(&second);

  state.return_empty_text = true;
  state.return_language = false;
  state.finish_reason = qwen3_asr::FinishReason::kLength;
  assert(Transcribe(handle, &first, &error) == 1);
  assert(error == nullptr && first.text != nullptr && first.text[0] == '\0');
  assert(first.language == nullptr && first.hit_length_limit == 1);
  omni_qwen_destroy(handle);
  omni_qwen_result_free(&first);
  omni_qwen_cancel(nullptr);
  omni_qwen_destroy(nullptr);
  omni_qwen_result_free(nullptr);
  omni_string_free(nullptr);
}

void Exceptions() {
  auto &state = omni_test::State();
  for (auto failure :
       {omni_test::Failure::kStandard, omni_test::Failure::kNonstandard}) {
    state.load_failure = failure;
    char *error = nullptr;
    assert(omni_qwen_create(std::filesystem::current_path().c_str(), &error) ==
           nullptr);
    assert(std::strcmp(error, "Model initialization failed.") == 0);
    omni_string_free(error);
    assert(state.loading_thread != std::this_thread::get_id());
  }
  state.load_failure = omni_test::Failure::kNone;
  auto *handle = Create();
  for (auto failure :
       {omni_test::Failure::kStandard, omni_test::Failure::kNonstandard}) {
    state.infer_failure = failure;
    OmniQwenResult result{};
    char *error = nullptr;
    assert(Transcribe(handle, &result, &error) == 0);
    assert(std::strcmp(error, "Transcription failed.") == 0);
    CheckZero(result);
    omni_string_free(error);
  }
  state.infer_failure = omni_test::Failure::kNone;
  CheckSuccess(handle);
  omni_qwen_destroy(handle);
}

void AllocationFailures() {
#ifdef OMNI_ABI_WRAP_MALLOC
  auto *handle = Create();
  for (int allocation_count : {0, 1}) {
    omni_test::State().malloc_failure_after = allocation_count;
    OmniQwenResult result{};
    char *error = nullptr;
    assert(Transcribe(handle, &result, &error) == 0);
    CheckZero(result);
    assert(std::strcmp(error, "Transcription failed.") == 0);
    omni_string_free(error);
  }
  omni_test::State().malloc_failure_after = 0;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_create(nullptr, &error) == nullptr);
  assert(error == nullptr);
  CheckSuccess(handle);
  omni_qwen_destroy(handle);
#endif
}

void CancellationAndDestruction(bool destroy_active) {
  auto *handle = Create();
  auto &state = omni_test::State();
  state.block_inference = true;
  auto request = std::async(std::launch::async, [handle] {
    OmniQwenResult result{};
    char *error = nullptr;
    assert(Transcribe(handle, &result, &error) == 0);
    assert(std::strcmp(error, "Transcription cancelled.") == 0);
    CheckZero(result);
    omni_string_free(error);
  });
  {
    std::unique_lock<std::mutex> lock(state.mutex);
    assert(state.changed.wait_for(lock, std::chrono::seconds(5),
                                  [&] { return state.active_count == 1; }));
  }
  std::atomic<bool> destroyed{false};
  std::future<void> destruction;
  if (destroy_active) {
    destruction = std::async(std::launch::async, [&] {
      omni_qwen_destroy(handle);
      destroyed = true;
    });
  } else {
    omni_qwen_cancel(handle);
  }
  {
    std::unique_lock<std::mutex> lock(state.mutex);
    assert(state.changed.wait_for(lock, std::chrono::seconds(5),
                                  [&] { return state.cancellation_seen; }));
    assert(state.destruction_count == 0 && !destroyed.load());
    state.release_inference = true;
    state.changed.notify_all();
  }
  request.get();
  if (destroy_active) {
    destruction.get();
    assert(destroyed.load());
  } else {
    omni_qwen_cancel(handle);
    OmniQwenResult result{};
    char *error = nullptr;
    assert(Transcribe(handle, &result, &error) == 0);
    assert(std::strcmp(error, "Transcription cancelled.") == 0);
    CheckZero(result);
    omni_string_free(error);
    omni_qwen_destroy(handle);
  }
  assert(state.destruction_count == 1);
  assert(state.loading_thread == state.destruction_thread);
}

void CancellationBeforeSubmission() {
  auto *handle = Create();
  omni_qwen_cancel(handle);
  OmniQwenResult result{};
  char *error = nullptr;
  assert(Transcribe(handle, &result, &error) == 0);
  assert(std::strcmp(error, "Transcription cancelled.") == 0);
  CheckZero(result);
  omni_string_free(error);
  assert(omni_test::State().inference_count == 0);
  omni_qwen_destroy(handle);
  auto *fresh = Create();
  CheckSuccess(fresh);
  omni_qwen_destroy(fresh);
  assert(omni_test::State().inference_count == 1);
}

void ConcurrentRequests() {
  auto *handle = Create();
  std::vector<std::future<void>> requests;
  for (int i = 0; i < 8; ++i) {
    requests.push_back(
        std::async(std::launch::async, [handle] { CheckSuccess(handle); }));
  }
  for (auto &request : requests) {
    request.get();
  }
  assert(omni_test::State().inference_count == 8);
  omni_qwen_destroy(handle);
  for (int i = 0; i < 16; ++i) {
    auto *next_handle = Create();
    CheckSuccess(next_handle);
    omni_qwen_destroy(next_handle);
  }
  assert(omni_test::State().destruction_count == 17);
}

} // namespace

int main(int argument_count, char **arguments) {
  assert(argument_count == 2 && omni_core_abi_version() == 9);
  omni_test::SortformerState().config.modules.use_aosc = true;
  const std::string test = arguments[1];
  if (test.starts_with("sortformer_") &&
      !test.starts_with("sortformer_config_")) {
    omni_test::WriteSortformerConfig(omni_test::SortformerState().config);
  } else {
  }
  if (test == "invalid_directories") {
    InvalidDirectories();
  } else if (test == "invalid_inputs") {
    InvalidInputs();
  } else if (test == "ownership_options") {
    OwnershipAndOptions();
  } else if (test == "exceptions") {
    Exceptions();
  } else if (test == "allocation_failures") {
    AllocationFailures();
  } else if (test == "cancellation") {
    CancellationAndDestruction(false);
  } else if (test == "cancel_before_submission") {
    CancellationBeforeSubmission();
  } else if (test == "destroy_active") {
    CancellationAndDestruction(true);
  } else if (test == "concurrent_requests") {
    ConcurrentRequests();
  } else if (test.starts_with("silero_offline_")) {
    omni_test::RunSileroOfflineCase(test);
  } else if (test.starts_with("silero_stream_")) {
    omni_test::RunSileroStreamCase(test);
  } else if (test.starts_with("silero_lifecycle_")) {
    omni_test::RunSileroLifecycleCase(test);
  } else if (test.starts_with("silero_failure_")) {
    omni_test::RunSileroFailureCase(test);
  } else if (test.starts_with("sortformer_failure_") ||
             test.starts_with("sortformer_config_")) {
    omni_test::RunSortformerFailureCase(test);
  } else if (test.starts_with("sortformer_lifecycle_")) {
    omni_test::RunSortformerLifecycleCase(test);
  } else if (test.starts_with("sortformer_")) {
    omni_test::RunSortformerCase(test);
  } else if (test.starts_with("realtime_")) {
    omni_test::RunRealtimeCase(test);
  } else {
    omni_test::RunRequestCase(test);
  }
  if (test.starts_with("silero_")) {
    const auto &backend = omni_test::SileroState();
    assert(backend.load_count == backend.destruction_count);
    assert(backend.live_array_count == 0 && backend.active_count == 0);
    assert(backend.loading_thread == backend.destruction_thread);
  } else if (test.starts_with("sortformer_")) {
    const auto &backend = omni_test::SortformerState();
    assert(backend.load_count == backend.destruction_count);
    assert(backend.live_array_count == 0 && backend.active_count == 0);
    assert(backend.loading_thread == backend.destruction_thread);
  } else {
  }
  std::cout << "PASS " << test
            << " (model/MLX stubs; real native worker and config parser)\n";
}
