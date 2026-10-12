// SPDX-License-Identifier: Apache-2.0
#include "engine_support.h"

namespace speaker_test {
EngineFixture::EngineFixture(Family family) {
  const auto sink = [this](const qwen3_asr::SpeakerRealtimeEvent &event) {
    const auto *segment =
        std::get_if<qwen3_asr::SpeakerRealtimeSegment>(&event);
    if (blocks_preview && segment != nullptr && !segment->is_final) {
      publication_gate.block();
    } else {
    }
    {
      std::lock_guard<std::mutex> lock(events_mutex);
      events.push_back(event);
    }
    if (closes_in_sink) {
      close();
    } else {
    }
  };
  if (family == Family::kMoss) {
    engine = std::make_shared<moss::MossRealtimeEngine>(worker, moss_model,
                                                        sink, cancel);
  } else {
    engine = std::make_shared<nemotron::NemotronRealtimeEngine>(
        worker, nemotron_model, sink, cancel);
  }
}
EngineFixture::~EngineFixture() {
  script.model_gate.release();
  publication_gate.release();
  close();
  drain(worker);
}
void EngineFixture::append(std::vector<float> samples) {
  std::visit(
      [&](const auto &concrete_engine) {
        concrete_engine->Append(std::move(samples));
      },
      engine);
}
void EngineFixture::commit() {
  std::visit([](const auto &concrete_engine) { concrete_engine->Commit(); },
             engine);
}
void EngineFixture::finish() {
  std::visit([](const auto &concrete_engine) { concrete_engine->Finish(); },
             engine);
}
void EngineFixture::close() {
  std::visit(
      [](const auto &concrete_engine) {
        if (concrete_engine) {
          concrete_engine->Close();
        } else {
        }
      },
      engine);
}
void EngineFixture::destroy() {
  std::visit([](auto &concrete_engine) { concrete_engine.reset(); }, engine);
}
std::vector<qwen3_asr::SpeakerRealtimeEvent> EngineFixture::snapshot() {
  std::lock_guard<std::mutex> lock(events_mutex);
  return events;
}
} // namespace speaker_test
