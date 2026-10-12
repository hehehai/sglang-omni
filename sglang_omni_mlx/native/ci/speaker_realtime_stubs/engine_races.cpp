// SPDX-License-Identifier: Apache-2.0
#include "engine_support.h"

#include <future>

namespace speaker_test {
nlohmann::ordered_json engine_race_case(Family family,
                                        const std::string &name) {
  if (name == "worker_join") {
    DecodeScript script;
    script.steps = {{result("retained"), false, true, true}};
    moss::MossTranscriber moss_model(script);
    nemotron::NemotronTranscriber nemotron_model(script);
    auto worker = std::make_unique<qwen3_asr::TranscriptionWorker>([] {});
    const auto cancel = qwen3_asr::NewCancelFlag();
    std::atomic<int> event_count{0};
    const auto sink = [&](const qwen3_asr::SpeakerRealtimeEvent &) {
      ++event_count;
    };
    if (family == Family::kMoss) {
      auto engine = std::make_shared<moss::MossRealtimeEngine>(
          *worker, moss_model, sink, cancel);
      engine->Append(samples(20000));
      script.model_gate.wait();
      engine.reset();
    } else {
      auto engine = std::make_shared<nemotron::NemotronRealtimeEngine>(
          *worker, nemotron_model, sink, cancel);
      engine->Append(samples(3));
      script.model_gate.wait();
      engine.reset();
    }
    auto join = std::async(std::launch::async, [&] { worker.reset(); });
    const bool waits_for_job = join.wait_for(std::chrono::milliseconds(100)) ==
                               std::future_status::timeout;
    script.model_gate.release();
    join.get();
    require(waits_for_job && cancel->load() && event_count == 0,
            "Actual worker destruction failed to join retained job");
    return {{"passed", name}};
  } else {
  }
  EngineFixture fixture(family);
  if (name == "final_close") {
    if (family == Family::kNemotron) {
      fixture.script.steps = {{result("preview")},
                              {result("final"), false, true, true}};
      fixture.append(samples(3));
      drain(fixture.worker);
    } else {
      fixture.script.steps = {{result("final"), false, true, true}};
      fixture.append(samples(3));
    }
    const size_t event_count = fixture.snapshot().size();
    auto finish = std::async(std::launch::async, [&] { fixture.finish(); });
    fixture.script.model_gate.wait();
    fixture.close();
    const bool woke_without_model =
        finish.wait_for(std::chrono::milliseconds(200)) ==
        std::future_status::ready;
    fixture.script.model_gate.release();
    finish.get();
    drain(fixture.worker);
    require(woke_without_model && fixture.snapshot().size() == event_count,
            "Close did not wake active final job command or suppressed event "
            "escaped");
  } else if (name == "close_commit" || name == "close_finish" ||
             name == "close_preview_commit" || name == "close_preview_finish") {
    fixture.script.steps = {{result("late"), false, true, true},
                            {result("tail")}};
    const bool is_preview = name.find("preview") != std::string::npos;
    if (is_preview || family == Family::kNemotron) {
      fixture.append(samples(family == Family::kMoss ? 20000 : 3));
      fixture.script.model_gate.wait();
    } else {
      fixture.append(samples(3));
    }
    std::promise<void> started;
    auto command = std::async(std::launch::async, [&] {
      started.set_value();
      if (name.find("commit") != std::string::npos) {
        fixture.commit();
      } else {
        fixture.finish();
      }
    });
    started.get_future().wait();
    fixture.script.model_gate.wait();
    const bool was_blocked = command.wait_for(std::chrono::milliseconds(100)) ==
                             std::future_status::timeout;
    fixture.close();
    const bool woke_without_model =
        command.wait_for(std::chrono::milliseconds(200)) ==
        std::future_status::ready;
    fixture.script.model_gate.release();
    command.get();
    drain(fixture.worker);
    require(was_blocked, "Command failed to wait for worker");
    require(woke_without_model,
            "Close drained worker instead of waking blocked command");
    require(fixture.snapshot().empty(), "Late worker result escaped Close");
  } else if (name == "sink_close") {
    fixture.closes_in_sink = true;
    fixture.script.steps = {{result("preview")}};
    fixture.append(samples(family == Family::kMoss ? 20000 : 3));
    drain(fixture.worker);
    require(fixture.cancel->load() && fixture.snapshot().size() == 1,
            "Sink Close failed");
    fixture.finish();
    fixture.append(samples(64000));
    require(fixture.snapshot().size() == 1, "Post-close event delivered");
  } else if (name == "active_sink_close") {
    fixture.blocks_preview = true;
    fixture.script.steps = {{result("preview")}};
    fixture.append(samples(family == Family::kMoss ? 20000 : 3));
    fixture.publication_gate.wait();
    std::promise<void> started;
    auto close = std::async(std::launch::async, [&] {
      started.set_value();
      fixture.close();
    });
    started.get_future().wait();
    const bool waits_for_sink =
        close.wait_for(std::chrono::milliseconds(100)) ==
        std::future_status::timeout;
    fixture.publication_gate.release();
    close.get();
    drain(fixture.worker);
    fixture.finish();
    require(waits_for_sink && fixture.snapshot().size() == 1,
            "Close did not join active event delivery");
  } else if (name == "destroy_active") {
    fixture.script.steps = {{result("retained job"), false, true, true}};
    fixture.append(samples(family == Family::kMoss ? 20000 : 3));
    fixture.script.model_gate.wait();
    fixture.destroy();
    require(fixture.cancel->load(), "Destructor did not cancel");
    auto join = std::async(std::launch::async, [&] { drain(fixture.worker); });
    const bool job_retained = join.wait_for(std::chrono::milliseconds(100)) ==
                              std::future_status::timeout;
    fixture.script.model_gate.release();
    join.get();
    require(job_retained && fixture.snapshot().empty(),
            "Destruction drained or published retained job");
  } else if (name == "publication") {
    fixture.script.steps = {{result("preview")}, {result("final")}};
    fixture.blocks_preview = true;
    fixture.append(samples(family == Family::kMoss ? 20000 : 3));
    fixture.publication_gate.wait();
    auto finish = std::async(std::launch::async, [&] { fixture.finish(); });
    const bool waiting = finish.wait_for(std::chrono::milliseconds(100)) ==
                         std::future_status::timeout;
    const bool has_queued_finish =
        fixture.worker.RequestStates().count("queued") != 0;
    fixture.publication_gate.release();
    finish.get();
    require(waiting && !has_queued_finish,
            "Finish advanced before typed preview publication");
    const auto events = fixture.snapshot();
    require(
        events.size() == 3 &&
            !std::get<qwen3_asr::SpeakerRealtimeSegment>(events[0]).is_final &&
            std::get<qwen3_asr::SpeakerRealtimeSegment>(events[1]).is_final &&
            std::holds_alternative<qwen3_asr::SpeakerRealtimeCompleted>(
                events[2]),
        "Typed publication order changed");
  } else {
    throw std::invalid_argument("Unknown typed race case");
  }
  return {{"passed", name}};
}
} // namespace speaker_test
