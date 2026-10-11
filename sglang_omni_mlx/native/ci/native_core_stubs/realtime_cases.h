// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "omni_native_core.h"
#include "transcriber.h"

#include <cassert>
#include <chrono>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace omni_test {

inline constexpr uint64_t SESSION_ID = UINT64_C(0xfedcba9876543210);
inline constexpr std::chrono::seconds BARRIER_TIMEOUT_SECONDS{5};
inline constexpr float AUDIBLE_SAMPLE = 0.25f;
using Realtime =
    std::unique_ptr<OmniQwenRealtime, decltype(&omni_qwen_realtime_destroy)>;

inline void CheckError(char *error, const char *expected) {
  assert(error != nullptr && std::strcmp(error, expected) == 0);
  omni_string_free(error);
}

inline void CheckCleared(const OmniQwenRealtimeEvent &event) {
  assert(event.session_id == 0 && event.event_sequence == 0);
  assert(event.kind == 0 && event.segment_id == 0 && event.is_final == 0);
  assert(event.text == nullptr && event.error_message == nullptr);
}

struct RecordedEvent {
  OmniQwenRealtimeEventKind kind;
  int segment_id;
  bool is_final;
  std::optional<std::string> text;
  std::optional<std::string> error;
};

struct EventReader {
  OmniQwenRealtime *session;
  uint64_t session_id = SESSION_ID;
  uint64_t next_sequence = 1;

  std::optional<RecordedEvent> Poll() {
    OmniQwenRealtimeEvent event{};
    event.session_id = 123;
    event.event_sequence = 456;
    event.text = reinterpret_cast<char *>(1);
    event.error_message = reinterpret_cast<char *>(1);
    char *error = reinterpret_cast<char *>(1);
    const int status = omni_qwen_realtime_poll(session, &event, &error);
    assert(status >= 0 && error == nullptr);
    if (status == 0) {
      CheckCleared(event);
      return std::nullopt;
    } else {
      assert(event.session_id == session_id);
      assert(event.event_sequence == next_sequence++);
      RecordedEvent recorded{event.kind, event.segment_id, event.is_final != 0,
                             std::nullopt, std::nullopt};
      if (event.text != nullptr) {
        recorded.text = event.text;
      } else {
      }
      if (event.error_message != nullptr) {
        recorded.error = event.error_message;
      } else {
      }
      if (event.kind == OMNI_QWEN_REALTIME_SEGMENT ||
          event.kind == OMNI_QWEN_REALTIME_COMPLETED) {
        assert(recorded.text && !recorded.error);
      } else if (event.kind == OMNI_QWEN_REALTIME_FAILED) {
        assert(!recorded.text && recorded.error);
      } else {
        assert(!recorded.text && !recorded.error);
      }
      omni_qwen_realtime_event_free(&event);
      CheckCleared(event);
      omni_qwen_realtime_event_free(&event);
      return recorded;
    }
  }

  RecordedEvent Wait() {
    const auto deadline =
        std::chrono::steady_clock::now() + BARRIER_TIMEOUT_SECONDS;
    while (std::chrono::steady_clock::now() < deadline) {
      auto event = Poll();
      if (event) {
        return *event;
      } else {
        std::this_thread::yield();
      }
    }
    assert(false && "Timed out waiting for a public realtime event");
    std::abort();
  }

  std::vector<RecordedEvent> All() {
    std::vector<RecordedEvent> events;
    while (auto event = Poll()) {
      events.push_back(std::move(*event));
    }
    return events;
  }
};

struct RealtimeFixture {
  std::unique_ptr<OmniQwenHandle, decltype(&omni_qwen_destroy)> model{
      nullptr, &omni_qwen_destroy};

  RealtimeFixture() {
    char *error = reinterpret_cast<char *>(1);
    model.reset(
        omni_qwen_create(std::filesystem::current_path().c_str(), &error));
    assert(model && error == nullptr);
    assert(State().load_count == 1 && State().destruction_count == 0);
    assert(State().loading_thread != std::this_thread::get_id());
  }

  ~RealtimeFixture() {
    model.reset();
    assert(State().load_count == 1 && State().destruction_count == 1);
    assert(State().loading_thread == State().destruction_thread);
    assert(State().live_models.empty());
  }

  Realtime Create(OmniQwenRealtimeSettings settings = {1000, 1000, 32000, 128},
                  uint64_t session_id = SESSION_ID,
                  const char *language = nullptr,
                  const char *context = nullptr) {
    char *error = reinterpret_cast<char *>(1);
    Realtime session(omni_qwen_realtime_create(model.get(), session_id,
                                               &settings, language, context,
                                               &error),
                     &omni_qwen_realtime_destroy);
    assert(session && error == nullptr);
    return session;
  }

  void Final(const char *expected_error = nullptr) {
    OmniQwenResult result{};
    char *error = reinterpret_cast<char *>(1);
    const int status =
        omni_qwen_transcribe(model.get(), &AUDIBLE_SAMPLE, 1, nullptr, nullptr,
                             128, &result, &error);
    if (expected_error != nullptr) {
      assert(status == 0 && result.text == nullptr);
      CheckError(error, expected_error);
    } else {
      assert(status == 1 && result.text != nullptr && error == nullptr);
    }
    omni_qwen_result_free(&result);
  }
};

inline void Push(OmniQwenRealtime *session, uint64_t audio_sequence,
                 size_t sample_count = 1, float value = AUDIBLE_SAMPLE) {
  const std::vector<float> samples(sample_count, value);
  uint64_t accepted_sequence = UINT64_MAX;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_realtime_push(session, audio_sequence, samples.data(),
                                 samples.size(), &accepted_sequence,
                                 &error) == 1);
  assert(accepted_sequence == audio_sequence && error == nullptr);
}

inline void Finish(OmniQwenRealtime *session) {
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_realtime_finish(session, &error) == 1 && error == nullptr);
  assert(omni_qwen_realtime_drain(session, &error) == 1 && error == nullptr);
}

inline void WaitForInference(bool cancellation = false) {
  auto &state = State();
  std::unique_lock<std::mutex> lock(state.mutex);
  assert(state.changed.wait_for(lock, BARRIER_TIMEOUT_SECONDS, [&] {
    return cancellation ? state.cancellation_seen : state.active_count == 1;
  }));
}

inline void ReleaseInference() {
  auto &state = State();
  std::lock_guard<std::mutex> lock(state.mutex);
  state.release_inference = true;
  state.changed.notify_all();
}

inline void CheckTerminal(EventReader &reader, OmniQwenRealtimeEventKind kind) {
  const auto events = reader.All();
  assert(!events.empty() && events.back().kind == kind);
  size_t terminal_count = 0;
  for (const auto &event : events) {
    if (event.kind == OMNI_QWEN_REALTIME_COMPLETED ||
        event.kind == OMNI_QWEN_REALTIME_CANCELLED ||
        event.kind == OMNI_QWEN_REALTIME_FAILED) {
      ++terminal_count;
    } else {
      assert(event.kind == OMNI_QWEN_REALTIME_UPDATED ||
             event.kind == OMNI_QWEN_REALTIME_SEGMENT);
    }
  }
  assert(terminal_count == 1 && !reader.Poll());
}

} // namespace omni_test
