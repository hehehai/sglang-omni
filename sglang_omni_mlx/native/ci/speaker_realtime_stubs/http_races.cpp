// SPDX-License-Identifier: Apache-2.0
#include "support.h"

#include <future>
#include <iostream>
#include <streambuf>

namespace speaker_test {
#ifndef SPEAKER_BASELINE
extern Gate preview_serialization;
extern std::atomic<bool> observes_preview_serialization;
#endif
class FailureLogGate : public std::streambuf {
public:
  Gate publication_gate;
  explicit FailureLogGate(qwen3_asr::TranscriptionWorker &worker)
      : worker_(worker), previous_(std::cerr.rdbuf(this)) {}
  ~FailureLogGate() override {
    publication_gate.release();
    drain(worker_);
    std::cerr.rdbuf(previous_);
  }

protected:
  std::streamsize xsputn(const char *text,
                         std::streamsize byte_count) override {
    if (std::string(text, static_cast<size_t>(byte_count))
            .find("realtime decode failed") != std::string::npos) {
      publication_gate.block();
    } else {
    }
    return previous_->sputn(text, byte_count);
  }
  int overflow(int character) override {
    if (character == traits_type::eof()) {
      return traits_type::not_eof(character);
    } else {
      return previous_->sputc(static_cast<char>(character));
    }
  }

private:
  qwen3_asr::TranscriptionWorker &worker_;
  std::streambuf *previous_;
};
nlohmann::ordered_json http_race_case(Family family, const std::string &name) {
  if (name == "lazy_close") {
    constexpr int REPLAY_COUNT = 50;
    for (int i = 0; i < REPLAY_COUNT; ++i) {
      HttpFixture fixture(family);
      std::promise<void> start;
      const auto started = start.get_future().share();
      auto update = std::async(std::launch::async, [&] {
        started.wait();
        fixture.handle({{"type", "session.update"},
                        {"session", nlohmann::json::object()}});
      });
      auto close = std::async(std::launch::async, [&] {
        started.wait();
        fixture.session->Close();
      });
      start.set_value();
      update.get();
      close.get();
      const size_t event_count = fixture.log.snapshot().size();
      fixture.append(64000);
      fixture.handle({{"type", "transcription.done"}});
      drain(fixture.worker);
      require(fixture.log.snapshot().size() == event_count &&
                  fixture.script.snapshot().empty(),
              "Lazy engine raced Close and decoded or published after "
              "cancellation");
    }
    return {{"passed", name}};
  } else {
  }
#ifndef SPEAKER_BASELINE
  if (name == "error_sender_close" || name == "error_sender_close_throws") {
    DecodeScript script;
    script.steps = {{result("preview"), false, true}};
    moss::MossTranscriber moss_model(script);
    nemotron::NemotronTranscriber nemotron_model(script, 16000, 0.08);
    qwen3_asr::TranscriptionWorker worker([] {});
    std::shared_ptr<qwen3_asr::RealtimeConnection> session;
    int delivered_events = 0;
    observes_preview_serialization.store(true);
    auto sender = [&](const std::string &serialized) {
      require(nlohmann::json::parse(serialized)["type"] == "error",
              "A preview escaped closed transport admission");
      ++delivered_events;
      script.model_gate.release();
      preview_serialization.wait();
      session->Close();
      if (name == "error_sender_close_throws") {
        throw std::runtime_error("Sender failed after Close");
      } else {
      }
      return true;
    };
    if (family == Family::kMoss) {
      session = std::make_shared<moss::MossRealtimeSession>(worker, moss_model,
                                                            sender);
    } else {
      session = std::make_shared<nemotron::NemotronRealtimeSession>(
          worker, nemotron_model, sender);
    }
    session->Handle(
        {{"type", "input_audio_buffer.append"},
         {"audio", pcm16(samples(family == Family::kMoss ? 20000 : 3))}});
    script.model_gate.wait();
    bool sender_failed = false;
    try {
      session->Handle({{"type", "unknown"}});
    } catch (const std::runtime_error &) {
      sender_failed = true;
    }
    require(sender_failed == (name == "error_sender_close_throws"),
            "Sender failure was swallowed or fabricated");
    drain(worker);
    session->Close();
    require(delivered_events == 1 &&
                !session->Handle({{"type", "transcription.done"}}),
            "Deferred Close did not permanently retire HTTP admission");
    return {{"passed", name}};
  } else {
  }
#endif
  HttpFixture fixture(family);
  if (name == "sender_close") {
    fixture.log.closes_in_sender = true;
    fixture.script.steps = {{result("preview")}};
    fixture.append(family == Family::kMoss ? 20000 : 3);
    drain(fixture.worker);
    fixture.handle({{"type", "transcription.done"}});
    require(fixture.log.snapshot().size() == 1,
            "Sender Close published later events");
    return {{"passed", name}};
  } else if (name == "failure_publication") {
    require(family == Family::kNemotron, "Failure log gate requires Nemotron");
    fixture.script.steps = {{result("PRIVATE"), true}};
    FailureLogGate failure_log(fixture.worker);
    fixture.append(3);
    failure_log.publication_gate.wait();
    auto finish = std::async(std::launch::async, [&] {
      fixture.handle({{"type", "transcription.done"}});
    });
    const bool finish_before_failure_publication =
        finish.wait_for(std::chrono::milliseconds(200)) ==
        std::future_status::ready;
    failure_log.publication_gate.release();
    finish.get();
    auto trace = fixture.trace();
    trace["finish_before_failure_publication"] =
        finish_before_failure_publication;
#ifdef SPEAKER_BASELINE
    require(finish_before_failure_publication,
            "Original failure ordering not reproduced");
    require(trace["events"][0]["type"] == "transcription.completed" &&
                trace["events"][1]["type"] == "error",
            "Original completed did not overtake failure");
#else
    require(!finish_before_failure_publication,
            "Finish overtook failure publication");
    require(trace["events"][0]["type"] == "error" &&
                trace["events"][1]["type"] == "transcription.completed",
            "Failure must precede completed");
#endif
    return trace;
  } else if (name == "close_waiter") {
    fixture.script.steps = {{result("late"), false, true}, {result("final")}};
    fixture.append(family == Family::kMoss ? 20000 : 3);
    fixture.script.model_gate.wait();
    std::promise<void> command_started;
    auto command = std::async(std::launch::async, [&] {
      command_started.set_value();
      fixture.handle({{"type", "transcription.done"}});
    });
    command_started.get_future().wait();
    const bool blocked_before_close =
        command.wait_for(std::chrono::milliseconds(100)) ==
        std::future_status::timeout;
    fixture.session->Close();
    const bool woke_before_model_return =
        command.wait_for(std::chrono::milliseconds(200)) ==
        std::future_status::ready;
    fixture.script.model_gate.release();
    command.get();
    auto trace = fixture.trace();
    trace["blocked_before_close"] = blocked_before_close;
    trace["woke_before_model_return"] = woke_before_model_return;
    require(blocked_before_close, "Finish did not wait for model");
#ifdef SPEAKER_BASELINE
    require(!woke_before_model_return,
            "Baseline unexpectedly woke without worker completion");
#else
    require(woke_before_model_return, "Close did not wake HTTP command");
#endif
    return trace;
  } else if (name == "publication") {
    fixture.script.steps = {{result("preview")}, {result("final")}};
    fixture.log.blocks_preview = true;
    fixture.append(family == Family::kMoss ? 20000 : 3);
    fixture.log.publication_gate.wait();
    std::promise<void> command_started;
    auto command = std::async(std::launch::async, [&] {
      command_started.set_value();
      fixture.handle({{"type", "transcription.done"}});
    });
    command_started.get_future().wait();
    bool finish_queued_before_preview_published = false;
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
    while (std::chrono::steady_clock::now() < deadline) {
      if (fixture.worker.RequestStates().count("queued") != 0) {
        finish_queued_before_preview_published = true;
        break;
      } else {
        std::this_thread::yield();
      }
    }
    const bool finish_returned =
        command.wait_for(std::chrono::milliseconds(0)) ==
        std::future_status::ready;
    fixture.log.publication_gate.release();
    command.get();
    auto trace = fixture.trace();
    trace["finish_queued_before_preview_published"] =
        finish_queued_before_preview_published;
    trace["finish_returned_before_preview_published"] = finish_returned;
    require(!finish_returned, "Finish returned while sender was blocked");
#ifdef SPEAKER_BASELINE
    require(finish_queued_before_preview_published ==
                (family == Family::kNemotron),
            "Unexpected original publication behavior");
#else
    require(!finish_queued_before_preview_published,
            "Finish requested before preview publication");
#endif
    return trace;
  } else {
    throw std::invalid_argument("Unknown HTTP race case");
  }
}
} // namespace speaker_test
