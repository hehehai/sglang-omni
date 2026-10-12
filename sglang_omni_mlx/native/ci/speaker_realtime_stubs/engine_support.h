// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "moss_realtime_engine.h"
#include "nemotron_realtime_engine.h"
#include "support.h"

namespace speaker_test {
class EngineFixture {
public:
  DecodeScript script;
  moss::MossTranscriber moss_model{script};
  nemotron::NemotronTranscriber nemotron_model{script};
  qwen3_asr::TranscriptionWorker worker{[] {}};
  std::variant<std::shared_ptr<moss::MossRealtimeEngine>,
               std::shared_ptr<nemotron::NemotronRealtimeEngine>>
      engine;
  qwen3_asr::CancelFlag cancel = qwen3_asr::NewCancelFlag();
  std::mutex events_mutex;
  std::vector<qwen3_asr::SpeakerRealtimeEvent> events;
  Gate publication_gate;
  bool blocks_preview = false;
  bool closes_in_sink = false;
  explicit EngineFixture(Family family);
  ~EngineFixture();
  void append(std::vector<float> samples);
  void commit();
  void finish();
  void close();
  void destroy();
  std::vector<qwen3_asr::SpeakerRealtimeEvent> snapshot();
};
} // namespace speaker_test
