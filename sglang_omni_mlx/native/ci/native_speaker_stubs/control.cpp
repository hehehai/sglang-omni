// SPDX-License-Identifier: Apache-2.0
#include "moss_realtime_engine.h"
#include "nemotron_realtime_engine.h"
#include <iostream>
namespace {
nlohmann::ordered_json
typed_event(const qwen3_asr::SpeakerRealtimeEvent &event) {
  const std::string *text = nullptr;
  const std::vector<qwen3_asr::SpeakerSegment> *segments = nullptr;
  int kind = 1;
  int segment_id = 0;
  int is_final = 0;
  if (const auto *segment =
          std::get_if<qwen3_asr::SpeakerRealtimeSegment>(&event)) {
    kind = 2;
    segment_id = segment->segment_id;
    is_final = segment->is_final;
    text = &segment->text;
    segments = segment->segments ? &*segment->segments : nullptr;
  } else if (const auto *completed =
                 std::get_if<qwen3_asr::SpeakerRealtimeCompleted>(&event)) {
    kind = 3;
    is_final = 1;
    text = &completed->text;
    segments = &completed->segments;
  } else {
    native_test::require(
        std::holds_alternative<qwen3_asr::SpeakerRealtimeUpdated>(event),
        "Control failed");
  }
  nlohmann::ordered_json serialized_segments = nullptr;
  if (segments != nullptr) {
    serialized_segments = nlohmann::ordered_json::array();
    for (const auto &segment : *segments) {
      serialized_segments.push_back(
          {{"start", segment.start_seconds},
           {"end", segment.end_seconds},
           {"speaker", segment.speaker},
           {"text", segment.text},
           {"language", segment.language ? nlohmann::json(*segment.language)
                                         : nlohmann::json(nullptr)},
           {"emotion", segment.emotion ? nlohmann::json(*segment.emotion)
                                       : nlohmann::json(nullptr)},
           {"event", segment.event ? nlohmann::json(*segment.event)
                                   : nlohmann::json(nullptr)}});
    }
  } else {
  }
  return {{"kind", kind},
          {"segment_id", segment_id},
          {"is_final", is_final},
          {"text", text ? nlohmann::json(*text) : nlohmann::json(nullptr)},
          {"segments", serialized_segments},
          {"failure_status", 0}};
}
} // namespace
int main(int argument_count, char **arguments) {
  try {
    native_test::require(argument_count == 3, "Expected kind default/custom");
    const bool is_moss = std::string(arguments[1]) == "1";
    const bool custom = std::string(arguments[2]) == "custom";
    native_test::script.output = native_test::result("typed transcript");
    std::unique_ptr<moss::MossTranscriber> moss_model;
    std::unique_ptr<nemotron::NemotronTranscriber> nemo_model;
    std::shared_ptr<moss::MossRealtimeEngine> moss_engine;
    std::shared_ptr<nemotron::NemotronRealtimeEngine> nemo_engine;
    std::mutex events_mutex;
    auto events = nlohmann::ordered_json::array();
    const auto sink = [&](const qwen3_asr::SpeakerRealtimeEvent &event) {
      std::lock_guard<std::mutex> lock(events_mutex);
      events.push_back(typed_event(event));
    };
    qwen3_asr::TranscriptionWorker worker([&] {
      if (is_moss) {
        moss_model = std::make_unique<moss::MossTranscriber>(".");
      } else {
        nemo_model = std::make_unique<nemotron::NemotronTranscriber>(".");
      }
    });
    if (is_moss) {
      moss_engine =
          std::make_shared<moss::MossRealtimeEngine>(worker, *moss_model, sink);
      moss_engine->UpdatePrompt(
          custom ? std::optional<std::string>("typed <|audio_pad|>")
                 : std::nullopt);
      moss_engine->Append(native_test::audio(32000));
    } else {
      nemo_engine = std::make_shared<nemotron::NemotronRealtimeEngine>(
          worker, *nemo_model, sink);
      nemo_engine->UpdateSettings(
          custom ? std::optional<std::string>(" EN-us ") : std::nullopt,
          custom ? std::optional<double>(120) : std::nullopt);
      nemo_engine->Append(native_test::audio(32000));
    }
    worker.Transcribe(
        [](const std::atomic<bool> &) {
          return qwen3_asr::TranscriptionResult{};
        },
        qwen3_asr::NewCancelFlag());
    if (is_moss) {
      moss_engine->Commit();
      moss_engine->Finish();
    } else {
      nemo_engine->Commit();
      nemo_engine->Finish();
    }
    worker.Transcribe(
        [&](const std::atomic<bool> &) {
          moss_engine.reset();
          nemo_engine.reset();
          moss_model.reset();
          nemo_model.reset();
          return qwen3_asr::TranscriptionResult{};
        },
        qwen3_asr::NewCancelFlag());
    std::cout << nlohmann::ordered_json{{"calls",
                                         native_test::script.snapshot()},
                                        {"events", events}}
                     .dump()
              << '\n';
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
