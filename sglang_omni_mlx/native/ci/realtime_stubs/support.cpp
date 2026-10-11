// SPDX-License-Identifier: Apache-2.0
#include "support.h"

#include <algorithm>
#include <stdexcept>

namespace qwen3_asr::realtime_test {
void require(bool condition, const std::string &message) {
  if (!condition) {
    throw std::runtime_error(message);
  } else {
  }
}

std::string pcm16_base64(const std::vector<int16_t> &samples) {
  static constexpr char ALPHABET[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::vector<uint8_t> bytes;
  for (const int16_t sample : samples) {
    const auto unsigned_sample = static_cast<uint16_t>(sample);
    bytes.push_back(unsigned_sample & 0xFF);
    bytes.push_back(unsigned_sample >> 8);
  }
  std::string encoded;
  uint32_t accumulator = 0;
  int bit_count = 0;
  for (const uint8_t byte : bytes) {
    accumulator = (accumulator << 8) | byte;
    bit_count += 8;
    while (bit_count >= 6) {
      bit_count -= 6;
      encoded.push_back(ALPHABET[(accumulator >> bit_count) & 63]);
    }
  }
  if (bit_count != 0) {
    encoded.push_back(ALPHABET[(accumulator << (6 - bit_count)) & 63]);
  } else {
  }
  while (encoded.size() % 4 != 0) {
    encoded.push_back('=');
  }
  return encoded;
}

void Recording::drain() {
  // Note (OpenAI): a FIFO fence waits for real worker completions, not wall
  // time.
  worker.Transcribe(
      [](const std::atomic<bool> &) { return TranscriptionResult{}; },
      NewCancelFlag());
}

void Recording::record(nlohmann::json event) {
  std::lock_guard<std::mutex> lock(events_mutex);
  events.push_back(std::move(event));
}

nlohmann::json Recording::snapshot() {
  drain();
  std::scoped_lock lock(events_mutex, script.mutex);
  require(script.calls.size() == script.steps.size(),
          "Not all scripted decodes were consumed");
  return {{"events", events},
          {"returns", returns},
          {"calls", script.calls},
          {"prefixes", script.prefixes}};
}

HttpSession::HttpSession(RealtimeSettings settings) {
  session = std::make_shared<RealtimeSession>(
      recording.worker, recording.transcriber, settings,
      [this](const std::string &serialized_event) {
        nlohmann::json event = nlohmann::json::parse(serialized_event);
        const std::string event_id = event.at("event_id");
        require(event_id.size() == 36 && event_id.rfind("evt_", 0) == 0 &&
                    std::all_of(event_id.begin() + 4, event_id.end(),
                                [](char digit) {
                                  return (digit >= '0' && digit <= '9') ||
                                         (digit >= 'a' && digit <= 'f');
                                }),
                "Invalid wire event_id");
        event.erase("event_id");
        recording.record(std::move(event));
        return true;
      });
}

HttpSession::~HttpSession() {
  session->Close();
  recording.script.release();
  recording.drain();
}

void HttpSession::handle(const nlohmann::json &message) {
  recording.returns.push_back(session->Handle(message));
}
void HttpSession::append(const std::vector<int16_t> &samples) {
  handle({{"type", "input_audio_buffer.append"},
          {"audio", pcm16_base64(samples)}});
}
void HttpSession::update(const nlohmann::json &language) {
  handle({{"type", "session.update"},
          {"session", {{"turn_detection", nullptr}, {"language", language}}}});
}
void HttpSession::commit() { handle({{"type", "input_audio_buffer.commit"}}); }
void HttpSession::finish() { handle({{"type", "transcription.done"}}); }
} // namespace qwen3_asr::realtime_test
