// SPDX-License-Identifier: Apache-2.0
#include "engine_support.h"

#include <limits>

namespace speaker_test {
nlohmann::ordered_json engine_case(Family family, const std::string &name) {
  using namespace qwen3_asr;
  EngineFixture fixture(family);
  auto &script = fixture.script;
  if (name == "mapping") {
    require(
        SpeakerRealtimeEventJson(SpeakerRealtimeUpdated{}) ==
            nlohmann::ordered_json{{"type", "transcription_session.updated"}},
        "Updated mapping changed");
    const auto absent =
        SpeakerRealtimeEventJson(SpeakerRealtimeSegment{2, "", false});
    const auto empty = SpeakerRealtimeEventJson(
        SpeakerRealtimeSegment{2, "", true, std::vector<SpeakerSegment>{}});
    require(!absent.contains("segments") && empty.at("segments").empty(),
            "Absent versus empty segments lost");
    const auto error = SpeakerRealtimeEventJson(SpeakerRealtimeFailure{});
    require(error.at("error").at("type") == "server_error" &&
                error.at("error").at("code") == "transcription_failed" &&
                error.at("error").at("message") == "Transcription failed.",
            "Failure schema changed");
    script.steps = {{result("preview")}, {result("final", 17.0)}};
    fixture.append(samples(family == Family::kMoss ? 20000 : 3));
    drain(fixture.worker);
    fixture.finish();
    const auto events = fixture.snapshot();
    require(events.size() == 3, "Missing typed events");
    const auto &preview = std::get<SpeakerRealtimeSegment>(events[0]);
    const auto &final = std::get<SpeakerRealtimeSegment>(events[1]);
    const auto &completed = std::get<SpeakerRealtimeCompleted>(events[2]);
    require(!preview.is_final && !preview.segments.has_value(),
            "Preview mapping");
    require(final.is_final && final.segments.has_value(), "Final mapping");
    const auto &segment = final.segments->at(0);
    require(segment.start_seconds == 17.125 && segment.end_seconds == 17.875 &&
                segment.speaker == "S03" && segment.language == "en-US" &&
                segment.emotion == "neutral" && segment.event == "speech",
            "Segment metadata lost");
    require(completed.text == "final" && completed.segments.size() == 2,
            "Completed mapping");
    const auto serialized = SpeakerRealtimeEventJson(events[1]);
    require(serialized.at("segments")[0].at("language") == "en-US" &&
                !serialized.at("segments")[1].contains("language"),
            "Optional metadata mapping");
  } else if (name == "float_samples") {
    const std::vector<float> audio = {0.1234567f, -0.9876543f, 1.000001f,
                                      -1.000001f};
    script.steps = {{result("first")}, {result("final")}};
    fixture.append({});
    require(script.snapshot().empty(), "Empty append was not a no-op");
    fixture.append(audio);
    drain(fixture.worker);
    fixture.finish();
    const auto calls = script.snapshot();
    const size_t decode_index = family == Family::kMoss ? 0 : 1;
    require(calls[decode_index].at("samples").get<std::vector<float>>() ==
                audio,
            "Typed samples were quantized or altered");
  } else if (name == "empty") {
    script.steps = {{result("")}};
    script.steps[0].result.segments.clear();
    fixture.append({});
    fixture.commit();
    fixture.finish();
    const auto events = fixture.snapshot();
    const auto &completed = std::get<SpeakerRealtimeCompleted>(events.back());
    require(completed.text.empty() && completed.segments.empty(),
            "Empty finish mapping");
  } else if (name == "construction_append" || name == "construction_finish") {
    script.fails_construction = true;
    if (name == "construction_append") {
      fixture.append(samples(3));
    } else {
    }
    fixture.finish();
    const auto events = fixture.snapshot();
    require(events.size() == 2 &&
                std::get<SpeakerRealtimeFailure>(events[0]).code ==
                    "transcription_failed" &&
                std::holds_alternative<SpeakerRealtimeCompleted>(events[1]),
            "Construction failure stranded command or leaked details");
  } else if (name == "failure" || name == "allocation_failure") {
    script.throws_bad_alloc = name == "allocation_failure";
    script.steps = {{result("PRIVATE"), true}, {result("PRIVATE"), true}};
    fixture.append(samples(family == Family::kMoss ? 20000 : 3));
    drain(fixture.worker);
    fixture.finish();
    const auto events = fixture.snapshot();
    const auto &failure = std::get<SpeakerRealtimeFailure>(events.front());
    require(failure.message == "Transcription failed." &&
                failure.code == "transcription_failed",
            "Failure leaked private details");
    require(std::holds_alternative<SpeakerRealtimeCompleted>(events.back()),
            "Failure suppressed legacy completed event");
  } else if (name == "settings") {
    if (family == Family::kMoss) {
      const auto engine =
          std::get<std::shared_ptr<moss::MossRealtimeEngine>>(fixture.engine);
      engine->UpdatePrompt("<|audio_pad|><|audio_pad|>");
      engine->UpdatePrompt("typed <|audio_pad|>");
      script.steps = {{result("final")}};
      fixture.append({0.25f});
      fixture.finish();
      require(script.snapshot()[0].at("prompt") == "typed <|audio_pad|>",
              "Prompt changed");
      require(std::get<SpeakerRealtimeFailure>(fixture.snapshot()[0]).code ==
                  "invalid_prompt",
              "Prompt validation");
    } else {
      const auto engine =
          std::get<std::shared_ptr<nemotron::NemotronRealtimeEngine>>(
              fixture.engine);
      engine->UpdateSettings("en-US", std::numeric_limits<double>::quiet_NaN());
      engine->UpdateSettings(" EN-us ", 120.0);
      script.steps = {{result("preview")}, {result("final")}};
      fixture.append({0.25f});
      drain(fixture.worker);
      engine->UpdateSettings(std::nullopt, -1.0);
      fixture.finish();
      const auto calls = script.snapshot();
      require(calls[0].at("language") == " EN-us " &&
                  calls[0].at("chunk_frames") == 1,
              "Language normalization or tie changed");
      const auto events = fixture.snapshot();
      require(std::get<SpeakerRealtimeFailure>(events[0]).code ==
                  "invalid_chunk",
              "NaN validation");
      require(std::get<SpeakerRealtimeFailure>(events[3]).code ==
                  "session_started",
              "Late update precedence");
    }
  } else if (name == "finish_once") {
    script.steps = {{result("first")}, {result("last")}};
    fixture.append(samples(3));
    drain(fixture.worker);
    fixture.commit();
    fixture.commit();
    fixture.finish();
    const auto count = fixture.snapshot().size();
    fixture.finish();
    fixture.commit();
    require(fixture.snapshot().size() == count,
            "Repeated finish published duplicate");
    const size_t call_count = script.snapshot().size();
    fixture.append(samples(3));
    drain(fixture.worker);
    require(script.snapshot().size() == call_count,
            "Post-finish audio decoded");
    const auto events = fixture.snapshot();
    if (family == Family::kNemotron) {
      require(events.size() == count + 1 &&
                  std::get<SpeakerRealtimeFailure>(events.back()).code ==
                      "session_finished",
              "Missing post-commit append error");
    } else {
      require(events.size() == count, "Post-finish Moss event");
    }
  } else {
    throw std::invalid_argument("Unknown typed case");
  }
  return {{"passed", name}};
}
} // namespace speaker_test
