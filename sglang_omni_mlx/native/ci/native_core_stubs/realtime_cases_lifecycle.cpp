// SPDX-License-Identifier: Apache-2.0
// Cancellation and lease tests never race new calls against raw handle
// destruction.
#include "realtime_cases.h"

#include <barrier>
#include <future>

namespace omni_test {
namespace {

void CheckCancelled(OmniQwenRealtime *session) {
  uint64_t accepted_sequence = UINT64_MAX;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_realtime_push(session, 1, &AUDIBLE_SAMPLE, 1,
                                 &accepted_sequence, &error) == 0);
  assert(accepted_sequence == 0);
  CheckError(error, "Realtime session is cancelled.");
  assert(omni_qwen_realtime_finish(session, &error) == 0);
  CheckError(error, "Realtime session is cancelled.");
  assert(omni_qwen_realtime_drain(session, &error) == 1 && error == nullptr);
  assert(omni_qwen_realtime_drain(session, nullptr) == 1);
  EventReader reader{session};
  const auto events = reader.All();
  assert(events.size() == 2);
  assert(events.front().kind == OMNI_QWEN_REALTIME_UPDATED);
  assert(events.back().kind == OMNI_QWEN_REALTIME_CANCELLED);
  omni_qwen_realtime_cancel(session);
  assert(!reader.Poll());
}

void CheckReuse(RealtimeFixture &fixture) {
  fixture.Final();
  auto fresh = fixture.Create();
  Push(fresh.get(), 1);
  Finish(fresh.get());
  EventReader reader{fresh.get()};
  CheckTerminal(reader, OMNI_QWEN_REALTIME_COMPLETED);
  assert(State().load_count == 1 && State().destruction_count == 0);
}

void CancelBeforeSubmission() {
  RealtimeFixture fixture;
  auto cancelled = fixture.Create();
  omni_qwen_realtime_cancel(cancelled.get());
  omni_qwen_realtime_cancel(cancelled.get());
  CheckCancelled(cancelled.get());
  assert(State().inference_count == 0);
  CheckReuse(fixture);
  assert(State().inference_count == 2);
}

void CancelActive() {
  RealtimeFixture fixture;
  auto cancelled = fixture.Create({1, 1, 100, 128});
  auto independent = fixture.Create({1, 1, 1, 128}, 7);
  State().block_inference = true;
  State().ignores_cancellation = true;
  Push(cancelled.get(), 1);
  WaitForInference();
  omni_qwen_realtime_cancel(cancelled.get());
  WaitForInference(true);
  EventReader reader{cancelled.get()};
  CheckTerminal(reader, OMNI_QWEN_REALTIME_CANCELLED);
  auto drain = std::async(std::launch::async, [&] {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_realtime_drain(cancelled.get(), &error) == 1);
    assert(error == nullptr);
  });
  assert(drain.wait_for(std::chrono::seconds(0)) != std::future_status::ready);
  assert(State().destruction_count == 0);
  ReleaseInference();
  drain.get();
  assert(!reader.Poll());
  assert(State().inference_count == 1);
  Push(independent.get(), 1);
  Finish(independent.get());
  EventReader independent_reader{independent.get(), 7};
  CheckTerminal(independent_reader, OMNI_QWEN_REALTIME_COMPLETED);
  CheckReuse(fixture);
}

void Queued(bool destroy) {
  RealtimeFixture fixture;
  auto active = fixture.Create({1, 1, 100, 128});
  auto queued = fixture.Create({1, 1, 100, 128}, 2);
  auto independent = fixture.Create({1, 1, 100, 128}, 3);
  State().block_inference = true;
  Push(active.get(), 1);
  WaitForInference();
  Push(queued.get(), 1);
  Push(independent.get(), 1);
  assert(State().inference_count == 1);
  omni_qwen_realtime_cancel(queued.get());
  std::future<void> destruction;
  if (destroy) {
    destruction =
        std::async(std::launch::async, [session = std::move(queued)]() mutable {
          session.reset();
        });
    assert(destruction.wait_for(std::chrono::seconds(0)) !=
           std::future_status::ready);
  } else {
  }
  ReleaseInference();
  Finish(active.get());
  Finish(independent.get());
  if (destroy) {
    destruction.get();
  } else {
    assert(omni_qwen_realtime_drain(queued.get(), nullptr) == 1);
    EventReader reader{queued.get(), 2};
    CheckTerminal(reader, OMNI_QWEN_REALTIME_CANCELLED);
  }
  assert(State().inference_count == 4);
  EventReader active_reader{active.get()};
  EventReader independent_reader{independent.get(), 3};
  CheckTerminal(active_reader, OMNI_QWEN_REALTIME_COMPLETED);
  CheckTerminal(independent_reader, OMNI_QWEN_REALTIME_COMPLETED);
  CheckReuse(fixture);
}

void DestroyActive() {
  RealtimeFixture fixture;
  auto session = fixture.Create({1, 1, 100, 128});
  State().block_inference = true;
  State().ignores_cancellation = true;
  Push(session.get(), 1);
  WaitForInference();
  auto destruction =
      std::async(std::launch::async,
                 [session = std::move(session)]() mutable { session.reset(); });
  WaitForInference(true);
  assert(destruction.wait_for(std::chrono::seconds(0)) !=
         std::future_status::ready);
  assert(State().destruction_count == 0);
  ReleaseInference();
  destruction.get();
  assert(State().inference_count == 1 && State().active_count == 0);
  CheckReuse(fixture);
}

void ModelStop(bool destroy) {
  RealtimeFixture fixture;
  auto active = fixture.Create({1, 1, 100, 128});
  auto queued = fixture.Create({1, 1, 100, 128}, 2);
  auto idle = fixture.Create({1, 1, 100, 128}, 3);
  State().block_inference = true;
  State().ignores_cancellation = true;
  Push(active.get(), 1);
  WaitForInference();
  Push(queued.get(), 1);
  std::future<void> destruction;
  if (destroy) {
    destruction = std::async(
        std::launch::async,
        [model = std::move(fixture.model)]() mutable { model.reset(); });
  } else {
    omni_qwen_cancel(fixture.model.get());
    omni_qwen_cancel(fixture.model.get());
  }
  WaitForInference(true);
  if (destroy) {
    assert(destruction.wait_for(std::chrono::seconds(0)) !=
           std::future_status::ready);
  } else {
  }
  assert(State().destruction_count == 0);
  ReleaseInference();
  if (destroy) {
    destruction.get();
  } else {
    fixture.Final("Transcription cancelled.");
    char *error = nullptr;
    const OmniQwenRealtimeSettings settings{1, 1, 100, 128};
    assert(omni_qwen_realtime_create(fixture.model.get(), 4, &settings, nullptr,
                                     nullptr, &error) == nullptr);
    CheckError(error, "Transcription cancelled.");
  }
  for (auto *session : {active.get(), queued.get(), idle.get()}) {
    uint64_t accepted_sequence = UINT64_MAX;
    char *error = nullptr;
    assert(omni_qwen_realtime_push(session, 2, &AUDIBLE_SAMPLE, 1,
                                   &accepted_sequence, &error) == 0);
    assert(accepted_sequence == 0);
    CheckError(error, "Realtime session is cancelled.");
    assert(omni_qwen_realtime_finish(session, &error) == 0);
    CheckError(error, "Realtime session is cancelled.");
    assert(omni_qwen_realtime_drain(session, &error) == 1 && error == nullptr);
  }
  EventReader active_reader{active.get()};
  EventReader queued_reader{queued.get(), 2};
  EventReader idle_reader{idle.get(), 3};
  CheckTerminal(active_reader, OMNI_QWEN_REALTIME_CANCELLED);
  CheckTerminal(queued_reader, OMNI_QWEN_REALTIME_CANCELLED);
  CheckTerminal(idle_reader, OMNI_QWEN_REALTIME_CANCELLED);
  assert(State().inference_count == 1 && State().destruction_count == 0);
  active.reset();
  queued.reset();
  assert(State().destruction_count == 0);
  // Note (OpenAI): ABI3 deliberately releases a destroyed model at its last
  // lease.
  idle.reset();
  assert(State().destruction_count == (destroy ? 1 : 0));
}

void FinishCancelRace() {
  RealtimeFixture fixture;
  auto blocked = fixture.Create();
  Push(blocked.get(), 1);
  State().block_inference = true;
  State().ignores_cancellation = true;
  auto finishing = std::async(std::launch::async, [&] {
    char *error = nullptr;
    assert(omni_qwen_realtime_finish(blocked.get(), &error) == 0);
    CheckError(error, "Realtime session is cancelled.");
  });
  WaitForInference();
  omni_qwen_realtime_cancel(blocked.get());
  WaitForInference(true);
  ReleaseInference();
  finishing.get();
  CheckCancelled(blocked.get());
  for (int i = 0; i < 32; ++i) {
    auto session = fixture.Create();
    std::barrier start(3);
    auto finish = std::async(std::launch::async, [&] {
      start.arrive_and_wait();
      char *error = nullptr;
      const int status = omni_qwen_realtime_finish(session.get(), &error);
      if (status == 0) {
        CheckError(error, "Realtime session is cancelled.");
      } else {
        assert(status == 1 && error == nullptr);
      }
      return status;
    });
    auto cancel = std::async(std::launch::async, [&] {
      start.arrive_and_wait();
      omni_qwen_realtime_cancel(session.get());
    });
    start.arrive_and_wait();
    const int status = finish.get();
    cancel.get();
    assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
    EventReader reader{session.get()};
    CheckTerminal(reader, status == 1 ? OMNI_QWEN_REALTIME_COMPLETED
                                      : OMNI_QWEN_REALTIME_CANCELLED);
  }
  auto completed = fixture.Create();
  Finish(completed.get());
  omni_qwen_realtime_cancel(completed.get());
  Finish(completed.get());
  EventReader reader{completed.get()};
  CheckTerminal(reader, OMNI_QWEN_REALTIME_COMPLETED);
  CheckReuse(fixture);
}

} // namespace

void RunRealtimeLifecycleCase(const std::string &test) {
  if (test == "realtime_cancel_before_submission") {
    CancelBeforeSubmission();
  } else if (test == "realtime_cancel_active") {
    CancelActive();
  } else if (test == "realtime_cancel_queued") {
    Queued(false);
  } else if (test == "realtime_destroy_active") {
    DestroyActive();
  } else if (test == "realtime_destroy_queued") {
    Queued(true);
  } else if (test == "realtime_model_cancel") {
    ModelStop(false);
  } else if (test == "realtime_model_destroy") {
    ModelStop(true);
  } else if (test == "realtime_finish_cancel_race") {
    FinishCancelRace();
  } else {
    assert(false);
  }
}

} // namespace omni_test
