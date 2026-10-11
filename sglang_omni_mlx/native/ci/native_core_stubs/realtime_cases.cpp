// SPDX-License-Identifier: Apache-2.0
// Public realtime validation, identity, audio admission, and inference options.
#include "realtime_cases.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace omni_test {
namespace {

void Invalid() {
  RealtimeFixture fixture;
  const OmniQwenRealtimeSettings valid{10, 10, 100, 128};
  const std::string long_language(129, 'L');
  const std::string long_context(8193, 'C');
  for (const auto settings :
       std::vector<OmniQwenRealtimeSettings>{{0, 10, 100, 128},
                                             {-1, 10, 100, 128},
                                             {10, 0, 100, 128},
                                             {10, -1, 100, 128},
                                             {10, 10, 0, 128},
                                             {10, 10, -1, 128},
                                             {10, 10, 100, 0},
                                             {10, 10, 100, -1},
                                             {10, 10, 100, 4097},
                                             {480001, 10, 100, 128},
                                             {10, 480001, 100, 128},
                                             {10, 10, 480001, 128},
                                             {10, 10, 100, INT32_MAX}}) {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_realtime_create(fixture.model.get(), SESSION_ID, &settings,
                                     nullptr, nullptr, &error) == nullptr);
    CheckError(error, "Invalid realtime settings.");
  }
  struct InvalidCreate {
    OmniQwenHandle *model;
    uint64_t session_id;
    const OmniQwenRealtimeSettings *settings;
    const char *language;
    const char *context;
  };
  for (const auto &input : std::vector<InvalidCreate>{
           {nullptr, SESSION_ID, &valid, nullptr, nullptr},
           {fixture.model.get(), 0, &valid, nullptr, nullptr},
           {fixture.model.get(), SESSION_ID, nullptr, nullptr, nullptr},
           {fixture.model.get(), SESSION_ID, &valid, long_language.c_str(),
            nullptr},
           {fixture.model.get(), SESSION_ID, &valid, nullptr,
            long_context.c_str()}}) {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_realtime_create(input.model, input.session_id,
                                     input.settings, input.language,
                                     input.context, &error) == nullptr);
    CheckError(error, "Invalid realtime input.");
  }
  assert(omni_qwen_realtime_create(nullptr, 0, nullptr, nullptr, nullptr,
                                   nullptr) == nullptr);
  auto session = fixture.Create(valid);
  EventReader reader{session.get()};
  assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
  assert(!reader.Poll());
  for (auto *pointer :
       {static_cast<OmniQwenRealtime *>(nullptr), session.get()}) {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_realtime_poll(pointer, nullptr, &error) == -1);
    CheckError(error, "Invalid realtime input.");
  }
  OmniQwenRealtimeEvent event{};
  event.text = reinterpret_cast<char *>(1);
  char *error = reinterpret_cast<char *>(1);
  assert(omni_qwen_realtime_poll(nullptr, &event, &error) == -1);
  CheckCleared(event);
  CheckError(error, "Invalid realtime input.");
  assert(omni_qwen_realtime_finish(nullptr, &error) == 0);
  CheckError(error, "Invalid realtime input.");
  assert(omni_qwen_realtime_drain(nullptr, &error) == 0);
  CheckError(error, "Invalid realtime input.");
  assert(omni_qwen_realtime_drain(session.get(), &error) == 0);
  CheckError(error, "Realtime session is not terminal.");
  assert(omni_qwen_realtime_finish(nullptr, nullptr) == 0);
  assert(omni_qwen_realtime_poll(nullptr, nullptr, nullptr) == -1);
  assert(omni_qwen_realtime_drain(nullptr, nullptr) == 0);
  omni_qwen_realtime_cancel(nullptr);
  omni_qwen_realtime_destroy(nullptr);
  omni_qwen_realtime_event_free(nullptr);
  Finish(session.get());
  CheckTerminal(reader, OMNI_QWEN_REALTIME_COMPLETED);
  assert(State().inference_count == 0);
}

void Sequence() {
  RealtimeFixture fixture;
  auto session = fixture.Create();
  float samples[] = {0.25f, -0.5f, 0.0f};
  struct InvalidPush {
    OmniQwenRealtime *session;
    uint64_t sequence;
    const float *samples;
    size_t sample_count;
    const char *expected_error = "Invalid realtime input.";
  };
  for (const auto &input : std::vector<InvalidPush>{
           {nullptr, 1, samples, 3},
           {session.get(), 0, samples, 3},
           {session.get(), 2, samples, 3, "Invalid audio sequence."},
           {session.get(), UINT64_MAX, samples, 3, "Invalid audio sequence."},
           {session.get(), 1, nullptr, 3},
           {session.get(), 1, samples, 0},
           {session.get(), 1, samples, 32001},
           {session.get(), 1, samples, std::numeric_limits<size_t>::max()}}) {
    uint64_t accepted_sequence = UINT64_MAX;
    char *error = reinterpret_cast<char *>(1);
    assert(omni_qwen_realtime_push(input.session, input.sequence, input.samples,
                                   input.sample_count, &accepted_sequence,
                                   &error) == 0);
    assert(accepted_sequence == 0);
    CheckError(error, input.expected_error);
  }
  for (const float nonfinite : {NAN, INFINITY, -INFINITY}) {
    for (size_t position = 0; position < 3; ++position) {
      std::vector<float> invalid_samples(3, AUDIBLE_SAMPLE);
      invalid_samples[position] = nonfinite;
      uint64_t accepted_sequence = UINT64_MAX;
      char *error = nullptr;
      assert(omni_qwen_realtime_push(session.get(), 1, invalid_samples.data(),
                                     3, &accepted_sequence, &error) == 0);
      assert(accepted_sequence == 0);
      CheckError(error, "Audio samples must be finite.");
    }
  }
  char *missing_ack_error = nullptr;
  assert(omni_qwen_realtime_push(session.get(), 1, samples, 3, nullptr,
                                 &missing_ack_error) == 0);
  CheckError(missing_ack_error, "Invalid realtime input.");
  assert(omni_qwen_realtime_push(nullptr, 0, nullptr, 0, nullptr, nullptr) ==
         0);
  uint64_t accepted_sequence = 0;
  assert(omni_qwen_realtime_push(session.get(), 1, samples, 3,
                                 &accepted_sequence, nullptr) == 1);
  assert(accepted_sequence == 1);
  samples[0] = 0.75f;
  for (uint64_t sequence : {UINT64_C(1), UINT64_C(3), UINT64_MAX}) {
    char *error = nullptr;
    assert(omni_qwen_realtime_push(session.get(), sequence, samples, 3,
                                   &accepted_sequence, &error) == 0);
    assert(accepted_sequence == 0);
    CheckError(error, "Invalid audio sequence.");
  }
  Push(session.get(), 2);
  Finish(session.get());
  const std::vector<float> expected{0.25f, -0.5f, 0.0f, AUDIBLE_SAMPLE};
  assert(State().samples == expected && State().inference_count == 1);
  EventReader reader{session.get()};
  const auto events = reader.All();
  assert(events.size() == 3 && events[0].kind == OMNI_QWEN_REALTIME_UPDATED);
  assert(events[1].kind == OMNI_QWEN_REALTIME_SEGMENT && events[1].is_final);
  assert(events[1].segment_id == 0);
  assert(events[2].kind == OMNI_QWEN_REALTIME_COMPLETED);
  assert(events[1].text == events[2].text);
  Finish(session.get());
  omni_qwen_realtime_cancel(session.get());
  assert(!reader.Poll());
  char *error = nullptr;
  assert(omni_qwen_realtime_push(session.get(), 3, samples, 3,
                                 &accepted_sequence, &error) == 0);
  assert(accepted_sequence == 0);
  CheckError(error, "Realtime session is completed.");
}

void OptionsAndPrefix() {
  RealtimeFixture fixture;
  std::string language(128, 'L');
  std::string context(8192, 'C');
  auto session = fixture.Create({1, 1, 100, 4096}, UINT64_MAX, language.c_str(),
                                context.c_str());
  language[0] = 'X';
  context[0] = 'X';
  EventReader reader{session.get(), UINT64_MAX};
  assert(reader.Wait().kind == OMNI_QWEN_REALTIME_UPDATED);
  State().scripted_texts = {"abcdefghij", "abcdefghijkl", "prefix refresh",
                            "final text"};
  for (uint64_t sequence = 1; sequence <= 3; ++sequence) {
    Push(session.get(), sequence);
    const auto preview = reader.Wait();
    assert(preview.kind == OMNI_QWEN_REALTIME_SEGMENT && !preview.is_final);
    assert(preview.segment_id == 0);
    std::lock_guard<std::mutex> lock(State().mutex);
    const auto &options = State().options;
    assert(options.context == std::string(8192, 'C'));
    assert(options.language ==
           (sequence == 1 ? std::string(128, 'L') : "English"));
    assert(options.max_new_tokens == 4096);
    assert(options.stop_at_end_of_text && options.stop_on_token_loop);
    assert(options.layout == qwen3_asr::AudioLayout::kVoxtSwift);
    if (sequence == 3) {
      assert(options.prefix_text == "abcdefg");
      assert(options.prefix_token_ids ==
             std::vector<int>({'a', 'b', 'c', 'd', 'e', 'f', 'g'}));
    } else {
      assert(options.prefix_text.empty() && options.prefix_token_ids.empty());
    }
  }
  Finish(session.get());
  assert(State().prefix_count == 2 && State().inference_count == 4);
  auto final_segment = reader.Wait();
  assert(final_segment.is_final && final_segment.text == "final text");
  assert(reader.Wait().text == "final text");
  assert(!reader.Poll());
  auto fresh = fixture.Create({10, 10, 100, 1}, 1, " ");
  Push(fresh.get(), 1);
  Finish(fresh.get());
  assert(!State().options.context && !State().options.language);
  assert(State().options.max_new_tokens == 1);
  assert(State().load_count == 1);
}

void TotalSamples() {
  RealtimeFixture fixture;
  auto session = fixture.Create({480000, 480000, 480000, 1});
  for (uint64_t sequence = 1; sequence <= 15; ++sequence) {
    Push(session.get(), sequence, 32000);
  }
  uint64_t accepted_sequence = UINT64_MAX;
  char *error = nullptr;
  assert(omni_qwen_realtime_push(session.get(), 16, &AUDIBLE_SAMPLE, 1,
                                 &accepted_sequence, &error) == 0);
  assert(accepted_sequence == 0);
  CheckError(error, "Realtime sample limit exceeded.");
  Finish(session.get());
  assert(State().inference_count == 1 && State().samples.size() == 480000);
  assert(State().inference_sample_counts == std::vector<size_t>{480000});
  assert(std::all_of(State().samples.begin(), State().samples.end(),
                     [](float sample) { return sample == AUDIBLE_SAMPLE; }));
  EventReader reader{session.get()};
  CheckTerminal(reader, OMNI_QWEN_REALTIME_COMPLETED);
  auto next = fixture.Create();
  Push(next.get(), 1);
  Finish(next.get());
  assert(State().inference_count == 2);
}

void Unicode() {
  RealtimeFixture fixture;
  auto session = fixture.Create({10, 10, 1, 128});
  State().scripted_texts = {"  hello\xE3\x80\x80", "world",
                            "\xE4\xBD\xA0\xE5\xA5\xBD", "again"};
  for (uint64_t sequence = 1; sequence <= 4; ++sequence) {
    Push(session.get(), sequence);
  }
  Finish(session.get());
  EventReader reader{session.get()};
  const auto events = reader.All();
  assert(events.size() == 6);
  for (int i = 0; i < 4; ++i) {
    assert(events[i + 1].kind == OMNI_QWEN_REALTIME_SEGMENT);
    assert(events[i + 1].segment_id == i && events[i + 1].is_final);
  }
  assert(events.back().text == "hello world\xE4\xBD\xA0\xE5\xA5\xBD"
                               "again");
}

} // namespace

void RunRealtimeCase(const std::string &test) {
  if (test == "realtime_invalid") {
    Invalid();
  } else if (test == "realtime_sequence") {
    Sequence();
  } else if (test == "realtime_options_prefix") {
    OptionsAndPrefix();
  } else if (test == "realtime_total_samples") {
    TotalSamples();
  } else if (test == "realtime_unicode") {
    Unicode();
  } else if (test == "realtime_ownership" || test == "realtime_failures" ||
             test == "realtime_poll_allocation" ||
             test == "realtime_refresh_allocation" ||
             test == "realtime_backpressure" ||
             test == "realtime_terminal_reserve" ||
             test == "realtime_text_limits" ||
             test == "realtime_transcript_limits") {
    RunRealtimeQueueCase(test);
  } else {
    RunRealtimeLifecycleCase(test);
  }
}

} // namespace omni_test
