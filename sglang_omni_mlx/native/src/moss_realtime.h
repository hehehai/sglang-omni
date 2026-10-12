// SPDX-License-Identifier: Apache-2.0
// MOSS realtime HTTP adapter; the typed engine owns transcription state.
#pragma once

#include <memory>
#include <mutex>

#include "moss_realtime_engine.h"
#include "realtime.h"

namespace moss {

class MossRealtimeSession : public qwen3_asr::RealtimeConnection {
public:
  MossRealtimeSession(qwen3_asr::TranscriptionWorker &worker,
                      const MossTranscriber &transcriber, Sender sender);
  ~MossRealtimeSession() override;

  bool Handle(const nlohmann::json &message) override;
  void Close() override;

private:
  qwen3_asr::TranscriptionWorker &worker_;
  const MossTranscriber &transcriber_;
  std::mutex engine_mutex_;
  std::shared_ptr<MossRealtimeEngine> engine_;
  bool closed_ = false;
};

} // namespace moss
