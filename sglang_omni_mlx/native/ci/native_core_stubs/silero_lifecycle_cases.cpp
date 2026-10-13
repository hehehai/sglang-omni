// SPDX-License-Identifier: Apache-2.0
#include "silero_cases.h"

namespace omni_test {
namespace {

enum class StopKind { Request, DestroyRequest, Model, DestroyModel };

void OfflineActiveStop(StopKind stop_kind) {
  auto model = CreateSileroModel();
  auto request = CreateSileroRequest();
  auto &backend = SileroState();
  backend.block_feed = true;
  auto inference =
      std::async(std::launch::async, [model_pointer = model.get(),
                                      request_pointer = request.get()] {
        const std::vector<float> samples(1536, 0.75f);
        OmniSileroResult result{};
        char *error = nullptr;
        assert(omni_silero_speech_timestamps(
                   model_pointer, request_pointer, samples.data(),
                   samples.size(), &SILERO_SETTINGS, &result, &error) == 0);
        CheckSileroCleared(result);
        CheckSileroError(error);
      });
  WaitForSileroFeed();
  std::future<void> destruction;
  std::promise<void> started;
  if (stop_kind == StopKind::DestroyModel) {
    auto has_started = started.get_future();
    destruction =
        std::async(std::launch::async, [pointer = model.release(), &started] {
          started.set_value();
          omni_silero_destroy(pointer);
        });
    has_started.get();
    assert(destruction.wait_for(std::chrono::milliseconds(50)) ==
           std::future_status::timeout);
  } else {
    auto cancel = std::async(std::launch::async, [&] {
      if (stop_kind == StopKind::Request) {
        omni_silero_request_cancel(request.get());
      } else if (stop_kind == StopKind::DestroyRequest) {
        request.reset();
      } else {
        omni_silero_cancel(model.get());
      }
    });
    assert(cancel.wait_for(SILERO_BARRIER_TIMEOUT_SECONDS) ==
           std::future_status::ready);
    cancel.get();
  }
  {
    std::lock_guard<std::mutex> lock(backend.mutex);
    assert(backend.active_count == 1 && backend.destruction_count == 0);
  }
  ReleaseSileroFeed();
  inference.get();
  assert(backend.frames.size() == 1);
  if (destruction.valid()) {
    destruction.get();
    assert(backend.destruction_count == 1);
  } else if (stop_kind == StopKind::Model) {
    assert(omni_silero_stream_create(model.get(), nullptr) == nullptr);
    auto fresh = CreateSileroRequest();
    const float sample = 0.75f;
    OmniSileroResult result{};
    assert(omni_silero_speech_timestamps(model.get(), fresh.get(), &sample, 1,
                                         &SILERO_SETTINGS, &result,
                                         nullptr) == 0);
    CheckSileroCleared(result);
    assert(backend.frames.size() == 1);
  } else {
    CheckSileroOfflineSuccess(model.get());
    assert(backend.load_count == 1);
  }
}

void StreamActiveCancel(bool finishing) {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  auto independent = CreateSileroStream(model.get());
  if (finishing) {
    CheckSileroPush(stream.get(), 1, 511, 0, {});
  } else {
  }
  SileroState().block_feed = true;
  auto inference = std::async(std::launch::async, [&] {
    OmniSileroStreamResult result{};
    char *error = nullptr;
    if (finishing) {
      assert(omni_silero_stream_finish(stream.get(), &result, &error) == 0);
    } else {
      const std::vector<float> samples(1536, 0.25f);
      uint64_t accepted_sequence = UINT64_MAX;
      assert(omni_silero_stream_push(stream.get(), 1, samples.data(),
                                     samples.size(), &accepted_sequence,
                                     &result, &error) == 0);
      assert(accepted_sequence == 0);
    }
    CheckSileroCleared(result);
    CheckSileroError(error);
  });
  WaitForSileroFeed();
  auto cancellation = std::async(std::launch::async, [&] {
    omni_silero_stream_cancel(stream.get());
    omni_silero_stream_cancel(stream.get());
  });
  assert(cancellation.wait_for(SILERO_BARRIER_TIMEOUT_SECONDS) ==
         std::future_status::ready);
  cancellation.get();
  std::promise<void> started;
  auto has_started = started.get_future();
  auto drain = std::async(std::launch::async, [&] {
    started.set_value();
    CheckSileroDrain(stream.get());
  });
  has_started.get();
  assert(drain.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  ReleaseSileroFeed();
  inference.get();
  drain.get();
  assert(SileroState().frames.size() == 1);
  assert(SileroState().live_array_count == 1);
  CheckSileroPushRejected(stream.get(), finishing ? 2 : 1);
  OmniSileroStreamResult result{};
  assert(omni_silero_stream_finish(stream.get(), &result, nullptr) == 0);
  CheckSileroDrain(stream.get());
  CheckSileroPush(independent.get(), 1, 512, 512, {0.25f});
  CheckSileroOfflineSuccess(model.get());
}

void StreamModelStop(bool destroy_model) {
  auto model = CreateSileroModel();
  auto first = CreateSileroStream(model.get());
  auto second = CreateSileroStream(model.get());
  CheckSileroPush(second.get(), 1, 512, 512, {0.25f});
  SileroState().block_feed = true;
  auto inference = std::async(std::launch::async, [&] {
    const std::vector<float> samples(1024, 0.25f);
    uint64_t accepted_sequence = UINT64_MAX;
    OmniSileroStreamResult result{};
    assert(omni_silero_stream_push(first.get(), 1, samples.data(),
                                   samples.size(), &accepted_sequence, &result,
                                   nullptr) == 0);
    assert(accepted_sequence == 0);
    CheckSileroCleared(result);
  });
  WaitForSileroFeed();
  std::future<void> destruction;
  std::promise<void> started;
  if (destroy_model) {
    auto has_started = started.get_future();
    destruction = std::async(std::launch::async, [&] {
      started.set_value();
      char *error = nullptr;
      assert(omni_silero_destroy_checked(model.get(), &error) == 0);
      CheckSileroError(error);
    });
    has_started.get();
    assert(destruction.wait_for(std::chrono::milliseconds(50)) ==
           std::future_status::timeout);
  } else {
    omni_silero_cancel(model.get());
    omni_silero_cancel(model.get());
  }
  ReleaseSileroFeed();
  inference.get();
  if (destruction.valid()) {
    destruction.get();
    assert(SileroState().live_array_count >= 1);
  } else {
    assert(omni_silero_stream_create(model.get(), nullptr) == nullptr);
  }
  assert(SileroState().destruction_count == 0);
  assert(SileroState().frames.size() == 2);
  CheckSileroPushRejected(first.get());
  CheckSileroPushRejected(second.get(), 2);
  CheckSileroDrain(first.get());
  CheckSileroDrain(second.get());
  first.reset();
  assert(SileroState().destruction_count == 0);
  second.reset();
  model.reset();
  assert(SileroState().destruction_count == 1);
}

void QueuedStreamCancel() {
  auto model = CreateSileroModel();
  auto first = CreateSileroStream(model.get());
  auto second = CreateSileroStream(model.get());
  SileroState().block_feed = true;
  auto running = std::async(std::launch::async, [&] {
    CheckSileroPush(first.get(), 1, 512, 512, {0.25f});
  });
  WaitForSileroFeed();
  std::promise<void> started;
  auto has_started = started.get_future();
  auto queued = std::async(std::launch::async, [&] {
    started.set_value();
    CheckSileroPushRejected(second.get());
  });
  has_started.get();
  omni_silero_stream_cancel(second.get());
  ReleaseSileroFeed();
  running.get();
  queued.get();
  assert(SileroState().frames.size() == 1);
  CheckSileroDrain(second.get());
  CheckSileroPush(first.get(), 2, 512, 1024, {0.375f});
  CheckSileroOfflineSuccess(model.get());
}

void QueuedOfflineCancel() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  auto request = CreateSileroRequest();
  SileroState().block_feed = true;
  auto running = std::async(std::launch::async, [&] {
    CheckSileroPush(stream.get(), 1, 512, 512, {0.25f});
  });
  WaitForSileroFeed();
  std::promise<void> started;
  auto has_started = started.get_future();
  auto waiting = std::async(std::launch::async, [&] {
    const float sample = 0.75f;
    OmniSileroResult result{};
    char *error = nullptr;
    started.set_value();
    assert(omni_silero_speech_timestamps(model.get(), request.get(), &sample, 1,
                                         &SILERO_SETTINGS, &result,
                                         &error) == 0);
    CheckSileroCleared(result);
    CheckSileroError(error);
  });
  has_started.get();
  auto cancel = std::async(std::launch::async,
                           [&] { omni_silero_request_cancel(request.get()); });
  assert(cancel.wait_for(SILERO_BARRIER_TIMEOUT_SECONDS) ==
         std::future_status::ready);
  cancel.get();
  ReleaseSileroFeed();
  running.get();
  waiting.get();
  assert(SileroState().frames.size() == 1);
  CheckSileroOfflineSuccess(model.get());
  CheckSileroPush(stream.get(), 2, 512, 1024, {0.375f});
}

void CancelBeforeSubmission() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  omni_silero_stream_cancel(stream.get());
  omni_silero_stream_cancel(stream.get());
  CheckSileroPushRejected(stream.get());
  CheckSileroDrain(stream.get());
  assert(SileroState().frames.empty());
  CheckSileroOfflineSuccess(model.get());
  auto completed = CreateSileroStream(model.get());
  CheckSileroFinish(completed.get(), 0, {});
  omni_silero_stream_cancel(completed.get());
  CheckSileroFinish(completed.get(), 0, {});
  CheckSileroDrain(completed.get());
  auto unused = CreateSileroStream(model.get());
  omni_silero_cancel(model.get());
  CheckSileroPushRejected(unused.get());
  CheckSileroDrain(unused.get());
}

void CheckedDestructionFailures() {
  assert(omni_silero_destroy_checked(nullptr, nullptr) == 1);
  assert(omni_silero_stream_destroy_checked(nullptr, nullptr) == 1);
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  CheckSileroPush(stream.get(), 1, 512, 512, {0.25f});
  char *error = nullptr;
  assert(omni_silero_destroy_checked(model.get(), &error) == 0);
  CheckSileroError(error);
  const auto live_arrays = SileroState().live_array_count;
  State().synchronize_failure_after = 0;
  assert(omni_silero_stream_destroy_checked(stream.get(), &error) == 0);
  CheckSileroError(error);
  assert(SileroState().live_array_count == live_arrays);
  State().synchronize_failure_after = 1;
  assert(omni_silero_stream_destroy_checked(stream.get(), &error) == 0);
  CheckSileroError(error);
  assert(omni_silero_destroy_checked(model.get(), &error) == 0);
  CheckSileroError(error);
  assert(omni_silero_stream_destroy_checked(stream.get(), &error) == 1);
  assert(error == nullptr);
  stream.release();
  State().synchronize_failure_after = 0;
  assert(omni_silero_destroy_checked(model.get(), &error) == 0);
  CheckSileroError(error);
  assert(SileroState().destruction_count == 0);
  State().synchronize_failure_after = 1;
  assert(omni_silero_destroy_checked(model.get(), &error) == 0);
  CheckSileroError(error);
  assert(omni_silero_stream_create(model.get(), &error) == nullptr);
  CheckSileroError(error);
  assert(omni_silero_destroy_checked(model.get(), &error) == 1);
  assert(error == nullptr);
  model.release();
  assert(SileroState().destruction_count == 1);
}

void CheckedConstructorFailures() {
  auto &backend = SileroState();
  for (Failure failure : {Failure::kStandard, Failure::kNonstandard}) {
    backend.load_failure = failure;
    State().synchronize_failure_after = SYNCHRONIZE_ALWAYS_FAIL;
    OmniSileroHandle *model = nullptr;
    char *error = nullptr;
    assert(omni_silero_create_checked(std::filesystem::current_path().c_str(),
                                      &model, &error) == 0);
    CheckSileroError(error);
    assert(model != nullptr);
    assert(backend.live_array_count == 0);
    assert(backend.pending_constructor_work_count == 1);
    assert(backend.pending_constructor_cache_count == 1);
    assert(omni_silero_stream_create(model, &error) == nullptr);
    CheckSileroError(error);
    auto request = CreateSileroRequest();
    const std::vector<float> samples(512, 0.75f);
    OmniSileroResult result{};
    assert(omni_silero_speech_timestamps(model, request.get(), samples.data(),
                                         samples.size(), &SILERO_SETTINGS,
                                         &result, &error) == 0);
    CheckSileroError(error);
    CheckSileroCleared(result);
    assert(backend.frames.empty());
    for (int i = 0; i < 3; ++i) {
      const int attempts = backend.synchronize_attempt_count;
      assert(omni_silero_destroy_checked(model, &error) == 0);
      CheckSileroError(error);
      assert(backend.synchronize_attempt_count == attempts + 1);
      assert(backend.pending_constructor_work_count == 1);
      assert(backend.pending_constructor_cache_count == 1);
    }
    State().synchronize_failure_after = -1;
    backend.fail_cache_clear = true;
    for (int i = 0; i < 2; ++i) {
      const int attempts = backend.cache_clear_attempt_count;
      assert(omni_silero_destroy_checked(model, &error) == 0);
      CheckSileroError(error);
      assert(backend.cache_clear_attempt_count == attempts + 1);
      assert(backend.pending_constructor_work_count == 0);
      assert(backend.pending_constructor_cache_count == 1);
    }
    backend.fail_cache_clear = false;
    State().synchronize_failure_after = 1;
    assert(omni_silero_destroy_checked(model, &error) == 0);
    CheckSileroError(error);
    assert(backend.pending_constructor_cache_count == 0);
    assert(omni_silero_destroy_checked(model, &error) == 1);
    assert(error == nullptr);
  }
  backend.load_failure = Failure::kNone;
  OmniSileroHandle *model = nullptr;
  assert(omni_silero_create_checked(std::filesystem::current_path().c_str(),
                                    &model, nullptr) == 1);
  assert(model != nullptr);
  CheckSileroOfflineSuccess(model);
  assert(omni_silero_destroy_checked(model, nullptr) == 1);
}

void LegacyConstructorRetirementFailure() {
  auto &backend = SileroState();
  backend.load_failure = Failure::kStandard;
  State().synchronize_failure_after = SYNCHRONIZE_ALWAYS_FAIL;
  char *error = nullptr;
  assert(omni_silero_create(std::filesystem::current_path().c_str(), &error) ==
         nullptr);
  CheckSileroError(error);
  assert(backend.live_array_count == 0);
  assert(backend.synchronize_attempt_count == 1);
  assert(backend.pending_constructor_work_count == 1);
  assert(backend.pending_constructor_cache_count == 1);
}

void CheckedStreamWaitsForCalls() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  SileroState().block_feed = true;
  auto *pointer = stream.get();
  auto feeding = std::async(std::launch::async, [pointer] {
    const std::vector<float> samples(512, 0.25f);
    uint64_t accepted_sequence = 0;
    OmniSileroStreamResult result{};
    assert(omni_silero_stream_push(pointer, 1, samples.data(), samples.size(),
                                   &accepted_sequence, &result, nullptr) == 0);
    CheckSileroCleared(result);
  });
  WaitForSileroFeed();
  std::promise<void> started;
  auto has_started = started.get_future();
  auto destroying = std::async(std::launch::async, [&] {
    started.set_value();
    assert(omni_silero_stream_destroy_checked(pointer, nullptr) == 1);
  });
  has_started.get();
  assert(destroying.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  // Note (OpenAI): cancellation must remain safe while destroy waits for Feed.
  omni_silero_stream_cancel(pointer);
  ReleaseSileroFeed();
  feeding.get();
  destroying.get();
  stream.release();
  assert(SileroState().live_array_count == 1);
}

} // namespace

void RunSileroLifecycleCase(const std::string &test) {
  if (test == "silero_lifecycle_request_cancel") {
    OfflineActiveStop(StopKind::Request);
  } else if (test == "silero_lifecycle_request_destroy") {
    OfflineActiveStop(StopKind::DestroyRequest);
  } else if (test == "silero_lifecycle_offline_model_cancel") {
    OfflineActiveStop(StopKind::Model);
  } else if (test == "silero_lifecycle_offline_model_destroy") {
    OfflineActiveStop(StopKind::DestroyModel);
  } else if (test == "silero_lifecycle_stream_cancel") {
    StreamActiveCancel(false);
  } else if (test == "silero_lifecycle_finish_cancel") {
    StreamActiveCancel(true);
  } else if (test == "silero_lifecycle_stream_model_cancel") {
    StreamModelStop(false);
  } else if (test == "silero_lifecycle_stream_model_destroy") {
    StreamModelStop(true);
  } else if (test == "silero_lifecycle_queued_cancel") {
    QueuedStreamCancel();
  } else if (test == "silero_lifecycle_queued_offline_cancel") {
    QueuedOfflineCancel();
  } else if (test == "silero_lifecycle_cancel_before") {
    CancelBeforeSubmission();
  } else if (test == "silero_lifecycle_checked_failures") {
    CheckedDestructionFailures();
  } else if (test == "silero_lifecycle_constructor_retry") {
    CheckedConstructorFailures();
  } else if (test == "silero_lifecycle_constructor_legacy") {
    LegacyConstructorRetirementFailure();
  } else if (test == "silero_lifecycle_checked_wait") {
    CheckedStreamWaitsForCalls();
  } else {
    assert(false && "Unknown Silero lifecycle test");
  }
}

} // namespace omni_test
