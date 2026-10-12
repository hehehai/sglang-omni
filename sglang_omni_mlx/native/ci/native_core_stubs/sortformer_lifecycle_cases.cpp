// SPDX-License-Identifier: Apache-2.0
#include "sortformer_cases.h"

namespace omni_test {
namespace {

void CancelBlockedFeed(bool cancel_model, bool destroy_model) {
  auto model = CreateSortformerModel();
  auto first = CreateSortformerStream(model.get());
  auto second = CreateSortformerStream(model.get());
  SortformerState().block_feed = true;
  auto running = std::async(std::launch::async,
                            [&] { CheckSortformerRejected(first.get()); });
  WaitForSortformerFeed();
  if (cancel_model || destroy_model) {
    omni_sortformer_cancel(model.get());
    omni_sortformer_cancel(model.get());
  } else {
    omni_sortformer_stream_cancel(first.get());
    omni_sortformer_stream_cancel(first.get());
  }
  auto draining = std::async(std::launch::async, [&] {
    if (destroy_model) {
      model.reset();
    } else {
      CheckSortformerDrain(first.get());
    }
  });
  assert(draining.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  {
    auto &backend = SortformerState();
    std::lock_guard<std::mutex> lock(backend.mutex);
    assert(backend.active_count == 1 && backend.destruction_count == 0);
    assert(backend.live_array_count > 3);
  }
  ReleaseSortformerFeed();
  running.get();
  draining.get();
  assert(omni_sortformer_stream_finish(first.get(), nullptr) == 0);
  CheckSortformerDrain(first.get());
  if (cancel_model || destroy_model) {
    CheckSortformerRejected(second.get());
    CheckSortformerDrain(second.get());
  } else {
    auto result = PushSortformer(second.get(), 1);
    omni_sortformer_result_free(&result);
    auto third = CreateSortformerStream(model.get());
    result = PushSortformer(third.get(), 1);
    omni_sortformer_result_free(&result);
  }
  if (destroy_model) {
    assert(SortformerState().live_array_count == 3);
    assert(SortformerState().destruction_count == 0);
    first.reset();
    assert(SortformerState().destruction_count == 0);
    second.reset();
    assert(SortformerState().destruction_count == 1);
  } else {
  }
}

void CancelQueued() {
  auto model = CreateSortformerModel();
  auto first = CreateSortformerStream(model.get());
  auto second = CreateSortformerStream(model.get());
  SortformerState().block_feed = true;
  auto running = std::async(std::launch::async, [&] {
    auto result = PushSortformer(first.get(), 1);
    omni_sortformer_result_free(&result);
  });
  WaitForSortformerFeed();
  std::promise<void> started;
  auto has_started = started.get_future();
  auto queued = std::async(std::launch::async, [&] {
    started.set_value();
    CheckSortformerRejected(second.get());
  });
  has_started.get();
  assert(queued.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  omni_sortformer_stream_cancel(second.get());
  ReleaseSortformerFeed();
  running.get();
  queued.get();
  assert(SortformerState().feed_count == 1);
  CheckSortformerDrain(second.get());
  auto result = PushSortformer(first.get(), 2);
  omni_sortformer_result_free(&result);
}

void FinishRace() {
  auto model = CreateSortformerModel();
  auto stream = CreateSortformerStream(model.get());
  SortformerState().block_feed = true;
  auto running = std::async(std::launch::async,
                            [&] { CheckSortformerRejected(stream.get()); });
  WaitForSortformerFeed();
  auto finishing = std::async(std::launch::async, [&] {
    assert(omni_sortformer_stream_finish(stream.get(), nullptr) == 0);
  });
  assert(finishing.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  omni_sortformer_stream_cancel(stream.get());
  ReleaseSortformerFeed();
  running.get();
  finishing.get();
  CheckSortformerDrain(stream.get());
  assert(omni_sortformer_stream_finish(stream.get(), nullptr) == 0);
  auto completed = CreateSortformerStream(model.get());
  assert(omni_sortformer_stream_finish(completed.get(), nullptr) == 1);
  omni_sortformer_stream_cancel(completed.get());
  model.reset();
  CheckSortformerDrain(completed.get());
  assert(omni_sortformer_stream_finish(completed.get(), nullptr) == 1);
}

void CreateCancellation() {
  auto model = CreateSortformerModel();
  auto &backend = SortformerState();
  backend.block_init = true;
  auto creating = std::async(std::launch::async, [&] {
    char *error = nullptr;
    assert(omni_sortformer_stream_create(model.get(), &SORTFORMER_SETTINGS,
                                         &error) == nullptr);
    CheckSortformerError(error);
  });
  {
    std::unique_lock<std::mutex> lock(backend.mutex);
    assert(backend.changed.wait_for(lock, std::chrono::seconds(5),
                                    [&] { return backend.init_count == 1; }));
  }
  omni_sortformer_cancel(model.get());
  {
    std::lock_guard<std::mutex> lock(backend.mutex);
    backend.release_init = true;
    backend.changed.notify_all();
  }
  creating.get();
  assert(backend.live_array_count == 3);
  assert(omni_sortformer_stream_create(model.get(), &SORTFORMER_SETTINGS,
                                       nullptr) == nullptr);
}

void CancelBeforeAndDestroyWaiting() {
  auto model = CreateSortformerModel();
  auto first = CreateSortformerStream(model.get());
  auto second = CreateSortformerStream(model.get());
  omni_sortformer_stream_cancel(first.get());
  CheckSortformerRejected(first.get());
  assert(omni_sortformer_stream_finish(first.get(), nullptr) == 0);
  CheckSortformerDrain(first.get());
  SortformerState().block_feed = true;
  auto running = std::async(std::launch::async, [&] {
    auto result = PushSortformer(second.get(), 1);
    omni_sortformer_result_free(&result);
  });
  WaitForSortformerFeed();
  auto destroying = std::async(std::launch::async, [&] { first.reset(); });
  assert(destroying.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  ReleaseSortformerFeed();
  running.get();
  destroying.get();
  assert(SortformerState().load_count == 1 &&
         SortformerState().destruction_count == 0);
  auto third = CreateSortformerStream(model.get());
  auto result = PushSortformer(third.get(), 1);
  omni_sortformer_result_free(&result);
}

void CheckedNullDestruction() {
  char *error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_destroy_checked(nullptr, &error) == 1);
  assert(error == nullptr);
  error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_stream_destroy_checked(nullptr, &error) == 1);
  assert(error == nullptr);
}

void CheckedModelDestruction() {
  auto model = CreateSortformerModel();
  auto stream = CreateSortformerStream(model.get());
  char *error = nullptr;
  assert(omni_sortformer_destroy_checked(model.get(), &error) == 0);
  CheckSortformerError(error);
  auto result = PushSortformer(stream.get(), 1);
  omni_sortformer_result_free(&result);
  error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_stream_destroy_checked(stream.get(), &error) == 1);
  assert(error == nullptr);
  (void)stream.release();
  error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_destroy_checked(model.get(), &error) == 1);
  assert(error == nullptr);
  (void)model.release();
  assert(SortformerState().live_array_count == 0);
  assert(SortformerState().destruction_count == 1);
}

void CheckedStreamDestructionWaits() {
  auto model = CreateSortformerModel();
  auto stream = CreateSortformerStream(model.get());
  SortformerState().block_feed = true;
  const auto native_stream = stream.get();
  auto running = std::async(std::launch::async,
                            [&] { CheckSortformerRejected(native_stream); });
  WaitForSortformerFeed();
  auto destroying = std::async(std::launch::async, [&] {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_sortformer_stream_destroy_checked(native_stream, &error) == 1);
    assert(error == nullptr);
  });
  assert(destroying.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  ReleaseSortformerFeed();
  running.get();
  destroying.get();
  (void)stream.release();
  assert(SortformerState().live_array_count == 3);
  assert(omni_sortformer_destroy_checked(model.get(), nullptr) == 1);
  (void)model.release();
  assert(SortformerState().live_array_count == 0);
}

} // namespace

void RunSortformerLifecycleCase(const std::string &test) {
  if (test == "sortformer_lifecycle_stream_cancel") {
    CancelBlockedFeed(false, false);
  } else if (test == "sortformer_lifecycle_model_cancel") {
    CancelBlockedFeed(true, false);
  } else if (test == "sortformer_lifecycle_model_destroy") {
    CancelBlockedFeed(false, true);
  } else if (test == "sortformer_lifecycle_queued_cancel") {
    CancelQueued();
  } else if (test == "sortformer_lifecycle_finish_cancel") {
    FinishRace();
  } else if (test == "sortformer_lifecycle_create_cancel") {
    CreateCancellation();
  } else if (test == "sortformer_lifecycle_cancel_before") {
    CancelBeforeAndDestroyWaiting();
  } else if (test == "sortformer_lifecycle_checked_null") {
    CheckedNullDestruction();
  } else if (test == "sortformer_lifecycle_checked_model") {
    CheckedModelDestruction();
  } else if (test == "sortformer_lifecycle_checked_stream_wait") {
    CheckedStreamDestructionWaits();
  } else {
    assert(false && "Unknown Sortformer lifecycle case");
  }
}

} // namespace omni_test
