// SPDX-License-Identifier: Apache-2.0
// Owned poll outputs and bounded queues, including retryable allocation
// failure.
#include "realtime_cases.h"

namespace omni_test {
namespace {

void Ownership() {
  RealtimeFixture fixture;
  auto session = fixture.Create();
  Push(session.get(), 1);
  Finish(session.get());
  EventReader reader{session.get()};
  assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
  OmniQwenRealtimeEvent segment{}, completed{};
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_realtime_poll(session.get(), &segment, &error) == 1);
  assert(error == nullptr && segment.text != nullptr &&
         segment.error_message == nullptr);
  assert(segment.kind == OMNI_QWEN_REALTIME_SEGMENT && segment.is_final == 1);
  assert(segment.session_id == SESSION_ID && segment.event_sequence == 2);
  assert(omni_qwen_realtime_poll(session.get(), &completed, nullptr) == 1);
  assert(completed.kind == OMNI_QWEN_REALTIME_COMPLETED);
  assert(completed.event_sequence == 3 && completed.session_id == SESSION_ID);
  assert(completed.text != nullptr && completed.error_message == nullptr);
  assert(std::strcmp(segment.text, completed.text) == 0 &&
         segment.text != completed.text);
  segment.text[0] = 'X';
  assert(completed.text[0] == 's');
  session.reset();
  fixture.model.reset();
  assert(State().destruction_count == 1);
  assert(segment.text[0] == 'X' && completed.text[0] == 's');
  omni_qwen_realtime_event_free(&segment);
  omni_qwen_realtime_event_free(&completed);
  CheckCleared(segment);
  CheckCleared(completed);
  omni_qwen_realtime_event_free(&completed);
}

void Failures() {
  RealtimeFixture fixture;
  for (const auto failure : {Failure::kStandard, Failure::kNonstandard}) {
    State().infer_failure = failure;
    auto session = fixture.Create({1, 1, 100, 128});
    EventReader reader{session.get()};
    assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
    Push(session.get(), 1);
    const auto failed = reader.Wait();
    assert(failed.kind == OMNI_QWEN_REALTIME_FAILED);
    assert(failed.error == "Realtime transcription failed.");
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_realtime_finish(session.get(), &error) == 0);
    CheckError(error, "Realtime session has failed.");
    assert(omni_qwen_realtime_drain(session.get(), &error) == 1 &&
           error == nullptr);
    omni_qwen_realtime_cancel(session.get());
    assert(!reader.Poll());
  }
  State().infer_failure = Failure::kNone;
  State().return_empty_text = true;
  for (float value : {0.0f, AUDIBLE_SAMPLE}) {
    auto empty = fixture.Create();
    Push(empty.get(), 1, 3, value);
    Finish(empty.get());
    EventReader reader{empty.get()};
    const auto events = reader.All();
    assert(events.size() == 3);
    assert(events[1].text == "" && events[2].text == "");
    assert(events[1].is_final &&
           events[2].kind == OMNI_QWEN_REALTIME_COMPLETED);
  }
  State().return_empty_text = false;
  fixture.Final();
}

void RefreshAllocation() {
#ifdef OMNI_ABI_WRAP_MALLOC
  RealtimeFixture fixture;
  State().scripted_texts.emplace_back(4097, 'x');
  auto session = fixture.Create({1, 1, 32000, 128});
  EventReader reader{session.get()};
  assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
  // Note (Codex): the scripted result moves; its first string copy occurs in
  // the worker completion.
  new_failure_byte_count = 4098;
  Push(session.get(), 1);
  const auto failed = reader.Wait();
  assert(failed.kind == OMNI_QWEN_REALTIME_FAILED);
  assert(failed.error && *failed.error == "Realtime transcription failed.");
  assert(new_failure_byte_count.load() == 0);
  assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
  assert(!reader.Poll());
  fixture.Final();
#endif
}

void PollAllocation() {
#ifdef OMNI_ABI_WRAP_MALLOC
  RealtimeFixture fixture;
  for (bool fails : {false, true}) {
    State().infer_failure = fails ? Failure::kStandard : Failure::kNone;
    auto session = fixture.Create();
    EventReader reader{session.get()};
    assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
    Push(session.get(), 1);
    char *error = nullptr;
    const int status = omni_qwen_realtime_finish(session.get(), &error);
    if (fails) {
      assert(status == 0);
      CheckError(error, "Realtime session has failed.");
    } else {
      assert(status == 1 && error == nullptr);
    }
    assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
    for (int i = 0; i < 2; ++i) {
      OmniQwenRealtimeEvent event{};
      event.session_id = 123;
      event.text = reinterpret_cast<char *>(1);
      event.error_message = reinterpret_cast<char *>(1);
      error = reinterpret_cast<char *>(1);
      State().malloc_failure_after = 0;
      assert(omni_qwen_realtime_poll(session.get(), &event, &error) == -1);
      CheckCleared(event);
      CheckError(error, "Realtime poll allocation failed.");
    }
    OmniQwenRealtimeEvent event{};
    assert(omni_qwen_realtime_poll(session.get(), &event, &error) == 1);
    assert(event.session_id == SESSION_ID && event.event_sequence == 2);
    assert(error == nullptr);
    if (fails) {
      assert(event.kind == OMNI_QWEN_REALTIME_FAILED && event.text == nullptr);
      assert(std::strcmp(event.error_message,
                         "Realtime transcription failed.") == 0);
      event.error_message[0] = 'X';
    } else {
      assert(event.kind == OMNI_QWEN_REALTIME_SEGMENT &&
             event.error_message == nullptr);
      assert(std::strcmp(event.text,
                         "stub transcript \xE4\xBD\xA0\xE5\xA5\xBD") == 0);
      OmniQwenRealtimeEvent completed{};
      State().malloc_failure_after = 0;
      assert(omni_qwen_realtime_poll(session.get(), &completed, nullptr) == -1);
      CheckCleared(completed);
      assert(omni_qwen_realtime_poll(session.get(), &completed, &error) == 1);
      assert(error == nullptr &&
             completed.kind == OMNI_QWEN_REALTIME_COMPLETED);
      assert(completed.session_id == SESSION_ID &&
             completed.event_sequence == 3);
      assert(std::strcmp(completed.text, event.text) == 0);
      omni_qwen_realtime_event_free(&completed);
    }
    session.reset();
    if (fails) {
      fixture.model.reset();
      assert(State().destruction_count == 1);
      assert(event.error_message[0] == 'X');
    } else {
      assert(event.text[0] == 's');
    }
    omni_qwen_realtime_event_free(&event);
    CheckCleared(event);
  }
  State().malloc_failure_after = 0;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_realtime_poll(nullptr, nullptr, &error) == -1 &&
         error == nullptr);
#endif
}

void Backpressure() {
  RealtimeFixture fixture;
  auto session = fixture.Create({10, 10, 1, 128});
  EventReader reader{session.get()};
  for (uint64_t sequence = 1; sequence <= 62; ++sequence) {
    Push(session.get(), sequence);
  }
  uint64_t accepted_sequence = UINT64_MAX;
  for (int i = 0; i < 2; ++i) {
    char *error = nullptr;
    assert(omni_qwen_realtime_push(session.get(), 63, &AUDIBLE_SAMPLE, 1,
                                   &accepted_sequence, &error) == 0);
    assert(accepted_sequence == 0);
    CheckError(error, "Realtime event queue backpressure.");
  }
  assert(State().inference_count == 62);
  assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
  Push(session.get(), 63);
  Finish(session.get());
  const auto events = reader.All();
  assert(events.size() == OMNI_QWEN_REALTIME_MAX_QUEUED_EVENTS);
  for (int i = 0; i < 63; ++i) {
    assert(events[i].kind == OMNI_QWEN_REALTIME_SEGMENT);
    assert(events[i].segment_id == i && events[i].is_final);
  }
  assert(events.back().kind == OMNI_QWEN_REALTIME_COMPLETED);
  assert(State().inference_count == 63);
  assert(State().inference_sample_counts == std::vector<size_t>(63, 1));
  auto fresh = fixture.Create();
  Push(fresh.get(), 1);
  Finish(fresh.get());
}

void TerminalReserve() {
  RealtimeFixture fixture;
  for (bool cancel : {false, true}) {
    auto session = fixture.Create({10, 10, 1, 128});
    EventReader reader{session.get()};
    if (cancel) {
      for (uint64_t sequence = 1; sequence <= 62; ++sequence) {
        Push(session.get(), sequence);
      }
      omni_qwen_realtime_cancel(session.get());
    } else {
      // Note (OpenAI): one accepted chunk may exceed the sink's bounded
      // capacity.
      Push(session.get(), 1, 100);
    }
    char *error = nullptr;
    assert(omni_qwen_realtime_finish(session.get(), &error) == 0);
    CheckError(error, cancel ? "Realtime session is cancelled."
                             : "Realtime session has failed.");
    assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
    const auto events = reader.All();
    assert(events.size() == OMNI_QWEN_REALTIME_MAX_QUEUED_EVENTS);
    assert(events.front().kind == OMNI_QWEN_REALTIME_UPDATED);
    for (int i = 1; i < 63; ++i) {
      assert(events[i].kind == OMNI_QWEN_REALTIME_SEGMENT);
      assert(events[i].segment_id == i - 1 && events[i].is_final);
    }
    if (cancel) {
      assert(events.back().kind == OMNI_QWEN_REALTIME_CANCELLED);
    } else {
      assert(events.back().kind == OMNI_QWEN_REALTIME_FAILED);
      assert(events.back().error == "Realtime event queue capacity exceeded.");
    }
    omni_qwen_realtime_cancel(session.get());
    assert(!reader.Poll());
  }
  fixture.Final();
}

void TranscriptLimits() {
  RealtimeFixture fixture;
  for (bool is_silent : {false, true}) {
    auto session = fixture.Create({1000, 1000, 1, 128});
    EventReader reader{session.get()};
    assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
    const size_t segment_count =
        is_silent ? OMNI_QWEN_REALTIME_MAX_FINAL_SEGMENTS : 1;
    for (size_t i = 0; i < segment_count; ++i) {
      if (!is_silent) {
        State().scripted_texts.emplace_back(
            OMNI_QWEN_REALTIME_MAX_TRANSCRIPT_BYTES, 'x');
      } else {
      }
      Push(session.get(), i + 1, 1, is_silent ? 0.0f : AUDIBLE_SAMPLE);
      assert(reader.Wait().kind == OMNI_QWEN_REALTIME_SEGMENT);
    }
    if (!is_silent) {
      State().scripted_texts.emplace_back("extra");
    } else {
    }
    Push(session.get(), segment_count + 1, 1,
         is_silent ? 0.0f : AUDIBLE_SAMPLE);
    CheckTerminal(reader, OMNI_QWEN_REALTIME_FAILED);
    assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
    assert(!reader.Poll());
  }
  fixture.Final();
}

void TextLimits() {
  RealtimeFixture fixture;
  for (const std::string &text :
       {std::string(OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES, 'x'),
        std::string(OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES + 1, 'x'),
        std::string("PRIVATE\0transcript", 18)}) {
    State().scripted_texts = {text};
    auto session = fixture.Create({10, 10, 1, 128});
    Push(session.get(), 1);
    EventReader reader{session.get()};
    assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
    const auto event = reader.Wait();
    if (text.size() == OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES) {
      assert(event.kind == OMNI_QWEN_REALTIME_SEGMENT && event.text == text);
      Finish(session.get());
      assert(reader.Wait().text == text);
    } else {
      assert(event.kind == OMNI_QWEN_REALTIME_FAILED && !event.text);
      assert(event.error == "Realtime event text exceeds output limits.");
      assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
    }
    assert(!reader.Poll());
  }
  auto session = fixture.Create({1, 1, 1000, 128});
  EventReader reader{session.get()};
  assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
  for (uint64_t sequence = 1; sequence <= 62; ++sequence) {
    {
      std::lock_guard<std::mutex> lock(State().mutex);
      State().scripted_texts = {std::string(
          OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES, sequence % 2 ? 'a' : 'b')};
    }
    Push(session.get(), sequence);
    // Note (OpenAI): a public final request fences the prior preview callback.
    fixture.Final();
  }
  State().scripted_texts = {
      std::string(OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES, 'c')};
  char *error = nullptr;
  assert(omni_qwen_realtime_finish(session.get(), &error) == 0);
  CheckError(error, "Realtime session has failed.");
  assert(omni_qwen_realtime_drain(session.get(), nullptr) == 1);
  const auto events = reader.All();
  assert(events.size() == OMNI_QWEN_REALTIME_MAX_QUEUED_EVENTS);
  size_t queued_string_bytes = 0;
  for (size_t i = 0; i + 1 < events.size(); ++i) {
    assert(events[i].kind == OMNI_QWEN_REALTIME_SEGMENT);
    assert(events[i].text->size() == OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES);
    queued_string_bytes += events[i].text->size() + 1;
  }
  assert(events.back().kind == OMNI_QWEN_REALTIME_FAILED);
  assert(events.back().error == "Realtime event queue capacity exceeded.");
  queued_string_bytes += events.back().error->size() + 1;
  assert(queued_string_bytes <= OMNI_QWEN_REALTIME_MAX_QUEUED_STRING_BYTES);
}

} // namespace

void RunRealtimeQueueCase(const std::string &test) {
  if (test == "realtime_ownership") {
    Ownership();
  } else if (test == "realtime_failures") {
    Failures();
  } else if (test == "realtime_poll_allocation") {
    PollAllocation();
  } else if (test == "realtime_refresh_allocation") {
    RefreshAllocation();
  } else if (test == "realtime_backpressure") {
    Backpressure();
  } else if (test == "realtime_terminal_reserve") {
    TerminalReserve();
  } else if (test == "realtime_text_limits") {
    TextLimits();
  } else if (test == "realtime_transcript_limits") {
    TranscriptLimits();
  } else {
    assert(false);
  }
}

} // namespace omni_test
