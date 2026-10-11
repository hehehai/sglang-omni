// SPDX-License-Identifier: Apache-2.0
#include "support.h"

#include <chrono>
#include <limits>
#include <tuple>

#include "realtime_engine.h"

namespace qwen3_asr::realtime_test {
namespace {
struct EngineSession {
  Recording recording;
  CancelFlag cancel = NewCancelFlag();
  std::shared_ptr<RealtimeEngine> engine;
  bool should_close_from_sink = false;

  explicit EngineSession(RealtimeSettings settings = {100, 100, 100}) {
    engine = std::make_shared<RealtimeEngine>(
        recording.worker, recording.transcriber, settings,
        [this](const RealtimeEvent &event) {
          if (std::holds_alternative<RealtimeUpdated>(event)) {
            recording.record({"updated"});
          } else if (const auto *segment =
                         std::get_if<RealtimeSegment>(&event)) {
            recording.record({"segment", segment->segment_id, segment->text,
                              segment->is_final});
          } else if (const auto *completed =
                         std::get_if<RealtimeCompleted>(&event)) {
            recording.record({"completed", completed->text});
          } else {
            const auto &failure = std::get<RealtimeFailure>(event);
            recording.record(
                {"failure", failure.type, failure.code, failure.message});
          }
          if (should_close_from_sink) {
            engine->Close();
          } else {
          }
        },
        cancel);
  }

  ~EngineSession() {
    if (engine) {
      engine->Close();
    } else {
    }
    recording.script.release();
    recording.drain();
  }
};

void expect_events(const nlohmann::json &report,
                   const nlohmann::json &expected) {
  require(report.at("events") == expected,
          "Typed event mismatch: " + report.at("events").dump());
}

void float_samples() {
  EngineSession fixture;
  fixture.recording.script.steps = {{"float audio"}};
  const std::vector<float> samples = {-1.0f, 0.123456789f, 0.0f, 0.75f};
  fixture.engine->UpdateLanguage(" en ");
  fixture.engine->Append(samples);
  fixture.engine->Commit();
  fixture.engine->Finish();
  const auto report = fixture.recording.snapshot();
  expect_events(report, {{"updated"},
                         {"segment", 0, "float audio", true},
                         {"completed", "float audio"}});
  require(report["calls"][0]["samples"] == nlohmann::json(samples),
          "Direct float input was quantized or changed");
  require(report["calls"][0]["language"] == "English",
          "Language normalization");
}

void empty_silent() {
  EngineSession fixture({1, 1, 100});
  fixture.recording.script.steps = {{"edge"}, {"edge"}};
  fixture.engine->Append({});
  fixture.engine->Commit();
  fixture.engine->Append({0.0f, 0.000999f, -0.000999f});
  fixture.recording.drain();
  fixture.engine->Commit();
  fixture.engine->Append({-0.001f});
  fixture.recording.drain();
  fixture.engine->Finish();
  const auto report = fixture.recording.snapshot();
  expect_events(report, {{"segment", 0, "", true},
                         {"segment", 1, "edge", false},
                         {"segment", 1, "edge", true},
                         {"completed", "edge"}});
  for (const auto &call : report["calls"]) {
    require(call["samples"] == nlohmann::json(std::vector<float>{-0.001f}),
            "Silence must not reach the transcriber");
  }
}

void cadence_prefix() {
  EngineSession fixture({2, 2, 100});
  fixture.recording.script.steps = {{"first", "English"},
                                    {"retained abcdefgh"},
                                    {"retained abcdefgh"},
                                    {"final"}};
  fixture.engine->Append({0.0f, 0.0f});
  fixture.recording.drain();
  fixture.engine->Append({0.25f});
  fixture.recording.drain();
  fixture.engine->Append({0.5f});
  fixture.recording.drain();
  fixture.engine->Append({0.75f});
  fixture.recording.drain();
  fixture.engine->Append({1.0f, -1.0f});
  fixture.recording.drain();
  fixture.engine->Finish();
  const auto report = fixture.recording.snapshot();
  expect_events(report, {{"segment", 0, "first", false},
                         {"segment", 0, "retained abcdefgh", false},
                         {"segment", 0, "final", true},
                         {"completed", "final"}});
  const std::vector<float> samples = {0.0f,  0.0f, 0.25f, 0.5f,
                                      0.75f, 1.0f, -1.0f};
  const std::vector<size_t> sample_counts = {3, 5, 7, 7};
  for (size_t i = 0; i < sample_counts.size(); ++i) {
    require(report["calls"][i]["samples"] ==
                nlohmann::json(std::vector<float>(
                    samples.begin(), samples.begin() + sample_counts[i])),
            "Refresh cadence or cumulative audio changed");
    require(report["calls"][i]["prefix_text"] == (i < 2 ? "" : "retained abc"),
            "Prefix must start after two attempts with five-token rollback");
  }
  require(report["prefixes"].size() == 2,
          "Expected refresh and final prefix requests");
  for (const auto &prefix : report["prefixes"]) {
    require(prefix["rollback_token_count"] == 5, "Wrong rollback count");
    require(prefix["token_ids"] == report["calls"][2]["prefix_token_ids"],
            "Retained token IDs must reach decode options unchanged");
  }
}

void cuts_languages() {
  EngineSession fixture({100, 100, 3});
  fixture.recording.script.steps = {{"one"}, {"two"}, {"三"}, {"four"}};
  fixture.engine->UpdateLanguage("en");
  fixture.engine->Append({0.125f});
  fixture.engine->UpdateLanguage("zh");
  fixture.engine->Append({0.25f, 0.375f, 0.5f, 0.625f, 0.75f, 0.875f});
  fixture.engine->UpdateLanguage(std::nullopt);
  fixture.engine->Commit();
  fixture.engine->Append({1.0f});
  fixture.engine->Finish();
  const auto report = fixture.recording.snapshot();
  expect_events(report, {{"updated"},
                         {"updated"},
                         {"segment", 0, "one", true},
                         {"segment", 1, "two", true},
                         {"updated"},
                         {"segment", 2, "三", true},
                         {"segment", 3, "four", true},
                         {"completed", "one two三four"}});
  const nlohmann::json expected_audio = {
      {0.125, 0.25, 0.375}, {0.5, 0.625, 0.75}, {0.875}, {1.0}};
  const nlohmann::json expected_languages = {"English", "Chinese", "Chinese",
                                             nullptr};
  for (size_t i = 0; i < 4; ++i) {
    require(report["calls"][i]["samples"] == expected_audio[i],
            "Incorrect segment cut");
    require(report["calls"][i]["language"] == expected_languages[i],
            "Language snapshot changed");
  }
}

void failure() {
  EngineSession fixture({2, 2, 100});
  fixture.recording.script.steps = {
      {"", std::nullopt, true}, {"", std::nullopt, true}, {"survived"}};
  fixture.engine->Append({0.25f, 0.5f});
  fixture.recording.drain();
  fixture.engine->Commit();
  fixture.engine->Append({0.75f});
  fixture.engine->Finish();
  expect_events(fixture.recording.snapshot(),
                {{"failure", "server_error", "transcription_failed",
                  "Transcription failed."},
                 {"failure", "server_error", "transcription_failed",
                  "Transcription failed."},
                 {"segment", 1, "survived", true},
                 {"completed", "survived"}});
}

void blocked_preview(const std::string &case_name) {
  EngineSession fixture({2, 2, 100});
  fixture.recording.script.steps = {
      {"preview", "English", false, true, case_name == "late_success"}};
  if (case_name == "blocked_commit") {
    fixture.recording.script.steps.push_back({"final"});
  } else {
  }
  fixture.engine->Append({0.25f, 0.5f});
  fixture.recording.script.wait_for_calls(1);
  if (case_name == "blocked_commit") {
    std::promise<void> commit_started;
    auto started = commit_started.get_future();
    auto committed = std::async(std::launch::async, [&] {
      commit_started.set_value();
      fixture.engine->Commit();
    });
    started.get();
    fixture.recording.script.release();
    committed.get();
    fixture.engine->Finish();
    expect_events(fixture.recording.snapshot(),
                  {{"segment", 0, "preview", false},
                   {"segment", 0, "final", true},
                   {"completed", "final"}});
  } else {
    if (case_name == "destroy_active") {
      fixture.engine.reset();
    } else {
      fixture.engine->Close();
      fixture.engine->Close();
      fixture.engine->Append({0.75f, 1.0f});
      fixture.engine->UpdateLanguage("zh");
      fixture.engine->Commit();
      fixture.engine->Finish();
    }
    require(fixture.cancel->load(),
            "Close/destruction must cancel in-flight decode");
    fixture.recording.script.release();
    const auto report = fixture.recording.snapshot();
    expect_events(report, nlohmann::json::array());
    require(report["calls"][0]["cancelled"] == true,
            "Model did not observe cancellation");
  }
}

void close_during_finalization(bool should_finish) {
  EngineSession fixture({2, 2, 100});
  fixture.recording.script.steps = {
      {"late preview", "English", false, true, true}};
  fixture.engine->Append({0.25f, 0.5f});
  fixture.recording.script.wait_for_calls(1);
  std::promise<void> command_started;
  auto started = command_started.get_future();
  auto finalized = std::async(std::launch::async, [&] {
    command_started.set_value();
    if (should_finish) {
      fixture.engine->Finish();
    } else {
      fixture.engine->Commit();
    }
  });
  started.get();
  fixture.engine->Close();
  const bool returned_before_decode_release =
      finalized.wait_for(std::chrono::seconds(5)) == std::future_status::ready;
  fixture.recording.script.release();
  finalized.get();
  require(
      returned_before_decode_release,
      "Close must wake finalization without waiting for the model to drain");
  expect_events(fixture.recording.snapshot(), nlohmann::json::array());
}

void finish_once() {
  EngineSession fixture;
  fixture.recording.script.steps = {{"once"}};
  fixture.engine->Append({0.5f});
  fixture.engine->Finish();
  fixture.engine->Finish();
  fixture.engine->UpdateLanguage("en");
  fixture.engine->Append({0.75f});
  fixture.engine->Commit();
  fixture.engine->Finish();
  expect_events(fixture.recording.snapshot(),
                {{"segment", 0, "once", true}, {"completed", "once"}});
}

void sink_close() {
  EngineSession fixture({1, 1, 100});
  fixture.recording.script.steps = {{"last preview"}};
  fixture.should_close_from_sink = true;
  fixture.engine->Append({0.5f});
  fixture.recording.drain();
  fixture.engine->Finish();
  require(fixture.cancel->load(), "Sink Close must cancel without deadlock");
  expect_events(fixture.recording.snapshot(),
                {{"segment", 0, "last preview", false}});
}

void settings_join() {
  const auto settings = MakeRealtimeSettings(200, 100, 2.00001);
  require(settings.decode_interval_samples == 3200 &&
              settings.first_decode_samples == 1600 &&
              settings.max_segment_samples == 32000,
          "Settings conversion/truncation changed");
  require(MakeRealtimeSettings(1, 1, 0.0001).max_segment_samples == 1,
          "Fractional sample conversion must truncate");
  const double infinity = std::numeric_limits<double>::infinity();
  const double not_a_number = std::numeric_limits<double>::quiet_NaN();
  const int maximum = std::numeric_limits<int>::max();
  for (const auto &[interval_ms, first_ms, segment_seconds] :
       std::vector<std::tuple<int, int, double>>{{0, 1, 1},
                                                 {-1, 1, 1},
                                                 {1, 0, 1},
                                                 {1, -1, 1},
                                                 {1, 1, 0},
                                                 {1, 1, -1},
                                                 {1, 1, infinity},
                                                 {1, 1, not_a_number},
                                                 {1, 1, 0.000001},
                                                 {maximum, 1, 1},
                                                 {1, maximum, 1},
                                                 {1, 1, 1e20}}) {
    bool rejected = false;
    try {
      MakeRealtimeSettings(interval_ms, first_ms, segment_seconds);
    } catch (const std::invalid_argument &) {
      rejected = true;
    }
    require(rejected, "Unsafe settings accepted");
  }
  for (const RealtimeSettings invalid :
       {RealtimeSettings{0, 1, 1}, RealtimeSettings{1, 0, 1},
        RealtimeSettings{1, 1, 0}, RealtimeSettings{-1, 1, 1}}) {
    bool rejected = false;
    try {
      EngineSession fixture(invalid);
    } catch (const std::invalid_argument &) {
      rejected = true;
    }
    require(rejected, "Unsafe direct sample settings accepted");
  }
  require(JoinTranscriptParts({" hello ", "\t world", "　你好", "世界　",
                               "again"}) == "hello world你好世界again",
          "English/CJK join contract");
  require(JoinTranscriptParts({"", "\t", "　"}).empty(),
          "Whitespace-only join contract");
  require(JoinTranscriptParts({"a", "ไทย", "b", "မြန်မာ", "c", "ខ្មែរ", "d", "𠀀",
                               "e"}) == "aไทยbမြန်မာcខ្មែរd𠀀e",
          "Unspaced-script boundaries");
}
} // namespace

nlohmann::json run_engine_case(const std::string &case_name) {
  if (case_name == "float_samples") {
    float_samples();
  } else if (case_name == "empty_silent") {
    empty_silent();
  } else if (case_name == "cadence_prefix") {
    cadence_prefix();
  } else if (case_name == "cuts_languages") {
    cuts_languages();
  } else if (case_name == "failure") {
    failure();
  } else if (case_name == "blocked_commit" || case_name == "blocked_close" ||
             case_name == "late_success" || case_name == "destroy_active") {
    blocked_preview(case_name);
  } else if (case_name == "close_during_commit" ||
             case_name == "close_during_finish") {
    close_during_finalization(case_name == "close_during_finish");
  } else if (case_name == "finish_once") {
    finish_once();
  } else if (case_name == "sink_close") {
    sink_close();
  } else if (case_name == "settings_join") {
    settings_join();
  } else {
    throw std::invalid_argument("Unknown engine case: " + case_name);
  }
  return {{"passed", case_name}};
}
} // namespace qwen3_asr::realtime_test
