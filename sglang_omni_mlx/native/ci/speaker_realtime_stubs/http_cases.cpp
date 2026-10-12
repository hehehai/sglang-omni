// SPDX-License-Identifier: Apache-2.0
#include "support.h"

#include <thread>

namespace speaker_test {
nlohmann::ordered_json http_case(Family family, const std::string &name) {
  const bool is_limit = name == "session_limit";
  HttpFixture fixture(family, is_limit ? 1 : 16000,
                      name == "chunk_rounding" ? 0.03 : 0.08);
  auto &script = fixture.script;
  if (name == "protocol") {
    for (const nlohmann::json &message : std::vector<nlohmann::json>{
             nlohmann::json::object(),
             {{"type", "unknown"}},
             {{"type", "session.update"}},
             {{"type", "session.update"},
              {"session", {{"turn_detection", "vad"}}}},
             {{"type", "input_audio_buffer.append"}, {"audio", ""}},
             {{"type", "input_audio_buffer.append"}, {"audio", 4}},
             {{"type", "input_audio_buffer.append"}, {"audio", "AQ=="}},
             {{"type", "input_audio_buffer.append"}, {"audio", "A"}},
             {{"type", "session.update"},
              {"session", nlohmann::json::object()}}}) {
      fixture.handle(message);
    }
  } else if (name == "empty_finish") {
    script.steps = {{result("")}};
    script.steps[0].result.segments.clear();
    fixture.handle({{"type", "input_audio_buffer.commit"}});
    fixture.handle({{"type", "input_audio_buffer.commit"}});
    fixture.handle({{"type", "transcription.done"}});
  } else if (name == "failure" || name == "finish_failure") {
    script.steps = {{result("PRIVATE"), true}};
    fixture.append(family == Family::kMoss ? 20000 : 4);
    drain(fixture.worker);
    if (name == "finish_failure") {
      script.steps.push_back({result("PRIVATE"), true});
    } else {
      script.steps.push_back({result("recovered")});
    }
    fixture.handle({{"type", "transcription.done"}});
  } else if (family == Family::kMoss) {
    if (name == "prompt") {
      for (const nlohmann::json &prompt :
           std::vector<nlohmann::json>{"<|audio_pad|><|audio_pad|>",
                                       "one <|audio_pad|>", "", 42, nullptr}) {
        fixture.handle(
            {{"type", "session.update"}, {"session", {{"prompt", prompt}}}});
      }
      script.steps = {{result("done")}};
      fixture.append(3);
      fixture.handle({{"type", "transcription.done"}});
    } else if (name == "threshold") {
      script.steps = {{result("preview")}, {result("final")}};
      fixture.append(19999);
      drain(fixture.worker);
      require(script.snapshot().empty(), "Preview below 1.25 seconds");
      fixture.append(1, 19999);
      drain(fixture.worker);
      fixture.handle({{"type", "transcription.done"}});
    } else if (name == "preview_tail") {
      script.steps = {{result("preview", 0.5)}, {result("final")}};
      fixture.append(48000);
      drain(fixture.worker);
      fixture.handle({{"type", "transcription.done"}});
    } else if (name == "windows") {
      script.steps = {{result(" \xE3\x80\x80 first \n")},
                      {result(" second ", 4.0)},
                      {result("\n\t", 8.0)}};
      fixture.append(64000);
      drain(fixture.worker);
      fixture.append(64000, 64000);
      drain(fixture.worker);
      fixture.append(3, 128000);
      fixture.handle({{"type", "input_audio_buffer.commit"}});
      fixture.handle({{"type", "input_audio_buffer.commit"}});
      fixture.handle({{"type", "transcription.done"}});
    } else if (name == "backlog_merge" || name == "backlog_split" ||
               name == "prompt_during_decode") {
      const size_t sample_count = name == "backlog_split" ? 128000 : 127999;
      script.steps = {{result("preview"), false, true},
                      {result("first")},
                      {result("second", 4.0)}};
      fixture.handle(
          {{"type", "session.update"}, {"session", {{"prompt", "old"}}}});
      fixture.append(20000);
      script.model_gate.wait();
      fixture.append(sample_count - 20000, 20000);
      fixture.handle(
          {{"type", "session.update"}, {"session", {{"prompt", "new"}}}});
      script.model_gate.release();
      drain(fixture.worker);
      fixture.handle({{"type", "transcription.done"}});
    } else if (name == "empty_segments") {
      script.steps = {{result("")}, {result(" \n")}};
      script.steps[1].result.segments.clear();
      fixture.append(20000);
      drain(fixture.worker);
      fixture.handle({{"type", "transcription.done"}});
    } else if (name == "cadence") {
      script.steps = {{result("first preview")},
                      {result("second preview")},
                      {result("final")}};
      fixture.append(20000);
      drain(fixture.worker);
      std::this_thread::sleep_for(std::chrono::milliseconds(1100));
      fixture.append(1, 20000);
      drain(fixture.worker);
      fixture.handle({{"type", "transcription.done"}});
    } else {
      throw std::invalid_argument("Unknown Moss HTTP case");
    }
  } else if (name.rfind("chunk_", 0) == 0) {
    const double chunk_milliseconds =
        name == "chunk_rounding" ? 80.0 : std::stod(name.substr(6));
    fixture.handle(
        {{"type", "session.update"},
         {"session",
          {{"language", " EN-us "}, {"chunk_ms", chunk_milliseconds}}}});
    script.steps = {{result("final")}};
    fixture.handle({{"type", "transcription.done"}});
  } else if (name == "settings") {
    for (const nlohmann::json &chunk :
         std::vector<nlohmann::json>{0, -1, "80", true, nullptr, 320}) {
      fixture.handle({{"type", "session.update"},
                      {"session", {{"language", 17}, {"chunk_ms", chunk}}}});
    }
    script.steps = {{result("preview")}, {result("final")}};
    fixture.append(3);
    drain(fixture.worker);
    fixture.handle(
        {{"type", "session.update"}, {"session", {{"chunk_ms", -1}}}});
    fixture.handle({{"type", "input_audio_buffer.commit"}});
    fixture.handle({{"type", "input_audio_buffer.commit"}});
    fixture.append(3);
    fixture.handle({{"type", "transcription.done"}});
  } else if (name == "pending" || name == "failure_no_advance") {
    script.steps = {{result("first"), name == "failure_no_advance", true},
                    {result("second")},
                    {result("final")}};
    fixture.append(3);
    script.model_gate.wait();
    fixture.append(4, 3);
    fixture.append(5, 7);
    script.model_gate.release();
    drain(fixture.worker);
    drain(fixture.worker);
    fixture.handle({{"type", "input_audio_buffer.commit"}});
    fixture.handle({{"type", "input_audio_buffer.commit"}});
    fixture.append(2, 12);
    fixture.handle({{"type", "transcription.done"}});
  } else if (name == "duplicates") {
    script.steps = {
        {result("same")}, {result("same")}, {result("")}, {result("final")}};
    for (size_t i = 0; i < 3; ++i) {
      fixture.append(3, i * 3);
      drain(fixture.worker);
    }
    fixture.handle({{"type", "transcription.done"}});
  } else if (name == "session_limit") {
    script.steps = {{result("preview")}, {result("final")}};
    fixture.append(86400);
    drain(fixture.worker);
    fixture.append(1, 86400);
    fixture.handle({{"type", "transcription.done"}});
  } else {
    throw std::invalid_argument("Unknown Nemotron HTTP case");
  }
  return fixture.trace();
}
} // namespace speaker_test
