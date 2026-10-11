// SPDX-License-Identifier: Apache-2.0
#include "sortformer_cases.h"
#include "native_sortformer_worker.h"

#include <limits>

namespace omni_test {
namespace {

void DirectoriesAndSettings() {
  for (const char *directory : {static_cast<const char *>(nullptr), "",
                                "missing-private-model", __FILE__}) {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_sortformer_create(directory, &error) == nullptr);
    CheckSortformerError(error);
  }
  auto model = CreateSortformerModel();
  assert(omni_sortformer_stream_create(nullptr, &SORTFORMER_SETTINGS,
                                       nullptr) == nullptr);
  assert(omni_sortformer_stream_create(model.get(), nullptr, nullptr) ==
         nullptr);
  for (int field = 0; field < 5; ++field) {
    for (float value : {-1.0f, 4097.0f, std::numeric_limits<float>::infinity(),
                        std::numeric_limits<float>::quiet_NaN()}) {
      auto settings = SORTFORMER_SETTINGS;
      if (field == 0) {
        settings.threshold = value;
      } else if (field == 1) {
        settings.minimum_duration_seconds = value;
      } else if (field == 2) {
        settings.merge_gap_seconds = value;
      } else if (field == 3) {
        settings.speaker_cache_max_frames = value == -1.0f ? 0 : 4097;
      } else {
        settings.fifo_max_frames = value == -1.0f ? -1 : 4097;
      }
      char *error = nullptr;
      assert(omni_sortformer_stream_create(model.get(), &settings, &error) ==
             nullptr);
      CheckSortformerError(error);
    }
  }
  auto settings = SORTFORMER_SETTINGS;
  settings.speaker_cache_max_frames = 1123;
  auto *boundary =
      omni_sortformer_stream_create(model.get(), &settings, nullptr);
  assert(boundary != nullptr);
  omni_sortformer_stream_destroy(boundary);
  ++settings.speaker_cache_max_frames;
  assert(omni_sortformer_stream_create(model.get(), &settings, nullptr) ==
         nullptr);
  settings = {1.0f, 3600.0f, 3600.0f, 40, 0};
  assert(omni_sortformer_stream_create(model.get(), &settings, nullptr) ==
         nullptr);
  settings.speaker_cache_max_frames = 41;
  auto *explicit_stream =
      omni_sortformer_stream_create(model.get(), &settings, nullptr);
  assert(explicit_stream != nullptr);
  const float samples[] = {0.25f, 0.25f};
  OmniSortformerResult result{};
  uint64_t accepted = 0;
  assert(omni_sortformer_stream_push(explicit_stream, 1, samples, 2, &accepted,
                                     &result, nullptr) == 1);
  assert(result.segment_count == 0 && result.segments == nullptr);
  const auto &options = SortformerState().last_options;
  assert(options.threshold == 1 && options.min_duration == 3600 &&
         options.merge_gap == 3600);
  assert(options.spkcache_max == 41 && options.fifo_max == 0);
  omni_sortformer_result_free(&result);
  omni_sortformer_stream_destroy(explicit_stream);
}

void InvalidInputAndSequence() {
  auto model = CreateSortformerModel();
  auto stream = CreateSortformerStream(model.get());
  CheckSortformerRejected(stream.get(), 0);
  CheckSortformerRejected(stream.get(), 2);
  CheckSortformerRejected(stream.get(), UINT64_MAX);
  CheckSortformerRejected(stream.get(), 1, 0);
  CheckSortformerRejected(stream.get(), 1, 32001);
  for (float sample : {std::numeric_limits<float>::infinity(),
                       std::numeric_limits<float>::quiet_NaN()}) {
    uint64_t accepted = 9;
    OmniSortformerResult result{};
    assert(omni_sortformer_stream_push(stream.get(), 1, &sample, 1, &accepted,
                                       &result, nullptr) == 0);
    assert(accepted == 0);
    CheckSortformerCleared(result);
  }
  const float sample = 0.25f;
  uint64_t accepted = 0;
  OmniSortformerResult result{};
  assert(omni_sortformer_stream_push(stream.get(), 1, &sample, SIZE_MAX,
                                     &accepted, &result, nullptr) == 0);
  assert(omni_sortformer_stream_push(stream.get(), 1, nullptr, 1, &accepted,
                                     &result, nullptr) == 0);
  assert(omni_sortformer_stream_push(stream.get(), 1, &sample, 1, nullptr,
                                     &result, nullptr) == 0);
  assert(omni_sortformer_stream_push(stream.get(), 1, &sample, 1, &accepted,
                                     nullptr, nullptr) == 0);
  assert(omni_sortformer_stream_drain(stream.get(), nullptr) == 0);
  uint64_t sequence = 1;
  uint64_t frame_count = 0;
  for (size_t sample_count : {1, 2, 159, 160, 1279, 1280, 32000}) {
    result = PushSortformer(stream.get(), sequence, sample_count);
    frame_count += result.frame_count;
    assert(result.processed_frame_count == frame_count);
    omni_sortformer_result_free(&result);
    CheckSortformerRejected(stream.get(), sequence);
    ++sequence;
  }
  assert(SortformerState().feed_count == 7);
}

void OwnershipAndIsolation() {
  auto model = CreateSortformerModel();
  auto first = CreateSortformerStream(model.get());
  auto second = CreateSortformerStream(model.get());
  auto first_result = PushSortformer(first.get(), 1);
  auto second_result = PushSortformer(second.get(), 1);
  assert(first_result.processed_frame_count == 2 &&
         second_result.processed_frame_count == 2);
  assert(first_result.probabilities != second_result.probabilities);
  assert(first_result.segments != second_result.segments);
  first_result.probabilities[0] = 0;
  assert(second_result.probabilities[0] == 0.75f);
  omni_sortformer_stream_cancel(first.get());
  CheckSortformerRejected(first.get(), 2);
  auto next_result = PushSortformer(second.get(), 2);
  assert(next_result.processed_frame_count == 4);
  assert(next_result.segments[0].start_seconds ==
         static_cast<double>(2 * 0.08f));
  assert(next_result.segments[0].end_seconds ==
         static_cast<double>(2 * 0.08f + 2 * 0.08f));
  first.reset();
  second.reset();
  model.reset();
  assert(first_result.probabilities[0] == 0 &&
         second_result.probabilities[0] == 0.75f);
  assert(first_result.segments[3].speaker_index == 3);
  for (auto *result : {&first_result, &second_result, &next_result}) {
    omni_sortformer_result_free(result);
    CheckSortformerCleared(*result);
    omni_sortformer_result_free(result);
  }
}

void LimitsAndFinish() {
  auto model = CreateSortformerModel();
  std::vector<SortformerStreamLease> streams;
  for (int i = 0; i < OMNI_SORTFORMER_MAX_STREAMS; ++i) {
    streams.push_back(CreateSortformerStream(model.get()));
    assert(omni_sortformer_stream_finish(streams.back().get(), nullptr) == 1);
    omni_sortformer_stream_cancel(streams.back().get());
    CheckSortformerDrain(streams.back().get());
    CheckSortformerDrain(streams.back().get());
    assert(omni_sortformer_stream_finish(streams.back().get(), nullptr) == 1);
    CheckSortformerRejected(streams.back().get());
  }
  assert(SortformerState().feed_count == 0);
  assert(omni_sortformer_stream_create(model.get(), &SORTFORMER_SETTINGS,
                                       nullptr) == nullptr);
  streams.pop_back();
  streams.push_back(CreateSortformerStream(model.get()));
  for (uint64_t sequence = 1; sequence <= 200; ++sequence) {
    auto result = PushSortformer(streams.back().get(), sequence, 32000);
    assert(result.processed_frame_count == sequence * 26);
    omni_sortformer_result_free(&result);
  }
  omni_sortformer_cancel(model.get());
  assert(omni_sortformer_stream_finish(streams.front().get(), nullptr) == 1);
  assert(omni_sortformer_stream_finish(streams.back().get(), nullptr) == 0);
  assert(omni_sortformer_stream_create(model.get(), &SORTFORMER_SETTINGS,
                                       nullptr) == nullptr);
}

void ModelCapAndCounters() {
  SortformerState().config.modules.spkcache_update_period = 1;
  auto model = CreateSortformerModel();
  auto stream = CreateSortformerStream(model.get());
  CheckSortformerRejected(stream.get(), 1, 1280);
  auto result = PushSortformer(stream.get(), 1, 1279);
  omni_sortformer_result_free(&result);
  // Note (OpenAI): seeded counter boundaries avoid huge audio/history tests.
  stream->accepted_audio_sequence = UINT64_MAX - 1;
  result = PushSortformer(stream.get(), UINT64_MAX, 1);
  omni_sortformer_result_free(&result);
  CheckSortformerRejected(stream.get(), UINT64_MAX, 1);
  auto overflow = CreateSortformerStream(model.get());
  overflow->processed_frame_count = std::numeric_limits<int>::max();
  const int feed_count = SortformerState().feed_count;
  CheckSortformerRejected(overflow.get(), 1, 1);
  overflow->processed_frame_count = 0;
  result = PushSortformer(overflow.get(), 1, 1);
  omni_sortformer_result_free(&result);
  assert(SortformerState().feed_count == feed_count + 1);
  SortformerState().initial_frame_count = std::numeric_limits<int>::max();
  auto actual_overflow = CreateSortformerStream(model.get());
  CheckSortformerRejected(actual_overflow.get(), 1, 1);
  CheckSortformerRejected(actual_overflow.get(), 1, 1);
  assert(SortformerState().feed_count == feed_count + 1);
  CheckSortformerDrain(actual_overflow.get());
  SortformerState().initial_frame_count = std::numeric_limits<int>::max() - 1;
  auto boundary = CreateSortformerStream(model.get());
  boundary->processed_frame_count = std::numeric_limits<int>::max() - 1;
  result = PushSortformer(boundary.get(), 1, 1);
  assert(result.processed_frame_count ==
         static_cast<uint64_t>(std::numeric_limits<int>::max()));
  omni_sortformer_result_free(&result);
  CheckSortformerRejected(boundary.get(), 2, 1);
  assert(SortformerState().feed_count == feed_count + 2);
  assert(omni_sortformer_stream_finish(boundary.get(), nullptr) == 1);
}

} // namespace

void RunSortformerCase(const std::string &test) {
  if (test == "sortformer_settings") {
    DirectoriesAndSettings();
  } else if (test == "sortformer_input_sequence") {
    InvalidInputAndSequence();
  } else if (test == "sortformer_ownership_isolation") {
    OwnershipAndIsolation();
  } else if (test == "sortformer_limits_finish") {
    LimitsAndFinish();
  } else if (test == "sortformer_cap_counters") {
    ModelCapAndCounters();
  } else {
    assert(false && "Unknown Sortformer case");
  }
}

} // namespace omni_test
