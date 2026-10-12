// SPDX-License-Identifier: Apache-2.0
#include "support.h"

namespace speaker_test {
std::vector<float> samples(size_t sample_count, size_t start_sample) {
  constexpr int PCM16_FULL_SCALE = 32768;
  constexpr int PCM16_VALUE_COUNT = 65536;
  std::vector<float> audio(sample_count);
  for (size_t i = 0; i < sample_count; ++i) {
    audio[i] = static_cast<float>(
                   static_cast<int>((i + start_sample) % PCM16_VALUE_COUNT) -
                   PCM16_FULL_SCALE) /
               PCM16_FULL_SCALE;
  }
  return audio;
}
std::string pcm16(const std::vector<float> &samples) {
  constexpr char BASE64_ALPHABET[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::vector<uint8_t> bytes;
  for (const float sample : samples) {
    const uint16_t value =
        static_cast<uint16_t>(static_cast<int16_t>(sample * 32768.0f));
    bytes.push_back(value & 255);
    bytes.push_back(value >> 8);
  }
  std::string encoded;
  for (size_t i = 0; i < bytes.size(); i += 3) {
    const uint32_t value = (bytes[i] << 16) |
                           (i + 1 < bytes.size() ? bytes[i + 1] << 8 : 0) |
                           (i + 2 < bytes.size() ? bytes[i + 2] : 0);
    encoded += BASE64_ALPHABET[(value >> 18) & 63];
    encoded += BASE64_ALPHABET[(value >> 12) & 63];
    encoded += i + 1 < bytes.size() ? BASE64_ALPHABET[(value >> 6) & 63] : '=';
    encoded += i + 2 < bytes.size() ? BASE64_ALPHABET[value & 63] : '=';
  }
  return encoded;
}
void drain(qwen3_asr::TranscriptionWorker &worker) {
  worker.Transcribe(
      [](const std::atomic<bool> &) {
        return qwen3_asr::TranscriptionResult{};
      },
      qwen3_asr::NewCancelFlag());
}
bool EventLog::send(const std::string &serialized) {
  nlohmann::ordered_json event = nlohmann::ordered_json::parse(serialized);
  require(event.at("event_id").get<std::string>().size() == 36,
          "Invalid event id");
  event["event_id"] = "<random-event-id>";
  if (blocks_preview && event.at("type") == "transcription.segment" &&
      !event.at("is_final").get<bool>()) {
    publication_gate.block();
  } else {
  }
  {
    std::lock_guard<std::mutex> lock(mutex);
    events.push_back(std::move(event));
  }
  if (closes_in_sender) {
    connection.lock()->Close();
  } else {
  }
  return true;
}
nlohmann::ordered_json EventLog::snapshot() {
  std::lock_guard<std::mutex> lock(mutex);
  return events;
}
HttpFixture::HttpFixture(Family family, int sampling_rate, double frame_seconds)
    : nemotron_model(script, sampling_rate, frame_seconds) {
  const auto sender = [this](const std::string &serialized) {
    return log.send(serialized);
  };
  if (family == Family::kMoss) {
    session =
        std::make_shared<moss::MossRealtimeSession>(worker, moss_model, sender);
  } else {
    session = std::make_shared<nemotron::NemotronRealtimeSession>(
        worker, nemotron_model, sender);
  }
  log.connection = session;
}
HttpFixture::~HttpFixture() {
  script.model_gate.release();
  log.publication_gate.release();
  session->Close();
  drain(worker);
}
void HttpFixture::handle(const nlohmann::json &message) {
  returns.push_back(session->Handle(message));
}
void HttpFixture::append(size_t sample_count, size_t start_sample) {
  handle({{"type", "input_audio_buffer.append"},
          {"audio", pcm16(samples(sample_count, start_sample))}});
}
nlohmann::ordered_json HttpFixture::trace() {
  drain(worker);
  return {{"events", log.snapshot()},
          {"calls", script.snapshot()},
          {"returns", returns}};
}
} // namespace speaker_test
