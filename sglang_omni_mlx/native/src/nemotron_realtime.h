// SPDX-License-Identifier: Apache-2.0
// Nemotron realtime HTTP adapter; the engine owns the cache-aware stream.
#pragma once

#include <memory>
#include <mutex>

#include "nemotron_realtime_engine.h"
#include "realtime.h"

namespace nemotron {

class NemotronRealtimeSession : public qwen3_asr::RealtimeConnection {
public:
  NemotronRealtimeSession(qwen3_asr::TranscriptionWorker &worker,
                          const NemotronTranscriber &transcriber,
                          Sender sender);
  ~NemotronRealtimeSession() override;

  bool Handle(const nlohmann::json &message) override;
  void Close() override;

private:
  qwen3_asr::TranscriptionWorker &worker_;
  const NemotronTranscriber &transcriber_;
  std::mutex engine_mutex_;
  std::shared_ptr<NemotronRealtimeEngine> engine_;
  bool closed_ = false;
};

} // namespace nemotron
