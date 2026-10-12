// SPDX-License-Identifier: Apache-2.0
#include "moss_realtime.h"

namespace moss {

MossRealtimeSession::MossRealtimeSession(qwen3_asr::TranscriptionWorker &worker,
                                         const MossTranscriber &transcriber,
                                         Sender sender)
    : RealtimeConnection(std::move(sender)), worker_(worker),
      transcriber_(transcriber) {}

MossRealtimeSession::~MossRealtimeSession() { Close(); }

bool MossRealtimeSession::Handle(const nlohmann::json &message) {
  std::shared_ptr<MossRealtimeEngine> engine;
  {
    std::lock_guard<std::mutex> lock(engine_mutex_);
    if (closed_) {
      return false;
    } else if (!engine_) {
      // Note (OpenAI): Handle has shared ownership; construction does not.
      std::weak_ptr<MossRealtimeSession> weak_self =
          std::static_pointer_cast<MossRealtimeSession>(shared_from_this());
      engine_ = std::make_shared<MossRealtimeEngine>(
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
      const nlohmann::json value = session->value("prompt", nlohmann::json());
      engine->UpdatePrompt(value.is_string()
                               ? std::optional(value.get<std::string>())
                               : std::nullopt);
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

void MossRealtimeSession::Close() {
  if (IsSendingOnThisThread()) {
    RealtimeConnection::Close();
    return;
  } else {
  }
  std::shared_ptr<MossRealtimeEngine> engine;
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

} // namespace moss
