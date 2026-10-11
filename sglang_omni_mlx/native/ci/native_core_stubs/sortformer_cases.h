// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "omni_native_core.h"
#include "sortformer_backend.h"
#include "sortformer_config_fixture.h"

#include <cassert>
#include <chrono>
#include <cstring>
#include <future>
#include <memory>

namespace omni_test {

inline constexpr OmniSortformerSettings SORTFORMER_SETTINGS{0.5f, 0.0f, 0.18f,
                                                            188, 188};
using SortformerModelLease =
    std::unique_ptr<OmniSortformerHandle, decltype(&omni_sortformer_destroy)>;
using SortformerStreamLease =
    std::unique_ptr<OmniSortformerStream,
                    decltype(&omni_sortformer_stream_destroy)>;

inline SortformerModelLease CreateSortformerModel() {
  WriteSortformerConfig(SortformerState().config);
  char *error = reinterpret_cast<char *>(1);
  SortformerModelLease model(
      omni_sortformer_create(std::filesystem::current_path().c_str(), &error),
      &omni_sortformer_destroy);
  assert(model && error == nullptr);
  assert(SortformerState().loading_thread != std::this_thread::get_id());
  return model;
}

inline SortformerStreamLease
CreateSortformerStream(OmniSortformerHandle *model) {
  char *error = reinterpret_cast<char *>(1);
  SortformerStreamLease stream(
      omni_sortformer_stream_create(model, &SORTFORMER_SETTINGS, &error),
      &omni_sortformer_stream_destroy);
  assert(stream && error == nullptr);
  return stream;
}

inline void CheckSortformerError(char *error) {
  assert(error != nullptr && error[0] != '\0');
  assert(std::strstr(error, "PRIVATE") == nullptr);
  assert(std::strstr(error, "private/model") == nullptr);
  omni_string_free(error);
}

inline void CheckSortformerCleared(const OmniSortformerResult &result) {
  assert(result.probabilities == nullptr && result.probability_count == 0);
  assert(result.frame_count == 0 && result.speaker_count == 0 &&
         result.frame_duration_seconds == 0);
  assert(result.segments == nullptr && result.segment_count == 0 &&
         result.processed_frame_count == 0);
}

inline OmniSortformerResult PushSortformer(OmniSortformerStream *stream,
                                           uint64_t sequence,
                                           size_t sample_count = 1280) {
  const std::vector<float> samples(sample_count, 0.25f);
  OmniSortformerResult result{};
  uint64_t accepted_sequence = UINT64_MAX;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_stream_push(stream, sequence, samples.data(),
                                     sample_count, &accepted_sequence, &result,
                                     &error) == 1);
  assert(accepted_sequence == sequence && error == nullptr);
  assert(result.frame_count ==
         static_cast<int>((1 + sample_count / 160 + 7) / 8));
  assert(result.speaker_count == 4 &&
         result.probability_count == size_t(result.frame_count) * 4);
  assert(result.frame_duration_seconds == static_cast<double>(0.08f));
  assert(result.segment_count == 4);
  for (size_t i = 0; i < result.probability_count; ++i) {
    assert(result.probabilities[i] == 0.75f);
  }
  for (int i = 0; i < 4; ++i) {
    assert(result.segments[i].speaker_index == i);
  }
  return result;
}

inline void CheckSortformerRejected(OmniSortformerStream *stream,
                                    uint64_t sequence = 1,
                                    size_t sample_count = 1280) {
  const std::vector<float> samples(sample_count, 0.25f);
  OmniSortformerResult result{reinterpret_cast<float *>(1),
                              9,
                              9,
                              9,
                              9,
                              reinterpret_cast<OmniSortformerSegment *>(1),
                              9,
                              9};
  uint64_t accepted_sequence = UINT64_MAX;
  char *error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_stream_push(stream, sequence, samples.data(),
                                     sample_count, &accepted_sequence, &result,
                                     &error) == 0);
  assert(accepted_sequence == 0);
  CheckSortformerCleared(result);
  CheckSortformerError(error);
}

inline void CheckSortformerDrain(OmniSortformerStream *stream) {
  char *error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_stream_drain(stream, &error) == 1 && error == nullptr);
}

inline void WaitForSortformerFeed() {
  auto &backend = SortformerState();
  std::unique_lock<std::mutex> lock(backend.mutex);
  assert(backend.changed.wait_for(lock, std::chrono::seconds(5),
                                  [&] { return backend.active_count == 1; }));
}

inline void ReleaseSortformerFeed() {
  auto &backend = SortformerState();
  std::lock_guard<std::mutex> lock(backend.mutex);
  backend.release_feed = true;
  backend.changed.notify_all();
}

} // namespace omni_test
