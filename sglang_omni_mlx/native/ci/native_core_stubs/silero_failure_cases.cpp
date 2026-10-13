// SPDX-License-Identifier: Apache-2.0
#include "silero_cases.h"

#include <cmath>

namespace omni_test {
namespace {

void LoadAndFeedExceptions() {
  auto &backend = SileroState();
  for (Failure failure : {Failure::kStandard, Failure::kNonstandard}) {
    backend.load_failure = failure;
    char *error = reinterpret_cast<char *>(1);
    assert(omni_silero_create(std::filesystem::current_path().c_str(),
                              &error) == nullptr);
    CheckSileroError(error);
    assert(backend.live_array_count == 0);
    assert(backend.pending_constructor_work_count == 0);
    assert(backend.pending_constructor_cache_count == 0);
    assert(backend.loading_thread == backend.destruction_thread);
    assert(backend.loading_thread != std::this_thread::get_id());
  }
  backend.load_failure = Failure::kNone;
  auto model = CreateSileroModel();
  for (Failure failure : {Failure::kStandard, Failure::kNonstandard}) {
    backend.feed_failure = failure;
    auto request = CreateSileroRequest();
    const std::vector<float> samples(1024, 0.75f);
    OmniSileroResult result{};
    char *error = nullptr;
    assert(omni_silero_speech_timestamps(
               model.get(), request.get(), samples.data(), samples.size(),
               &SILERO_SETTINGS, &result, &error) == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
    backend.feed_failure = Failure::kNone;
    assert(omni_silero_speech_timestamps(
               model.get(), request.get(), samples.data(), samples.size(),
               &SILERO_SETTINGS, &result, &error) == 0);
    CheckSileroError(error);
    CheckSileroOfflineSuccess(model.get());
    backend.feed_failure = failure;
    auto stream = CreateSileroStream(model.get());
    uint64_t accepted_sequence = UINT64_MAX;
    OmniSileroStreamResult stream_result{};
    assert(omni_silero_stream_push(stream.get(), 1, samples.data(),
                                   samples.size(), &accepted_sequence,
                                   &stream_result, &error) == 0);
    assert(accepted_sequence == 0);
    CheckSileroCleared(stream_result);
    CheckSileroError(error);
    backend.feed_failure = Failure::kNone;
    CheckSileroPushRejected(stream.get());
    assert(omni_silero_stream_finish(stream.get(), &stream_result, nullptr) ==
           0);
    CheckSileroDrain(stream.get());
    CheckSileroOfflineSuccess(model.get());
  }
}

void InvalidProbabilities() {
  auto model = CreateSileroModel();
  auto &backend = SileroState();
  for (float probability : {-0.01f, 1.01f, NAN, INFINITY, -INFINITY}) {
    auto request = CreateSileroRequest();
    const std::vector<float> samples(1024, 0.75f);
    OmniSileroResult result{};
    char *error = nullptr;
    backend.scripted_probabilities = {probability};
    auto frame_count = backend.frames.size();
    assert(omni_silero_speech_timestamps(
               model.get(), request.get(), samples.data(), samples.size(),
               &SILERO_SETTINGS, &result, &error) == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
    assert(backend.frames.size() == frame_count + 1);
    for (bool finishing : {false, true}) {
      auto stream = CreateSileroStream(model.get());
      CheckSileroPush(stream.get(), 1, 511, 0, {});
      backend.scripted_probabilities = {probability};
      frame_count = backend.frames.size();
      OmniSileroStreamResult stream_result{};
      if (finishing) {
        assert(omni_silero_stream_finish(stream.get(), &stream_result,
                                         &error) == 0);
      } else {
        uint64_t accepted_sequence = UINT64_MAX;
        assert(omni_silero_stream_push(stream.get(), 2, samples.data(),
                                       samples.size(), &accepted_sequence,
                                       &stream_result, &error) == 0);
        assert(accepted_sequence == 0);
      }
      CheckSileroCleared(stream_result);
      CheckSileroError(error);
      CheckSileroPushRejected(stream.get(), 2);
      assert(omni_silero_stream_finish(stream.get(), &stream_result, nullptr) ==
             0);
      assert(backend.frames.size() == frame_count + 1);
      CheckSileroDrain(stream.get());
      assert(backend.live_array_count == 1);
    }
    CheckSileroOfflineSuccess(model.get());
  }
  auto partial = CreateSileroStream(model.get());
  backend.scripted_probabilities = {0.25f, NAN};
  const std::vector<float> samples(1024, 0.25f);
  uint64_t accepted_sequence = UINT64_MAX;
  OmniSileroStreamResult result{};
  assert(omni_silero_stream_push(partial.get(), 1, samples.data(),
                                 samples.size(), &accepted_sequence, &result,
                                 nullptr) == 0);
  assert(accepted_sequence == 0);
  CheckSileroCleared(result);
  CheckSileroPushRejected(partial.get());
  CheckSileroDrain(partial.get());
  auto stream = CreateSileroStream(model.get());
  backend.scripted_probabilities = {0.0f, 1.0f};
  CheckSileroPush(stream.get(), 1, 1024, 1024, {0.0f, 1.0f});
}

void AllocationFailures() {
#ifdef OMNI_ABI_WRAP_MALLOC
  fail_next_new = true;
  assert(omni_silero_request_create() == nullptr);
  assert(!fail_next_new.load());
  const auto directory = std::filesystem::current_path().string();
  char *creation_error = nullptr;
  fail_next_new = true;
  assert(omni_silero_create(directory.c_str(), &creation_error) == nullptr);
  assert(!fail_next_new.load());
  CheckSileroError(creation_error);
  auto model = CreateSileroModel();
  fail_next_new = true;
  assert(omni_silero_stream_create(model.get(), &creation_error) == nullptr);
  assert(!fail_next_new.load());
  CheckSileroError(creation_error);
  std::vector<SileroStream> leases;
  for (size_t i = 0; i < OMNI_SILERO_MAX_STREAMS; ++i) {
    leases.push_back(CreateSileroStream(model.get()));
  }
  leases.clear();
  auto &backend = SileroState();
  const std::vector<float> samples(1009, 0.75f);
  for (bool copying : {false, true}) {
    auto request = CreateSileroRequest();
    OmniSileroResult result{reinterpret_cast<OmniSileroTimestamp *>(1), 9};
    char *error = nullptr;
    if (copying) {
      new_failure_byte_count = samples.size() * sizeof(float);
    } else {
      State().malloc_failure_after = 0;
    }
    assert(omni_silero_speech_timestamps(
               model.get(), request.get(), samples.data(), samples.size(),
               &SILERO_SETTINGS, &result, &error) == 0);
    assert(new_failure_byte_count == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
    assert(omni_silero_speech_timestamps(
               model.get(), request.get(), samples.data(), samples.size(),
               &SILERO_SETTINGS, &result, nullptr) == 0);
    CheckSileroOfflineSuccess(model.get());
  }
  auto retryable = CreateSileroStream(model.get());
  CheckSileroPush(retryable.get(), 1, 511, 0, {});
  uint64_t accepted_sequence = UINT64_MAX;
  OmniSileroStreamResult result{};
  char *error = nullptr;
  const auto frame_count = backend.frames.size();
  new_failure_byte_count = samples.size() * sizeof(float);
  assert(omni_silero_stream_push(retryable.get(), 2, samples.data(),
                                 samples.size(), &accepted_sequence, &result,
                                 &error) == 0);
  assert(new_failure_byte_count == 0 && accepted_sequence == 0);
  CheckSileroCleared(result);
  CheckSileroError(error);
  assert(backend.frames.size() == frame_count);
  CheckSileroPush(retryable.get(), 2, 1, 512, {0.25f});
  for (bool finishing : {false, true}) {
    auto stream = CreateSileroStream(model.get());
    CheckSileroPush(stream.get(), 1, 511, 0, {});
    State().malloc_failure_after = 0;
    if (finishing) {
      assert(omni_silero_stream_finish(stream.get(), &result, &error) == 0);
    } else {
      accepted_sequence = UINT64_MAX;
      assert(omni_silero_stream_push(stream.get(), 2, samples.data(),
                                     samples.size(), &accepted_sequence,
                                     &result, &error) == 0);
      assert(accepted_sequence == 0);
    }
    CheckSileroError(error);
    CheckSileroCleared(result);
    CheckSileroPushRejected(stream.get(), 2);
    assert(omni_silero_stream_finish(stream.get(), &result, nullptr) == 0);
    CheckSileroDrain(stream.get());
  }
  auto worker_failure = CreateSileroStream(model.get());
  const std::vector<float> six_frames(6 * OMNI_SILERO_FRAME_SAMPLES, 0.25f);
  new_failure_byte_count = 6 * sizeof(float);
  accepted_sequence = UINT64_MAX;
  assert(omni_silero_stream_push(worker_failure.get(), 1, six_frames.data(),
                                 six_frames.size(), &accepted_sequence, &result,
                                 &error) == 0);
  assert(new_failure_byte_count == 0 && accepted_sequence == 0);
  CheckSileroCleared(result);
  CheckSileroError(error);
  CheckSileroPushRejected(worker_failure.get());
  CheckSileroDrain(worker_failure.get());
  auto empty = CreateSileroStream(model.get());
  State().malloc_failure_after = 0;
  CheckSileroPush(empty.get(), 1, 511, 0, {});
  assert(State().malloc_failure_after == 0);
  State().malloc_failure_after = -1;
  CheckSileroFinish(empty.get(), 512, {0.25f});
  State().malloc_failure_after = 0;
  CheckSileroFinish(empty.get(), 512, {});
  assert(State().malloc_failure_after == 0);
  error = reinterpret_cast<char *>(1);
  assert(omni_silero_create(nullptr, &error) == nullptr);
  assert(error == nullptr);
  CheckSileroOfflineSuccess(model.get());
#endif
}

void SerializedInputAdmission() {
#ifdef OMNI_ABI_WRAP_MALLOC
  auto model = CreateSileroModel();
  auto first = CreateSileroStream(model.get());
  auto second = CreateSileroStream(model.get());
  const std::vector<float> samples(1009, 0.25f);
  SileroState().block_feed = true;
  auto running = std::async(std::launch::async, [&] {
    CheckSileroPush(first.get(), 1, 512, 512, {0.25f});
  });
  WaitForSileroFeed();
  new_failure_byte_count = samples.size() * sizeof(float);
  std::promise<void> started;
  auto has_started = started.get_future();
  auto waiting = std::async(std::launch::async, [&] {
    started.set_value();
    uint64_t accepted_sequence = UINT64_MAX;
    OmniSileroStreamResult result{};
    char *error = nullptr;
    assert(omni_silero_stream_push(second.get(), 1, samples.data(),
                                   samples.size(), &accepted_sequence, &result,
                                   &error) == 0);
    assert(accepted_sequence == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
  });
  has_started.get();
  assert(waiting.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  assert(new_failure_byte_count == samples.size() * sizeof(float));
  ReleaseSileroFeed();
  running.get();
  waiting.get();
  assert(new_failure_byte_count == 0);
  assert(SileroState().frames.size() == 1);
  CheckSileroPush(second.get(), 1, 512, 512, {0.25f});
  CheckSileroPush(first.get(), 2, 512, 1024, {0.375f});
#endif
}

} // namespace

void RunSileroFailureCase(const std::string &test) {
  if (test == "silero_failure_exceptions") {
    LoadAndFeedExceptions();
  } else if (test == "silero_failure_probabilities") {
    InvalidProbabilities();
  } else if (test == "silero_failure_allocation") {
    AllocationFailures();
  } else if (test == "silero_failure_serialized_admission") {
    SerializedInputAdmission();
  } else {
    assert(false && "Unknown Silero failure test");
  }
}

} // namespace omni_test
