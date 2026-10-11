// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "realtime.h"

namespace qwen3_asr::realtime_test {
void require(bool condition, const std::string &message);
std::string pcm16_base64(const std::vector<int16_t> &samples);

struct Recording {
  DecodeScript script;
  Qwen3ASRTranscriber transcriber{script};
  TranscriptionWorker worker{[] {}};
  std::mutex events_mutex;
  nlohmann::json events = nlohmann::json::array();
  nlohmann::json returns = nlohmann::json::array();

  void drain();
  void record(nlohmann::json event);
  nlohmann::json snapshot();
};

struct HttpSession {
  Recording recording;
  std::shared_ptr<RealtimeSession> session;

  explicit HttpSession(RealtimeSettings settings = {100, 100, 100});
  ~HttpSession();
  void handle(const nlohmann::json &message);
  void append(const std::vector<int16_t> &samples);
  void update(const nlohmann::json &language);
  void commit();
  void finish();
};

nlohmann::json run_http_case(const std::string &case_name);
#ifndef OMNI_REALTIME_BASELINE
nlohmann::json run_engine_case(const std::string &case_name);
#endif
} // namespace qwen3_asr::realtime_test
