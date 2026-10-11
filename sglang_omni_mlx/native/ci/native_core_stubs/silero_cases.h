// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "omni_native_core.h"
#include "silero_backend.h"

#include <cassert>
#include <chrono>
#include <cstring>
#include <future>
#include <memory>

namespace omni_test {

inline constexpr OmniSileroSettings SILERO_SETTINGS{0.5f, 0, 0, 0};
inline constexpr std::chrono::seconds SILERO_BARRIER_TIMEOUT_SECONDS{5};
using SileroModel =
    std::unique_ptr<OmniSileroHandle, decltype(&omni_silero_destroy)>;
using SileroStream =
    std::unique_ptr<OmniSileroStream, decltype(&omni_silero_stream_destroy)>;
using SileroRequest =
    std::unique_ptr<OmniSileroRequest, decltype(&omni_silero_request_destroy)>;

inline SileroModel CreateSileroModel() {
  char *error = reinterpret_cast<char *>(1);
  SileroModel model(
      omni_silero_create(std::filesystem::current_path().c_str(), &error),
      &omni_silero_destroy);
  assert(model && error == nullptr);
  assert(SileroState().loading_thread != std::this_thread::get_id());
  return model;
}

inline SileroStream CreateSileroStream(OmniSileroHandle *model) {
  char *error = reinterpret_cast<char *>(1);
  SileroStream stream(omni_silero_stream_create(model, &error),
                      &omni_silero_stream_destroy);
  assert(stream && error == nullptr);
  return stream;
}

inline SileroRequest CreateSileroRequest() {
  SileroRequest request(omni_silero_request_create(),
                        &omni_silero_request_destroy);
  assert(request);
  return request;
}

inline void CheckSileroError(char *error) {
  assert(error != nullptr && error[0] != '\0');
  assert(std::strstr(error, "PRIVATE") == nullptr);
  assert(std::strstr(error, "private/model") == nullptr);
  omni_string_free(error);
}

inline void CheckSileroCleared(const OmniSileroResult &result) {
  assert(result.timestamps == nullptr && result.timestamp_count == 0);
}

inline void CheckSileroCleared(const OmniSileroStreamResult &result) {
  assert(result.probabilities == nullptr && result.probability_count == 0);
  assert(result.processed_sample_count == 0);
}

inline void CheckSileroOfflineSuccess(OmniSileroHandle *model,
                                      size_t sample_count = 513) {
  auto request = CreateSileroRequest();
  const std::vector<float> samples(sample_count, 0.75f);
  OmniSileroResult result{reinterpret_cast<OmniSileroTimestamp *>(1), 9};
  char *error = reinterpret_cast<char *>(1);
  assert(omni_silero_speech_timestamps(model, request.get(), samples.data(),
                                       samples.size(), &SILERO_SETTINGS,
                                       &result, &error) == 1);
  assert(error == nullptr && result.timestamp_count == 1);
  assert(result.timestamps[0].start_sample == 0);
  assert(result.timestamps[0].end_sample == static_cast<int64_t>(sample_count));
  omni_silero_result_free(&result);
  CheckSileroCleared(result);
  omni_silero_result_free(&result);
}

inline void CheckSileroPush(OmniSileroStream *stream, uint64_t audio_sequence,
                            size_t sample_count,
                            uint64_t processed_sample_count,
                            const std::vector<float> &probabilities,
                            float sample = 0.25f) {
  const std::vector<float> samples(sample_count, sample);
  OmniSileroStreamResult result{reinterpret_cast<float *>(1), 9, 9};
  uint64_t accepted_sequence = UINT64_MAX;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_silero_stream_push(stream, audio_sequence, samples.data(),
                                 samples.size(), &accepted_sequence, &result,
                                 &error) == 1);
  assert(error == nullptr && accepted_sequence == audio_sequence);
  assert(result.processed_sample_count == processed_sample_count);
  assert(result.probability_count == probabilities.size());
  assert((result.probabilities == nullptr) == probabilities.empty());
  for (size_t i = 0; i < probabilities.size(); ++i) {
    assert(result.probabilities[i] == probabilities[i]);
  }
  omni_silero_stream_result_free(&result);
  CheckSileroCleared(result);
  omni_silero_stream_result_free(&result);
}

inline void CheckSileroFinish(OmniSileroStream *stream,
                              uint64_t processed_sample_count,
                              const std::vector<float> &probabilities) {
  OmniSileroStreamResult result{reinterpret_cast<float *>(1), 9, 9};
  char *error = reinterpret_cast<char *>(1);
  assert(omni_silero_stream_finish(stream, &result, &error) == 1);
  assert(error == nullptr);
  assert(result.processed_sample_count == processed_sample_count);
  assert(result.probability_count == probabilities.size());
  assert((result.probabilities == nullptr) == probabilities.empty());
  for (size_t i = 0; i < probabilities.size(); ++i) {
    assert(result.probabilities[i] == probabilities[i]);
  }
  omni_silero_stream_result_free(&result);
  CheckSileroCleared(result);
}

inline void CheckSileroDrain(OmniSileroStream *stream) {
  char *error = reinterpret_cast<char *>(1);
  assert(omni_silero_stream_drain(stream, &error) == 1 && error == nullptr);
}

inline void WaitForSileroFeed() {
  auto &backend = SileroState();
  std::unique_lock<std::mutex> lock(backend.mutex);
  assert(backend.changed.wait_for(lock, SILERO_BARRIER_TIMEOUT_SECONDS,
                                  [&] { return backend.active_count == 1; }));
}

inline void ReleaseSileroFeed() {
  auto &backend = SileroState();
  std::lock_guard<std::mutex> lock(backend.mutex);
  backend.release_feed = true;
  backend.changed.notify_all();
}

inline void CheckSileroPushRejected(OmniSileroStream *stream,
                                    uint64_t audio_sequence = 1) {
  const float sample = 0.25f;
  uint64_t accepted_sequence = UINT64_MAX;
  OmniSileroStreamResult result{reinterpret_cast<float *>(1), 9, 9};
  char *error = reinterpret_cast<char *>(1);
  assert(omni_silero_stream_push(stream, audio_sequence, &sample, 1,
                                 &accepted_sequence, &result, &error) == 0);
  assert(accepted_sequence == 0);
  CheckSileroCleared(result);
  CheckSileroError(error);
}

} // namespace omni_test
