// SPDX-License-Identifier: Apache-2.0
#include "nemotron_realtime.h"

#include <limits>
#include <optional>
#include <utility>

namespace nemotron {

NemotronRealtimeSession::NemotronRealtimeSession(
    qwen3_asr::TranscriptionWorker &worker,
    const NemotronTranscriber &transcriber, Sender sender)
    : RealtimeConnection(std::move(sender)), worker_(worker),
      transcriber_(transcriber) {}

NemotronRealtimeSession::~NemotronRealtimeSession() { Close(); }

bool NemotronRealtimeSession::Handle(const nlohmann::json &message) {
  std::shared_ptr<NemotronRealtimeEngine> engine;
  {
    std::lock_guard<std::mutex> lock(engine_mutex_);
    if (closed_) {
      return false;
    } else if (!engine_) {
      const std::weak_ptr<NemotronRealtimeSession> weak_self =
          std::static_pointer_cast<NemotronRealtimeSession>(shared_from_this());
      engine_ = std::make_shared<NemotronRealtimeEngine>(
          worker_, transcriber_,
          [weak_self](const qwen3_asr::SpeakerRealtimeEvent &event) {
            if (const auto self = weak_self.lock()) {
              self->Send(qwen3_asr::SpeakerRealtimeEventJson(event));
            } else {
            }
          },
          cancel_);
    } else {
    }
    engine = engine_;
  }
  const nlohmann::json type = message.value("type", nlohmann::json());
  if (type == "session.update") {
    const std::optional<nlohmann::json> session = ManualTurnSession(message);
    if (session.has_value()) {
      const nlohmann::json language =
          session->value("language", nlohmann::json());
      const nlohmann::json chunk = session->value("chunk_ms", nlohmann::json());
      std::optional<double> chunk_milliseconds;
      if (chunk.is_null()) {
        chunk_milliseconds.reset();
      } else if (chunk.is_number()) {
        chunk_milliseconds = chunk.get<double>();
      } else {
        // Note (Codex): let the engine retain session_started error precedence.
        chunk_milliseconds = std::numeric_limits<double>::quiet_NaN();
      }
      engine->UpdateSettings(language.is_string()
                                 ? std::optional(language.get<std::string>())
                                 : std::nullopt,
                             chunk_milliseconds);
    } else {
    }
    return true;
  } else if (type == "input_audio_buffer.append") {
    std::optional<std::vector<float>> samples =
        AppendedSamples(message.value("audio", nlohmann::json()));
    if (samples.has_value()) {
      engine->Append(std::move(*samples));
    } else {
    }
    return true;
  } else if (type == "input_audio_buffer.commit") {
    engine->Commit();
    return true;
  } else if (type == "transcription.done") {
    engine->Finish();
    return false;
  } else {
    SendError("invalid_request_error", "invalid_event", "Unknown event type.");
    return true;
  }
}

void NemotronRealtimeSession::Close() {
  if (IsSendingOnThisThread()) {
    RealtimeConnection::Close();
    return;
  } else {
  }
  std::shared_ptr<NemotronRealtimeEngine> engine;
  {
    std::lock_guard<std::mutex> lock(engine_mutex_);
    closed_ = true;
    engine = engine_;
  }
  if (engine) {
    engine->Close();
  } else {
  }
  RealtimeConnection::Close();
}

} // namespace nemotron
