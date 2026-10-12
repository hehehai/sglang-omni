// SPDX-License-Identifier: Apache-2.0
#include "realtime.h"

#include <iostream>
#include <random>
#include <utility>

namespace qwen3_asr {

namespace {

constexpr float kPcm16FullScale = 32768.0f;

std::optional<std::vector<uint8_t>> DecodeBase64(const std::string &text) {
  // Note (Jiaxin Deng): matches Python's b64decode(validate=False), which
  // drops characters outside the alphabet but still checks the padding.
  std::string clean;
  for (const char c : text) {
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=') {
      clean.push_back(c);
    } else {
    }
  }
  size_t padding = 0;
  while (!clean.empty() && clean.back() == '=') {
    clean.pop_back();
    ++padding;
  }
  const size_t remainder = clean.size() % 4;
  if (clean.find('=') != std::string::npos || remainder == 1 ||
      (remainder != 0 && padding < 4 - remainder)) {
    return std::nullopt;
  } else {
  }
  const auto value = [](char c) -> uint32_t {
    if (c >= 'A' && c <= 'Z')
      return c - 'A';
    if (c >= 'a' && c <= 'z')
      return c - 'a' + 26;
    if (c >= '0' && c <= '9')
      return c - '0' + 52;
    return c == '+' ? 62 : 63;
  };
  std::vector<uint8_t> bytes;
  uint32_t buffer = 0;
  int bits = 0;
  for (const char c : clean) {
    buffer = (buffer << 6) | value(c);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push_back(static_cast<uint8_t>((buffer >> bits) & 0xFF));
    } else {
    }
  }
  return bytes;
}

std::string NewEventId() {
  static thread_local std::mt19937_64 generator{std::random_device{}()};
  static constexpr char kHex[] = "0123456789abcdef";
  std::string id = "evt_";
  for (int i = 0; i < 32; ++i)
    id.push_back(kHex[generator() % 16]);
  return id;
}

} // namespace

RealtimeConnection::RealtimeConnection(Sender sender)
    : sender_(std::move(sender)) {}

bool RealtimeConnection::IsSendingOnThisThread() {
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
  return sending_thread_ == std::this_thread::get_id();
}

void RealtimeConnection::Send(nlohmann::ordered_json event) {
  std::exception_ptr failure;
  bool close_after_delivery;
  {
    std::lock_guard<std::recursive_mutex> lock(send_mutex_);
    if (closed_) {
      return;
    } else {
    }
    event_index_ += 1;
    event["event_id"] = NewEventId();
    event["event_index"] = event_index_;
    const std::string serialized = event.dump();
    sending_thread_ = std::this_thread::get_id();
    try {
      if (!sender_(serialized)) {
        closed_ = true;
      } else {
      }
    } catch (...) {
      failure = std::current_exception();
    }
    sending_thread_ = {};
    close_after_delivery = std::exchange(close_after_delivery_, false);
  }
  if (close_after_delivery) {
    // Note (OpenAI): direct HTTP errors must not invert transport/engine locks.
    Close();
  } else {
  }
  if (failure) {
    std::rethrow_exception(failure);
  } else {
  }
}

void RealtimeConnection::SendError(const std::string &type,
                                   const std::string &code,
                                   const std::string &message) {
  Send({{"type", "error"},
        {"error", {{"type", type}, {"code", code}, {"message", message}}}});
}

void RealtimeConnection::Close() {
  cancel_->store(true);
  std::lock_guard<std::recursive_mutex> lock(send_mutex_);
  closed_ = true;
  if (sending_thread_ == std::this_thread::get_id()) {
    close_after_delivery_ = true;
  } else {
  }
}

std::optional<std::vector<float>>
RealtimeConnection::AppendedSamples(const nlohmann::json &audio) {
  const std::optional<std::vector<uint8_t>> pcm =
      audio.is_string() ? DecodeBase64(audio.get<std::string>()) : std::nullopt;
  if (!pcm.has_value() || pcm->empty() || pcm->size() % 2 != 0) {
    SendError("invalid_request_error", "invalid_audio",
              "Audio must be base64 PCM16.");
    return std::nullopt;
  } else {
  }
  std::vector<float> samples;
  samples.reserve(pcm->size() / 2);
  for (size_t i = 0; i + 1 < pcm->size(); i += 2) {
    const int16_t value =
        static_cast<int16_t>((*pcm)[i] | ((*pcm)[i + 1] << 8));
    samples.push_back(static_cast<float>(value) / kPcm16FullScale);
  }
  return samples;
}

std::optional<nlohmann::json>
RealtimeConnection::ManualTurnSession(const nlohmann::json &message) {
  const nlohmann::json session = message.value("session", nlohmann::json());
  if (!session.is_object() || (session.contains("turn_detection") &&
                               !session["turn_detection"].is_null())) {
    SendError("invalid_request_error", "unsupported_session",
              "Only manual turns are supported.");
    return std::nullopt;
  } else {
    return session;
  }
}

void RealtimeConnection::ReportDecodeFailure(std::exception_ptr error) {
  try {
    std::rethrow_exception(error);
  } catch (const TranscriptionCancelled &) {
    return;
  } catch (const std::exception &failure) {
    // Note (Jiaxin Deng): log the type alone, never the audio or text.
    std::cerr << "realtime decode failed: " << typeid(failure).name() << "\n";
  } catch (...) {
    std::cerr << "realtime decode failed\n";
  }
  SendError("server_error", "transcription_failed", "Transcription failed.");
}

RealtimeSession::RealtimeSession(TranscriptionWorker &worker,
                                 const Qwen3ASRTranscriber &transcriber,
                                 RealtimeSettings settings, Sender sender)
    : RealtimeConnection(std::move(sender)), worker_(worker),
      transcriber_(transcriber), settings_(settings) {}

bool RealtimeSession::Handle(const nlohmann::json &message) {
  if (!engine_) {
    // Note (Codex): Handle runs after shared ownership exists, unlike
    // construction.
    std::weak_ptr<RealtimeSession> weak_self =
        std::static_pointer_cast<RealtimeSession>(shared_from_this());
    engine_ = std::make_shared<RealtimeEngine>(
        worker_, transcriber_, settings_,
        [weak_self](const RealtimeEvent &event) {
          if (const auto self = weak_self.lock()) {
            self->SendEvent(event);
          } else {
          }
        },
        cancel_);
  } else {
  }
  const nlohmann::json type = message.value("type", nlohmann::json());
  if (type == "session.update") {
    const std::optional<nlohmann::json> session = ManualTurnSession(message);
    if (session.has_value()) {
      const nlohmann::json language =
          session->value("language", nlohmann::json());
      engine_->UpdateLanguage(language.is_string()
                                  ? std::optional(language.get<std::string>())
                                  : std::nullopt);
    } else {
    }
    return true;
  } else if (type == "input_audio_buffer.append") {
    std::optional<std::vector<float>> samples =
        AppendedSamples(message.value("audio", nlohmann::json()));
    if (samples.has_value()) {
      engine_->Append(std::move(*samples));
    } else {
    }
    return true;
  } else if (type == "input_audio_buffer.commit") {
    engine_->Commit();
    return true;
  } else if (type == "transcription.done") {
    engine_->Finish();
    return false;
  } else {
    SendError("invalid_request_error", "invalid_event", "Unknown event type.");
    return true;
  }
}

void RealtimeSession::SendEvent(const RealtimeEvent &event) {
  if (std::holds_alternative<RealtimeUpdated>(event)) {
    Send({{"type", "transcription_session.updated"}});
  } else if (const auto *segment = std::get_if<RealtimeSegment>(&event)) {
    Send({{"type", "transcription.segment"},
          {"segment_id", segment->segment_id},
          {"text", segment->text},
          {"is_final", segment->is_final}});
  } else if (const auto *completed = std::get_if<RealtimeCompleted>(&event)) {
    Send({{"type", "transcription.completed"}, {"text", completed->text}});
  } else {
    const auto &failure = std::get<RealtimeFailure>(event);
    SendError(failure.type, failure.code, failure.message);
  }
}

} // namespace qwen3_asr
