// SPDX-License-Identifier: Apache-2.0
#include "silero_cases.h"

#include <cmath>
#include <limits>

namespace omni_test {
namespace {

void StreamInvalid() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  CheckSileroPush(stream.get(), 1, 511, 0, {});
  const float sample = 0.25f;
  struct InvalidInput {
    OmniSileroStream *stream;
    uint64_t audio_sequence;
    const float *samples;
    size_t sample_count;
    bool has_acknowledgement;
    bool has_result;
  };
  for (const auto &input : std::vector<InvalidInput>{
           {nullptr, 2, &sample, 1, true, true},
           {stream.get(), 2, nullptr, 1, true, true},
           {stream.get(), 2, &sample, 0, true, true},
           {stream.get(), 2, &sample, OMNI_SILERO_MAX_CHUNK_SAMPLES + 1, true,
            true},
           {stream.get(), 2, &sample, std::numeric_limits<size_t>::max(), true,
            true},
           {stream.get(), 0, &sample, 1, true, true},
           {stream.get(), 1, &sample, 1, true, true},
           {stream.get(), 3, &sample, 1, true, true},
           {stream.get(), UINT64_MAX, &sample, 1, true, true},
           {stream.get(), 2, &sample, 1, false, true},
           {stream.get(), 2, &sample, 1, true, false}}) {
    uint64_t accepted_sequence = UINT64_MAX;
    OmniSileroStreamResult result{reinterpret_cast<float *>(1), 9, 9};
    char *error = reinterpret_cast<char *>(1);
    assert(omni_silero_stream_push(
               input.stream, input.audio_sequence, input.samples,
               input.sample_count,
               input.has_acknowledgement ? &accepted_sequence : nullptr,
               input.has_result ? &result : nullptr, &error) == 0);
    if (input.has_acknowledgement) {
      assert(accepted_sequence == 0);
    } else {
    }
    if (input.has_result) {
      CheckSileroCleared(result);
    } else {
    }
    CheckSileroError(error);
  }
  for (float nonfinite : {NAN, INFINITY, -INFINITY}) {
    for (size_t position : {size_t{0}, size_t{511}, size_t{31999}}) {
      std::vector<float> samples(32000, sample);
      samples[position] = nonfinite;
      uint64_t accepted_sequence = UINT64_MAX;
      OmniSileroStreamResult result{};
      assert(omni_silero_stream_push(stream.get(), 2, samples.data(),
                                     samples.size(), &accepted_sequence,
                                     &result, nullptr) == 0);
      assert(accepted_sequence == 0);
      CheckSileroCleared(result);
    }
  }
  assert(SileroState().frames.empty());
  assert(omni_silero_stream_finish(stream.get(), nullptr, nullptr) == 0);
  assert(omni_silero_stream_drain(stream.get(), nullptr) == 0);
  CheckSileroPush(stream.get(), 2, 1, 512, {0.25f});
  CheckSileroFinish(stream.get(), 512, {});
  CheckSileroDrain(stream.get());
  assert(omni_silero_stream_create(nullptr, nullptr) == nullptr);
  OmniSileroStreamResult result{reinterpret_cast<float *>(1), 9, 9};
  assert(omni_silero_stream_finish(nullptr, &result, nullptr) == 0);
  CheckSileroCleared(result);
  assert(omni_silero_stream_drain(nullptr, nullptr) == 0);
  omni_silero_stream_cancel(nullptr);
  omni_silero_stream_destroy(nullptr);
  omni_silero_stream_result_free(nullptr);
}

void StreamSequenceAndPadding() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  CheckSileroPushRejected(stream.get(), 0);
  CheckSileroPushRejected(stream.get(), 2);
  CheckSileroPush(stream.get(), 1, 511, 0, {});
  CheckSileroPushRejected(stream.get(), 1);
  CheckSileroPush(stream.get(), 2, 2, 512, {0.25f});
  CheckSileroPushRejected(stream.get(), 4);
  CheckSileroPush(stream.get(), 3, 1024, 1536, {0.375f, 0.5f});
  CheckSileroFinish(stream.get(), 2048, {0.625f});
  CheckSileroFinish(stream.get(), 2048, {});
  CheckSileroPushRejected(stream.get(), 4);
  auto &backend = SileroState();
  assert(backend.frames.size() == 4);
  for (size_t i = 0; i < 2048; ++i) {
    assert(backend.frames[i / 512][i % 512] == (i < 1537 ? 0.25f : 0.0f));
  }
  CheckSileroDrain(stream.get());
  CheckSileroDrain(stream.get());
  assert(backend.live_array_count == 1);
  CheckSileroFinish(stream.get(), 2048, {});
  stream.reset();
  auto empty = CreateSileroStream(model.get());
  CheckSileroFinish(empty.get(), 0, {});
  CheckSileroFinish(empty.get(), 0, {});
  CheckSileroDrain(empty.get());
  assert(backend.frames.size() == 4);
}

void StreamStateIsolation() {
  auto model = CreateSileroModel();
  auto first = CreateSileroStream(model.get());
  auto second = CreateSileroStream(model.get());
  CheckSileroPush(first.get(), 1, 511, 0, {}, 0.25f);
  CheckSileroPush(second.get(), 1, 512, 512, {0.5f}, 0.5f);
  CheckSileroOfflineSuccess(model.get());
  CheckSileroPush(first.get(), 2, 2, 512, {0.25f}, 0.25f);
  CheckSileroPush(second.get(), 2, 512, 1024, {0.625f}, 0.5f);
  CheckSileroFinish(first.get(), 1024, {0.375f});
  CheckSileroDrain(first.get());
  CheckSileroPush(second.get(), 3, 512, 1536, {0.75f}, 0.5f);
  CheckSileroFinish(second.get(), 1536, {});
  CheckSileroDrain(second.get());
  assert(SileroState().load_count == 1);
}

void ContinualStream() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  const std::vector<float> samples(OMNI_SILERO_MAX_CHUNK_SAMPLES, 0.25f);
  uint64_t received_sample_count = 0;
  for (uint64_t audio_sequence = 1; audio_sequence <= 20; ++audio_sequence) {
    uint64_t accepted_sequence = UINT64_MAX;
    OmniSileroStreamResult result{};
    const uint64_t previous_frame_count = received_sample_count / 512;
    received_sample_count += samples.size();
    assert(omni_silero_stream_push(stream.get(), audio_sequence, samples.data(),
                                   samples.size(), &accepted_sequence, &result,
                                   nullptr) == 1);
    assert(accepted_sequence == audio_sequence);
    assert(result.processed_sample_count == received_sample_count / 512 * 512);
    assert(result.probability_count ==
           received_sample_count / 512 - previous_frame_count);
    assert(result.probability_count <= (samples.size() + 511) / 512);
    for (size_t i = 0; i < result.probability_count; ++i) {
      assert(std::isfinite(result.probabilities[i]));
      assert(result.probabilities[i] >= 0 && result.probabilities[i] <= 1);
    }
    omni_silero_stream_result_free(&result);
    assert(SileroState().live_array_count == 3);
  }
  assert(received_sample_count > OMNI_SILERO_MAX_OFFLINE_SAMPLES);
  CheckSileroFinish(stream.get(), received_sample_count, {});
  CheckSileroDrain(stream.get());
  assert(SileroState().live_array_count == 1);
}

void StreamLeaseLimit() {
  auto model = CreateSileroModel();
  std::vector<SileroStream> streams;
  for (size_t i = 0; i < OMNI_SILERO_MAX_STREAMS; ++i) {
    streams.push_back(CreateSileroStream(model.get()));
  }
  char *error = reinterpret_cast<char *>(1);
  assert(omni_silero_stream_create(model.get(), &error) == nullptr);
  CheckSileroError(error);
  streams.pop_back();
  streams.push_back(CreateSileroStream(model.get()));
  for (auto &stream : streams) {
    CheckSileroPush(stream.get(), 1, 512, 512, {0.25f});
  }
  assert(SileroState().load_count == 1);
  streams.clear();
  assert(SileroState().live_array_count == 1);
  CheckSileroOfflineSuccess(model.get());
}

void StreamResultOwnership() {
  auto model = CreateSileroModel();
  auto stream = CreateSileroStream(model.get());
  OmniSileroStreamResult first{};
  OmniSileroStreamResult second{};
  std::vector<float> samples(512, 0.25f);
  uint64_t accepted_sequence = 0;
  assert(omni_silero_stream_push(stream.get(), 1, samples.data(),
                                 samples.size(), &accepted_sequence, &first,
                                 nullptr) == 1);
  samples[0] = 0.5f;
  assert(omni_silero_stream_push(stream.get(), 2, samples.data(),
                                 samples.size(), &accepted_sequence, &second,
                                 nullptr) == 1);
  assert(first.probabilities != second.probabilities);
  assert(first.probabilities[0] == 0.25f);
  assert(second.probabilities[0] == 0.625f);
  first.probabilities[0] = 0;
  stream.reset();
  model.reset();
  assert(second.probabilities[0] == 0.625f);
  omni_silero_stream_result_free(&first);
  omni_silero_stream_result_free(&second);
  CheckSileroCleared(first);
  CheckSileroCleared(second);
  omni_silero_stream_result_free(&second);
}

} // namespace

void RunSileroStreamCase(const std::string &test) {
  if (test == "silero_stream_invalid") {
    StreamInvalid();
  } else if (test == "silero_stream_sequence_padding") {
    StreamSequenceAndPadding();
  } else if (test == "silero_stream_isolation") {
    StreamStateIsolation();
  } else if (test == "silero_stream_continual") {
    ContinualStream();
  } else if (test == "silero_stream_limit") {
    StreamLeaseLimit();
  } else if (test == "silero_stream_ownership") {
    StreamResultOwnership();
  } else {
    assert(false && "Unknown Silero stream test");
  }
}

} // namespace omni_test
