// SPDX-License-Identifier: Apache-2.0
// Public ABI tests against the real worker and explicitly stubbed backend/MLX.
#include "omni_native_core.h"
#include "transcriber.h"

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <future>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

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
  assert(argument_count == 2 && omni_core_abi_version() == 1);
  const std::string test = arguments[1];
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
  } else {
    assert(false);
  }
  std::cout << "PASS " << test << " (backend/MLX stubs; real native worker)\n";
}
