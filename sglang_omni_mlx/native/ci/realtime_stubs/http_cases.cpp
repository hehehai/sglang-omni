// SPDX-License-Identifier: Apache-2.0
#include "support.h"

namespace qwen3_asr::realtime_test {
namespace {
nlohmann::json protocol_errors() {
  HttpSession fixture;
  fixture.recording.script.steps = {{"pcm verified"}};
  for (const nlohmann::json &session :
       {nlohmann::json(nullptr), nlohmann::json::array(),
        nlohmann::json{{"turn_detection", "server_vad"}},
        nlohmann::json{{"turn_detection", nlohmann::json::object()}}}) {
    fixture.handle({{"type", "session.update"}, {"session", session}});
  }
  fixture.handle({{"type", "session.update"}});
  fixture.handle(
      {{"type", "session.update"}, {"session", nlohmann::json::object()}});
  fixture.update(" en ");
  fixture.handle(nlohmann::json::object());
  fixture.handle({{"type", 123}});
  fixture.handle({{"type", "unknown"}});
  for (const nlohmann::json &audio :
       {nlohmann::json(nullptr), nlohmann::json(12), nlohmann::json(""),
        nlohmann::json("A"), nlohmann::json("AA=="), nlohmann::json("AA"),
        nlohmann::json("AA=A"), nlohmann::json("====")}) {
    fixture.handle({{"type", "input_audio_buffer.append"}, {"audio", audio}});
  }
  fixture.handle({{"type", "input_audio_buffer.append"}});
  fixture.handle(
      {{"type", "input_audio_buffer.append"},
       {"audio", " \n!" + pcm16_base64({-32768, -1, 0, 1, 32767}) + "#\t"}});
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json manual_turns() {
  HttpSession fixture;
  fixture.recording.script.steps = {
      {" \t hello \n"}, {"world"}, {"　你好　"}, {"世界"}, {" again "}};
  for (int i = 0; i < 5; ++i) {
    fixture.append({static_cast<int16_t>(1000 + i)});
    fixture.commit();
    fixture.commit();
  }
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json cadence() {
  HttpSession fixture({2, 2, 100});
  fixture.recording.script.steps = {
      {"first"}, {"replacement"}, {"replacement"}, {"latest"}, {"final"}};
  fixture.append({0, 0});
  fixture.recording.drain();
  fixture.append({1000});
  fixture.recording.drain();
  fixture.append({2000});
  fixture.recording.drain();
  fixture.append({3000});
  fixture.recording.drain();
  fixture.append({4000, 5000});
  fixture.recording.drain();
  fixture.append({6000, 7000});
  fixture.recording.drain();
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json automatic_cuts(bool exact_boundary) {
  HttpSession fixture({100, 100, 3});
  if (exact_boundary) {
    fixture.recording.script.steps = {{"boundary"}, {"tail"}};
    fixture.append({1000, 2000, 3000});
    fixture.commit();
    fixture.append({4000});
  } else {
    fixture.recording.script.steps = {{"one"}, {"two"}, {"三"}};
    fixture.append({1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000});
  }
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json language_snapshots() {
  HttpSession fixture({2, 2, 100});
  fixture.recording.script.steps = {{"detected", "German"},
                                    {"continued"},
                                    {"first final"},
                                    {"第二"},
                                    {"auto"}};
  fixture.update(" EN ");
  fixture.append({1000});
  fixture.update(" ZH-cn ");
  fixture.append({2000});
  fixture.recording.drain();
  fixture.append({3000, 4000});
  fixture.recording.drain();
  fixture.commit();
  fixture.append({5000});
  fixture.update(123);
  fixture.commit();
  fixture.append({6000});
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json prefix_rollback() {
  HttpSession fixture({1, 1, 100});
  fixture.recording.script.steps = {{"first draft", "English"},
                                    {"retained abcdefgh"},
                                    {"corrected abcdefgh"},
                                    {"short"},
                                    {"final"}};
  for (int i = 0; i < 4; ++i) {
    fixture.append({static_cast<int16_t>(1000 + i)});
    fixture.recording.drain();
  }
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json decode_failure() {
  HttpSession fixture({2, 2, 100});
  fixture.recording.script.steps = {
      {"", std::nullopt, true}, {"", std::nullopt, true}, {"survived"}};
  fixture.append({1000, 2000});
  fixture.recording.drain();
  fixture.commit();
  fixture.append({3000});
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json prefix_after_failure() {
  HttpSession fixture({1, 1, 100});
  fixture.recording.script.steps = {{"retained abcdefgh", "English"},
                                    {"", std::nullopt, true},
                                    {"recovered"}};
  fixture.append({1000});
  fixture.recording.drain();
  fixture.append({2000});
  fixture.recording.drain();
  fixture.finish();
  return fixture.recording.snapshot();
}

nlohmann::json blocked_preview(const std::string &case_name) {
  HttpSession fixture({2, 2, 100});
  fixture.recording.script.steps = {
      {"preview", "English", false, true, case_name == "late_success"}};
  if (case_name == "blocked_commit") {
    fixture.recording.script.steps.push_back({"final"});
  } else {
  }
  fixture.append({1000, 2000});
  fixture.recording.script.wait_for_calls(1);
  if (case_name == "blocked_commit") {
    std::promise<void> commit_started;
    std::future<void> started = commit_started.get_future();
    std::future<void> committed = std::async(std::launch::async, [&] {
      commit_started.set_value();
      fixture.commit();
    });
    started.get();
    fixture.recording.script.release();
    committed.get();
    fixture.finish();
  } else {
    fixture.session->Close();
    fixture.session->Close();
    fixture.recording.script.release();
    fixture.recording.drain();
    fixture.session->SendError("server_error", "late", "must not be published");
  }
  return fixture.recording.snapshot();
}
} // namespace

nlohmann::json run_http_case(const std::string &case_name) {
  if (case_name == "protocol_errors") {
    return protocol_errors();
  } else if (case_name == "manual_turns") {
    return manual_turns();
  } else if (case_name == "cadence") {
    return cadence();
  } else if (case_name == "automatic_cuts" || case_name == "exact_boundary") {
    return automatic_cuts(case_name == "exact_boundary");
  } else if (case_name == "language_snapshots") {
    return language_snapshots();
  } else if (case_name == "prefix_rollback") {
    return prefix_rollback();
  } else if (case_name == "decode_failure") {
    return decode_failure();
  } else if (case_name == "prefix_after_failure") {
    return prefix_after_failure();
  } else if (case_name == "blocked_commit" || case_name == "blocked_close" ||
             case_name == "late_success") {
    return blocked_preview(case_name);
  } else if (case_name == "empty_finish" || case_name == "silent_finish") {
    HttpSession fixture({1, 1, 100});
    fixture.commit();
    if (case_name == "silent_finish") {
      fixture.append({0, 32, -32});
      fixture.recording.drain();
    } else {
    }
    fixture.finish();
    return fixture.recording.snapshot();
  } else {
    throw std::invalid_argument("Unknown HTTP case: " + case_name);
  }
}
} // namespace qwen3_asr::realtime_test
