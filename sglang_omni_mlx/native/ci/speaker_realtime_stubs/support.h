// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "moss_realtime.h"
#include "nemotron_realtime.h"

namespace speaker_test {
enum class Family { kMoss, kNemotron };
std::vector<float> samples(size_t sample_count, size_t start_sample = 0);
std::string pcm16(const std::vector<float> &samples);
void drain(qwen3_asr::TranscriptionWorker &worker);
class EventLog {
public:
  std::mutex mutex;
  nlohmann::ordered_json events = nlohmann::ordered_json::array();
  Gate publication_gate;
  bool blocks_preview = false;
  bool closes_in_sender = false;
  std::weak_ptr<qwen3_asr::RealtimeConnection> connection;
  bool send(const std::string &serialized);
  nlohmann::ordered_json snapshot();
};
class HttpFixture {
public:
  DecodeScript script;
  moss::MossTranscriber moss_model{script};
  nemotron::NemotronTranscriber nemotron_model;
  EventLog log;
  qwen3_asr::TranscriptionWorker worker{[] {}};
  std::shared_ptr<qwen3_asr::RealtimeConnection> session;
  nlohmann::ordered_json returns = nlohmann::ordered_json::array();
  explicit HttpFixture(Family family, int sampling_rate = 16000,
                       double frame_seconds = 0.08);
  ~HttpFixture();
  void handle(const nlohmann::json &message);
  void append(size_t sample_count, size_t start_sample = 0);
  nlohmann::ordered_json trace();
};
nlohmann::ordered_json http_case(Family family, const std::string &name);
nlohmann::ordered_json http_race_case(Family family, const std::string &name);
#ifndef SPEAKER_BASELINE
nlohmann::ordered_json engine_case(Family family, const std::string &name);
nlohmann::ordered_json engine_race_case(Family family, const std::string &name);
#endif
} // namespace speaker_test
