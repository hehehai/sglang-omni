// SPDX-License-Identifier: Apache-2.0
// Realtime HTTP events and serialization for one socket.
#pragma once

#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "realtime_engine.h"
#include "worker.h"

namespace qwen3_asr {

// One realtime socket's session: numbered events out, client events in.
// Handle runs on the socket's thread; decodes run on the worker and report
// back through the sender.
class RealtimeConnection
    : public std::enable_shared_from_this<RealtimeConnection> {
public:
  // Writes one serialized event; false once the socket is gone.
  using Sender = std::function<bool(const std::string &)>;

  explicit RealtimeConnection(Sender sender);
  virtual ~RealtimeConnection() = default;

  // Applies one client event; false once the session has completed.
  virtual bool Handle(const nlohmann::json &message) = 0;
  void SendError(const std::string &type, const std::string &code,
                 const std::string &message);
  // The client left: stop any decode in flight and send nothing more.
  void Close();

protected:
  void Send(nlohmann::ordered_json event);
  // The samples of an append event's base64 PCM16 audio; reports anything
  // else to the client and returns nothing.
  std::optional<std::vector<float>>
  AppendedSamples(const nlohmann::json &audio);
  // A session.update's session object when it asks for manual turns; reports
  // anything else to the client and returns nothing.
  std::optional<nlohmann::json>
  ManualTurnSession(const nlohmann::json &message);
  // Reports a failed decode; a cancelled one ended with the client.
  void ReportDecodeFailure(std::exception_ptr error);

  CancelFlag cancel_ = NewCancelFlag();

private:
  Sender sender_;
  std::mutex send_mutex_;
  int event_index_ = 0;
  bool closed_ = false;
};

// Qwen3-ASR HTTP adapter; the engine owns all transcription state.
class RealtimeSession : public RealtimeConnection {
public:
  RealtimeSession(TranscriptionWorker &worker,
                  const Qwen3ASRTranscriber &transcriber,
                  RealtimeSettings settings, Sender sender);

  bool Handle(const nlohmann::json &message) override;

private:
  void SendEvent(const RealtimeEvent &event);

  TranscriptionWorker &worker_;
  const Qwen3ASRTranscriber &transcriber_;
  const RealtimeSettings settings_;
  std::shared_ptr<RealtimeEngine> engine_;
};

} // namespace qwen3_asr
