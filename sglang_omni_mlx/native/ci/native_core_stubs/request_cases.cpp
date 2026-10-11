// SPDX-License-Identifier: Apache-2.0
// Request lifecycle tests use the public ABI, real worker, and backend
// barriers.
#include "omni_native_core.h"
#include "transcriber.h"

#include <cassert>
#include <chrono>
#include <cstring>
#include <future>
#include <limits>
#include <memory>
#include <vector>

namespace omni_test {
namespace {

const float SAMPLES[] = {0.25f, -0.5f, 0.0f};
using Request =
    std::unique_ptr<OmniQwenRequest, decltype(&omni_qwen_request_destroy)>;

Request NewRequest() {
  Request request(omni_qwen_request_create(), &omni_qwen_request_destroy);
  assert(request != nullptr);
  return request;
}

struct RequestFixture {
  std::unique_ptr<OmniQwenHandle, decltype(&omni_qwen_destroy)> handle{
      nullptr, &omni_qwen_destroy};

  RequestFixture() {
    char *error = reinterpret_cast<char *>(1);
    handle.reset(
        omni_qwen_create(std::filesystem::current_path().c_str(), &error));
    assert(handle != nullptr && error == nullptr);
    assert(State().load_count == 1);
    assert(State().loading_thread != std::this_thread::get_id());
  }

  ~RequestFixture() {
    handle.reset();
    assert(State().load_count == 1 && State().destruction_count == 1);
    assert(State().loading_thread == State().destruction_thread);
  }

  void Check(OmniQwenRequest *request, const char *expected_error = nullptr) {
    OmniQwenResult result{reinterpret_cast<char *>(1),
                          reinterpret_cast<char *>(1), 9, 9};
    char *error = reinterpret_cast<char *>(1);
    const int success = omni_qwen_transcribe_request(
        handle.get(), request, SAMPLES, 3, "English", "private context", 128,
        &result, &error);
    if (expected_error == nullptr) {
      assert(success == 1 && error == nullptr);
      assert(std::strcmp(result.text,
                         "stub transcript \xE4\xBD\xA0\xE5\xA5\xBD") == 0);
      assert(std::strcmp(result.language, "English") == 0);
      assert(result.generated_token_count == 7 && result.hit_length_limit == 0);
    } else {
      assert(success == 0 && error != nullptr);
      assert(std::strcmp(error, expected_error) == 0);
      assert(result.text == nullptr && result.language == nullptr);
      assert(result.generated_token_count == 0 && result.hit_length_limit == 0);
    }
    omni_qwen_result_free(&result);
    omni_string_free(error);
  }

  void WaitForInference(bool cancellation = false) {
    auto &state = State();
    std::unique_lock<std::mutex> lock(state.mutex);
    assert(state.changed.wait_for(lock, std::chrono::seconds(5), [&] {
      return cancellation ? state.cancellation_seen : state.active_count == 1;
    }));
  }

  void WaitForSubmission(OmniQwenRequest *request, int normalization_count) {
    auto &state = State();
    {
      std::unique_lock<std::mutex> lock(state.mutex);
      assert(state.changed.wait_for(lock, std::chrono::seconds(5), [&] {
        return state.normalization_count == normalization_count;
      }));
    }
    // Note (Codex): normalization proves the first caller claimed the token;
    // duplicate rejection waits for its submission lock, without timing sleeps.
    Check(request, "Request already used.");
  }

  void ReleaseInference() {
    auto &state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    state.release_inference = true;
    state.changed.notify_all();
  }
};

void CancelBeforeSubmission() {
  RequestFixture fixture;
  auto request = NewRequest();
  omni_qwen_request_cancel(request.get());
  omni_qwen_request_cancel(request.get());
  fixture.Check(request.get(), "Transcription cancelled.");
  fixture.Check(request.get(), "Request already used.");
  assert(State().inference_count == 0);
  request.reset();
  auto fresh = NewRequest();
  fixture.Check(fresh.get());
  fixture.Check(fresh.get(), "Request already used.");
  assert(State().inference_count == 1 && State().load_count == 1);
  assert(State().options.context == "private context");
  assert(State().options.language == "English");
  assert(State().options.max_new_tokens == 128);
  assert(State().options.stop_at_end_of_text &&
         State().options.stop_on_token_loop);
  assert(State().options.layout == qwen3_asr::AudioLayout::kVoxtSwift);
  OmniQwenResult result{};
  assert(omni_qwen_transcribe(fixture.handle.get(), SAMPLES, 3, nullptr,
                              nullptr, 128, &result, nullptr) == 1);
  omni_qwen_result_free(&result);
  assert(State().inference_count == 2 && State().load_count == 1);
}

void InvalidRequests() {
  RequestFixture fixture;
  fixture.Check(nullptr, "Invalid transcription request.");
  assert(omni_qwen_transcribe_request(nullptr, nullptr, nullptr, 0, nullptr,
                                      nullptr, 0, nullptr, nullptr) == 0);
  omni_qwen_request_cancel(nullptr);
  omni_qwen_request_destroy(nullptr);
  auto unused = NewRequest();
  unused.reset();
  const float nonfinite = std::numeric_limits<float>::quiet_NaN();
  struct InvalidInput {
    OmniQwenHandle *handle;
    const float *samples;
    size_t sample_count;
    int maximum_token_count;
    bool missing_result = false;
    const char *error = "Invalid transcription input.";
  };
  for (const auto &input :
       std::vector<InvalidInput>{{nullptr, SAMPLES, 3, 128},
                                 {fixture.handle.get(), nullptr, 3, 128},
                                 {fixture.handle.get(), SAMPLES, 0, 128},
                                 {fixture.handle.get(), SAMPLES, 480001, 128},
                                 {fixture.handle.get(), SAMPLES, 3, 0},
                                 {fixture.handle.get(), SAMPLES, 3, 4097},
                                 {fixture.handle.get(), SAMPLES, 3, 128, true},
                                 {fixture.handle.get(), &nonfinite, 1, 128,
                                  false, "Audio samples must be finite."}}) {
    auto request = NewRequest();
    OmniQwenResult result{};
    char *error = nullptr;
    assert(omni_qwen_transcribe_request(
               input.handle, request.get(), input.samples, input.sample_count,
               nullptr, nullptr, input.maximum_token_count,
               input.missing_result ? nullptr : &result, &error) == 0);
    assert(std::strcmp(error, input.error) == 0);
    assert(result.text == nullptr && result.language == nullptr);
    assert(result.generated_token_count == 0 && result.hit_length_limit == 0);
    omni_string_free(error);
    fixture.Check(request.get(), "Request already used.");
  }
  assert(State().inference_count == 0);
  auto fresh = NewRequest();
  fixture.Check(fresh.get());
}

enum class Cancellation { kToken, kDestroyToken, kModel, kDestroyModel };

void ActiveCancellation(Cancellation cancellation) {
  RequestFixture fixture;
  auto request = NewRequest();
  State().block_inference = true;
  auto transcription =
      std::async(std::launch::async, [&fixture, pointer = request.get()] {
        fixture.Check(pointer, "Transcription cancelled.");
      });
  fixture.WaitForInference();
  std::future<void> destruction;
  if (cancellation == Cancellation::kToken) {
    omni_qwen_request_cancel(request.get());
  } else if (cancellation == Cancellation::kDestroyToken) {
    request.reset();
  } else if (cancellation == Cancellation::kModel) {
    omni_qwen_cancel(fixture.handle.get());
  } else {
    auto *handle = fixture.handle.release();
    destruction =
        std::async(std::launch::async, [handle] { omni_qwen_destroy(handle); });
  }
  fixture.WaitForInference(true);
  {
    std::lock_guard<std::mutex> lock(State().mutex);
    assert(State().active_count == 1 && State().destruction_count == 0);
  }
  fixture.ReleaseInference();
  transcription.get();
  if (destruction.valid()) {
    destruction.get();
  } else {
    auto fresh = NewRequest();
    fixture.Check(fresh.get(), cancellation == Cancellation::kModel
                                   ? "Transcription cancelled."
                                   : nullptr);
  }
  if (request != nullptr) {
    fixture.Check(request.get(), "Request already used.");
  } else {
  }
}

void QueuedCancellation(Cancellation cancellation) {
  RequestFixture fixture;
  auto active = NewRequest();
  auto queued = NewRequest();
  auto independent = NewRequest();
  const char *independent_error = cancellation == Cancellation::kModel
                                      ? "Transcription cancelled."
                                      : nullptr;
  State().block_inference = true;
  auto running = std::async(std::launch::async, [&] {
    fixture.Check(active.get(), independent_error);
  });
  fixture.WaitForInference();
  auto cancelled =
      std::async(std::launch::async, [&fixture, pointer = queued.get()] {
        fixture.Check(pointer, "Transcription cancelled.");
      });
  fixture.WaitForSubmission(queued.get(), 2);
  auto waiting = std::async(std::launch::async, [&] {
    fixture.Check(independent.get(), independent_error);
  });
  fixture.WaitForSubmission(independent.get(), 3);
  if (cancellation == Cancellation::kDestroyToken) {
    queued.reset();
  } else if (cancellation == Cancellation::kModel) {
    omni_qwen_cancel(fixture.handle.get());
    fixture.WaitForInference(true);
  } else {
    omni_qwen_request_cancel(queued.get());
  }
  fixture.ReleaseInference();
  running.get();
  cancelled.get();
  waiting.get();
  assert(State().inference_count == (independent_error == nullptr ? 2 : 1));
  auto fresh = NewRequest();
  fixture.Check(fresh.get(), independent_error);
}

void ConcurrentReuse() {
  RequestFixture fixture;
  auto request = NewRequest();
  State().block_inference = true;
  auto first =
      std::async(std::launch::async, [&] { fixture.Check(request.get()); });
  fixture.WaitForInference();
  std::vector<std::future<void>> duplicates;
  for (int i = 0; i < 8; ++i) {
    duplicates.push_back(std::async(std::launch::async, [&] {
      fixture.Check(request.get(), "Request already used.");
    }));
  }
  for (auto &duplicate : duplicates) {
    duplicate.get();
  }
  fixture.ReleaseInference();
  first.get();
  fixture.Check(request.get(), "Request already used.");
  assert(State().inference_count == 1);
}

void RequestFailures() {
  RequestFixture fixture;
  for (auto failure : {Failure::kStandard, Failure::kNonstandard}) {
    State().infer_failure = failure;
    auto request = NewRequest();
    fixture.Check(request.get(), "Transcription failed.");
    fixture.Check(request.get(), "Request already used.");
  }
  State().infer_failure = Failure::kNone;
#ifdef OMNI_ABI_WRAP_MALLOC
  for (int allocation_count : {0, 1}) {
    auto request = NewRequest();
    State().malloc_failure_after = allocation_count;
    fixture.Check(request.get(), "Transcription failed.");
    fixture.Check(request.get(), "Request already used.");
  }
  State().malloc_failure_after = 0;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_transcribe_request(fixture.handle.get(), nullptr, SAMPLES, 3,
                                      nullptr, nullptr, 128, nullptr,
                                      &error) == 0);
  assert(error == nullptr);
#endif
  auto fresh = NewRequest();
  fixture.Check(fresh.get());
}

} // namespace

void RunRequestCase(const std::string &test) {
  if (test == "request_cancel_before_submission") {
    CancelBeforeSubmission();
  } else if (test == "request_invalid") {
    InvalidRequests();
  } else if (test == "request_cancel_active") {
    ActiveCancellation(Cancellation::kToken);
  } else if (test == "request_destroy_active") {
    ActiveCancellation(Cancellation::kDestroyToken);
  } else if (test == "request_model_cancel_active") {
    ActiveCancellation(Cancellation::kModel);
  } else if (test == "request_model_destroy_active") {
    ActiveCancellation(Cancellation::kDestroyModel);
  } else if (test == "request_cancel_queued") {
    QueuedCancellation(Cancellation::kToken);
  } else if (test == "request_destroy_queued") {
    QueuedCancellation(Cancellation::kDestroyToken);
  } else if (test == "request_model_cancel_queued") {
    QueuedCancellation(Cancellation::kModel);
  } else if (test == "request_concurrent_reuse") {
    ConcurrentReuse();
  } else if (test == "request_failures") {
    RequestFailures();
  } else {
    assert(false);
  }
}

} // namespace omni_test
