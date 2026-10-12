// SPDX-License-Identifier: Apache-2.0
#include "support.h"
#include <algorithm>
#include <cstring>
namespace native_test {
void protocol_case(OmniSpeakerModelKind kind, const std::string &name) {
  Fixture fixture(kind, false);
  if (name == "defaults") {
    require(fixture.settings.model_kind == kind, "Wrong default kind");
    require(fixture.settings.family.moss.prompt == nullptr,
            "Default text not absent");
    if (kind == OMNI_SPEAKER_NEMOTRON) {
      require(fixture.settings.family.nemotron.has_chunk == 0 &&
                  fixture.settings.family.nemotron.chunk_milliseconds == 0,
              "Default chunk changed");
    } else {
    }
    fixture.create_stream();
    require(script.sync_count == 0,
            "Native idle worker performed unguarded sync");
    if (kind == OMNI_SPEAKER_NEMOTRON) {
      require(script.live_streams == 1, "Native stream not prepared eagerly");
      require(script.snapshot().at(0).at("chunk_frames").is_null(),
              "Default chunk was replaced");
    } else {
    }
  } else if (name == "full_session") {
    fixture.create_stream();
    const auto complete_audio = audio(480000);
    for (size_t offset_samples = 0; offset_samples < complete_audio.size();
         offset_samples += 32000) {
      fixture.push(
          std::vector<float>(complete_audio.begin() + offset_samples,
                             complete_audio.begin() + offset_samples + 32000));
    }
    uint64_t accepted = 99;
    const float sample = 0.25f;
    expect_status(
        omni_speaker_realtime_push(fixture.stream, 16, &sample, 1, &accepted),
        OMNI_BATCH_LIMIT, "Exact session cap");
    require(accepted == 0, "Limit rejection consumed audio sequence");
    expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                  "Finish exact 480000 samples");
    size_t observed_samples = 0;
    const auto calls = script.snapshot();
    for (const auto &call : calls) {
      if (kind == OMNI_SPEAKER_MOSS && call.at("operation") == "Transcribe" &&
          call.at("max_new_tokens").get<int>() >= 96) {
        const auto samples = call.at("samples").get<std::vector<float>>();
        require(observed_samples + samples.size() <= complete_audio.size(),
                "MOSS extra physical samples");
        require(std::equal(samples.begin(), samples.end(),
                           complete_audio.begin() + observed_samples),
                "MOSS samples clipped, duplicated, or reordered");
        require(call.at("window_offset_seconds").get<double>() ==
                        static_cast<double>(observed_samples) / 16000 &&
                    call.at("stop_at_end_of_text") &&
                    call.at("stop_on_token_loop"),
                "MOSS physical frames/options changed");
        observed_samples += samples.size();
      } else if (kind == OMNI_SPEAKER_NEMOTRON &&
                 call.at("operation") == "Finish") {
        require(call.at("ordered_samples").get<std::vector<float>>() ==
                    complete_audio,
                "Nemo full Float32 sequence changed");
        observed_samples = complete_audio.size();
      } else {
      }
    }
    require(observed_samples == 480000,
            "Session physical admitted samples not fully decoded");
    require(fixture.events().back().at("kind") == OMNI_SPEAKER_COMPLETED,
            "Exact cap lost completion");
  } else if (name == "mapping" || name == "empty_segments" ||
             name == "snapshot_ownership") {
    if (name == "empty_segments") {
      script.output.segments.clear();
    } else {
    }
    fixture.create_stream();
    fixture.push(audio(32000));
    auto preview = fixture.wait_segment();
    require(preview.kind == OMNI_SPEAKER_SEGMENT && !preview.is_final &&
                !preview.has_segments && preview.segment_count == 0 &&
                preview.segments == nullptr,
            "Preview absence lost");
    omni_speaker_realtime_event_free(&preview);
    expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                  "finish");
    auto final = fixture.poll();
    require(final.kind == OMNI_SPEAKER_SEGMENT && final.is_final &&
                final.has_segments,
            "Final segments presence lost");
    if (name == "empty_segments") {
      require(final.segment_count == 0 && final.segments == nullptr,
              "Empty final not preserved");
    } else {
      require(final.segment_count == 2, "Final segments truncated");
      const auto &segment = final.segments[0];
      require(segment.start_seconds == 0.125 && segment.end_seconds == 0.875 &&
                  std::strcmp(segment.speaker, "S03") == 0 &&
                  std::strcmp(segment.language, "en-US") == 0 &&
                  std::strcmp(segment.emotion, "neutral") == 0 &&
                  std::strcmp(segment.event, "speech") == 0,
              "Double times/metadata changed");
      require(final.segments[1].language == nullptr &&
                  final.segments[1].emotion != nullptr &&
                  final.segments[1].emotion[0] == '\0' &&
                  final.segments[1].event == nullptr,
              "Optional absent versus empty metadata lost");
    }
    auto completed = fixture.poll();
    require(completed.kind == OMNI_SPEAKER_COMPLETED &&
                completed.has_segments &&
                completed.segment_count == final.segment_count &&
                std::strcmp(completed.text, final.text) == 0,
            "Completion changed");
    if (name == "snapshot_ownership") {
      fixture.close();
      require(std::strcmp(final.text, "typed transcript") == 0 &&
                  std::strcmp(final.segments[0].language, "en-US") == 0 &&
                  std::strcmp(completed.text, final.text) == 0,
              "Snapshot borrowed freed engine/model storage");
      omni_speaker_realtime_event_free(&completed);
      omni_speaker_realtime_event_free(&final);
      return;
    } else {
    }
    omni_speaker_realtime_event_free(&completed);
    omni_speaker_realtime_event_free(&final);
  } else if (name == "empty_finish") {
    script.output = result("");
    script.output.segments.clear();
    fixture.create_stream();
    expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                  "empty finish");
    const auto events = fixture.events();
    require(events.back().at("kind") == OMNI_SPEAKER_COMPLETED &&
                events.back().at("text") == "" &&
                events.back().at("segments").empty(),
            "Empty finish changed");
    expect_status(omni_speaker_realtime_finish(fixture.stream),
                  OMNI_BATCH_INVALID, "finish twice");
  } else if (name == "commit") {
    fixture.create_stream();
    fixture.push(audio(32000));
    auto preview = fixture.wait_segment();
    omni_speaker_realtime_event_free(&preview);
    expect_status(omni_speaker_realtime_commit(fixture.stream), OMNI_BATCH_OK,
                  "commit");
    const auto events = fixture.events();
    require(events.back().at("kind") == OMNI_SPEAKER_SEGMENT,
            "Commit prematurely completed");
    if (kind == OMNI_SPEAKER_MOSS) {
      fixture.push(audio(1));
    } else {
      uint64_t accepted = 1;
      const float sample = 0.3f;
      expect_status(
          omni_speaker_realtime_push(fixture.stream, 2, &sample, 1, &accepted),
          OMNI_BATCH_INVALID, "Nemo committed append");
      require(accepted == 0, "Invalid postcommit ACK");
    }
    expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                  "finish after commit");
  } else if (name == "copy_settings" || name == "maximum_settings" ||
             name.starts_with("chunk_")) {
    std::string setting =
        name == "maximum_settings"
            ? std::string(kind == OMNI_SPEAKER_MOSS ? 8190 : 126, 's') +
                  "\xc3\xa9"
            : "typed <|audio_pad|>";
    const std::string expected_setting = setting;
    if (kind == OMNI_SPEAKER_MOSS) {
      fixture.settings.family.moss.prompt = setting.c_str();
    } else {
      fixture.settings.family.nemotron.language = setting.c_str();
      fixture.settings.family.nemotron.has_chunk = 1;
      fixture.settings.family.nemotron.chunk_milliseconds =
          name.starts_with("chunk_") ? std::stod(name.substr(6)) : 120;
      script.frame_seconds = name == "chunk_440" ? 0.04 : 0.08;
    }
    fixture.create_stream();
    setting.assign(setting.size(), 'X');
    fixture.push(audio(1));
    expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                  "settings finish");
    const auto calls = script.snapshot();
    if (kind == OMNI_SPEAKER_MOSS) {
      require(calls[0].at("prompt") == expected_setting,
              "Borrowed prompt mutated");
    } else {
      require(calls[0].at("language") == expected_setting,
              "Borrowed language mutated");
      const double milliseconds =
          fixture.settings.family.nemotron.chunk_milliseconds;
      const int expected_frames = milliseconds <= 120   ? 1
                                  : milliseconds <= 240 ? 2
                                  : milliseconds <= 440
                                      ? (script.frame_seconds == 0.04 ? 8 : 4)
                                  : milliseconds <= 840 ? 7
                                                        : 14;
      require(calls[0].at("chunk_frames") == expected_frames,
              "Actual nearest frame rule changed");
    }
  } else {
    throw std::invalid_argument("Unknown protocol case");
  }
  fixture.close();
}
nlohmann::ordered_json trace_case(OmniSpeakerModelKind kind,
                                  const std::string &name) {
  Fixture fixture(kind, false);
  if (name == "custom") {
    if (kind == OMNI_SPEAKER_MOSS) {
      fixture.settings.family.moss.prompt = "typed <|audio_pad|>";
    } else {
      fixture.settings.family.nemotron.language = " EN-us ";
      fixture.settings.family.nemotron.has_chunk = 1;
      fixture.settings.family.nemotron.chunk_milliseconds = 120;
    }
  } else {
  }
  fixture.create_stream();
  auto events = fixture.events();
  fixture.push(audio(32000));
  auto preview = fixture.wait_segment();
  events.push_back(event_json(preview));
  omni_speaker_realtime_event_free(&preview);
  expect_status(omni_speaker_realtime_commit(fixture.stream), OMNI_BATCH_OK,
                "trace commit");
  expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                "trace finish");
  for (const auto &event : fixture.events()) {
    events.push_back(event);
  }
  auto calls = script.snapshot();
  fixture.close();
  return {{"calls", calls}, {"events", events}};
}
} // namespace native_test
