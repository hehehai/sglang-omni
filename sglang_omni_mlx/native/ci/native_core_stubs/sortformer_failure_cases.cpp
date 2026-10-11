// SPDX-License-Identifier: Apache-2.0
#include "sortformer_cases.h"

#include <limits>

namespace omni_test {
namespace {

void InvalidConfigurations() {
  auto &backend = SortformerState();
  const auto valid = backend.config;
  for (int field = 0; field < 27; ++field) {
    backend.config = valid;
    auto &config = backend.config;
    switch (field) {
    case 0:
      config.num_speakers = 3;
      break;
    case 1:
      config.modules.num_speakers = 0;
      break;
    case 2:
      config.modules.use_aosc = false;
      break;
    case 3:
      config.processor.sampling_rate = 0;
      break;
    case 4:
      config.processor.hop_length = std::numeric_limits<int>::max();
      break;
    case 5:
      config.fc_encoder.subsampling_factor = 4;
      break;
    case 6:
      config.modules.subsampling_factor = -1;
      break;
    case 7:
      config.processor.fft_size = -1;
      break;
    case 8:
      config.processor.window_length = 513;
      break;
    case 9:
      config.processor.feature_size = -1;
      break;
    case 10:
      config.processor.preemphasis = std::numeric_limits<float>::quiet_NaN();
      break;
    case 11:
      config.fc_encoder.hidden_size = 0;
      break;
    case 12:
      config.fc_encoder.num_attention_heads = 0;
      break;
    case 13:
      config.tf_encoder.d_model = -1;
      break;
    case 14:
      config.tf_encoder.max_source_positions = std::numeric_limits<int>::max();
      break;
    case 15:
      config.tf_encoder.max_source_positions = 188;
      break;
    case 16:
      config.tf_encoder.layer_norm_eps = std::numeric_limits<float>::infinity();
      break;
    case 17:
      config.modules.spkcache_len = 0;
      break;
    case 18:
      config.modules.spkcache_update_period = 0;
      break;
    case 19:
      config.modules.spkcache_update_period = 189;
      break;
    case 20:
      config.modules.chunk_left_context = -1;
      break;
    case 21:
      config.modules.fifo_len = std::numeric_limits<int>::max();
      break;
    case 22:
      config.modules.spkcache_sil_frames_per_spk = 48;
      break;
    case 23:
      config.modules.max_index = 1500;
      break;
    case 24:
      config.modules.pred_score_threshold = 0;
      break;
    case 25:
      config.modules.strong_boost_rate = std::numeric_limits<float>::infinity();
      break;
    case 26:
      config.modules.chunk_len = -1;
      break;
    }
    WriteSortformerConfig(config);
    char *error = nullptr;
    assert(omni_sortformer_create(std::filesystem::current_path().c_str(),
                                  &error) == nullptr);
    CheckSortformerError(error);
    assert(backend.load_count == 0 && backend.live_array_count == 0);
  }
  backend.config = valid;
  WriteSortformerConfig(valid);
  for (float duration :
       {0.0f, -1.0f, 0.1f, std::numeric_limits<float>::infinity(),
        std::numeric_limits<float>::quiet_NaN()}) {
    backend.frame_duration_seconds = duration;
    assert(omni_sortformer_create(std::filesystem::current_path().c_str(),
                                  nullptr) == nullptr);
    assert(backend.live_array_count == 0);
  }
  backend.frame_duration_seconds = 0.08f;
  auto model = CreateSortformerModel();
}

void ModelExceptions() {
  auto &backend = SortformerState();
  for (auto failure : {Failure::kStandard, Failure::kNonstandard}) {
    backend.load_failure = failure;
    char *error = nullptr;
    assert(omni_sortformer_create(std::filesystem::current_path().c_str(),
                                  &error) == nullptr);
    CheckSortformerError(error);
    assert(backend.live_array_count == 0);
  }
  backend.load_failure = Failure::kNone;
  auto model = CreateSortformerModel();
  for (auto failure : {Failure::kStandard, Failure::kNonstandard}) {
    backend.init_failure = failure;
    char *error = nullptr;
    assert(omni_sortformer_stream_create(model.get(), &SORTFORMER_SETTINGS,
                                         &error) == nullptr);
    CheckSortformerError(error);
    backend.init_failure = Failure::kNone;
    auto stream = CreateSortformerStream(model.get());
    backend.feed_failure = failure;
    CheckSortformerRejected(stream.get());
    CheckSortformerDrain(stream.get());
    backend.feed_failure = Failure::kNone;
    CheckSortformerRejected(stream.get());
    assert(omni_sortformer_stream_finish(stream.get(), nullptr) == 0);
  }
  auto reusable = CreateSortformerStream(model.get());
  auto result = PushSortformer(reusable.get(), 1);
  omni_sortformer_result_free(&result);
}

void InvalidResults() {
  auto model = CreateSortformerModel();
  auto &backend = SortformerState();
  for (int fault = static_cast<int>(SortformerOutputFault::NegativeFrames);
       fault <= static_cast<int>(SortformerOutputFault::LargeFifo); ++fault) {
    auto stream = CreateSortformerStream(model.get());
    backend.output_fault = static_cast<SortformerOutputFault>(fault);
    CheckSortformerRejected(stream.get());
    const int feed_count = backend.feed_count;
    backend.output_fault = SortformerOutputFault::None;
    CheckSortformerRejected(stream.get());
    assert(backend.feed_count == feed_count);
    assert(omni_sortformer_stream_finish(stream.get(), nullptr) == 0);
    omni_sortformer_stream_cancel(stream.get());
    CheckSortformerDrain(stream.get());
  }
  auto reusable = CreateSortformerStream(model.get());
  auto result = PushSortformer(reusable.get(), 1);
  omni_sortformer_result_free(&result);
}

void AllocationFailures() {
#ifdef OMNI_ABI_WRAP_MALLOC
  auto model = CreateSortformerModel();
  auto stream = CreateSortformerStream(model.get());
  const std::vector<float> samples(1009, 0.25f);
  OmniSortformerResult result{};
  uint64_t accepted = UINT64_MAX;
  char *error = nullptr;
  new_failure_byte_count = samples.size() * sizeof(float);
  assert(omni_sortformer_stream_push(stream.get(), 1, samples.data(),
                                     samples.size(), &accepted, &result,
                                     &error) == 0);
  assert(new_failure_byte_count == 0 && accepted == 0 &&
         SortformerState().feed_count == 0);
  CheckSortformerCleared(result);
  CheckSortformerError(error);
  result = PushSortformer(stream.get(), 1);
  omni_sortformer_result_free(&result);
  for (int allocation = 0; allocation < 2; ++allocation) {
    auto failing = CreateSortformerStream(model.get());
    State().malloc_failure_after = allocation;
    assert(omni_sortformer_stream_push(failing.get(), 1, samples.data(),
                                       samples.size(), &accepted, &result,
                                       &error) == 0);
    assert(State().malloc_failure_after == -1 && accepted == 0);
    CheckSortformerCleared(result);
    CheckSortformerError(error);
    CheckSortformerRejected(failing.get());
    CheckSortformerDrain(failing.get());
  }
  auto processing = CreateSortformerStream(model.get());
  new_failure_byte_count = 4 * sizeof(float);
  assert(omni_sortformer_stream_push(processing.get(), 1, samples.data(),
                                     samples.size(), &accepted, &result,
                                     &error) == 0);
  assert(new_failure_byte_count == 0 && accepted == 0);
  CheckSortformerError(error);
  CheckSortformerRejected(processing.get());
  State().malloc_failure_after = 0;
  error = reinterpret_cast<char *>(1);
  assert(omni_sortformer_create(nullptr, &error) == nullptr &&
         error == nullptr);
  result = PushSortformer(stream.get(), 2);
  omni_sortformer_result_free(&result);
#endif
}

void SerializedAdmission() {
#ifdef OMNI_ABI_WRAP_MALLOC
  auto model = CreateSortformerModel();
  auto first = CreateSortformerStream(model.get());
  auto second = CreateSortformerStream(model.get());
  const std::vector<float> samples(1009, 0.25f);
  SortformerState().block_feed = true;
  auto running = std::async(std::launch::async, [&] {
    auto result = PushSortformer(first.get(), 1);
    omni_sortformer_result_free(&result);
  });
  WaitForSortformerFeed();
  new_failure_byte_count = samples.size() * sizeof(float);
  std::promise<void> started;
  auto has_started = started.get_future();
  auto waiting = std::async(std::launch::async, [&] {
    started.set_value();
    OmniSortformerResult result{};
    uint64_t accepted = UINT64_MAX;
    assert(omni_sortformer_stream_push(second.get(), 1, samples.data(),
                                       samples.size(), &accepted, &result,
                                       nullptr) == 0);
    assert(accepted == 0);
    CheckSortformerCleared(result);
  });
  has_started.get();
  assert(waiting.wait_for(std::chrono::milliseconds(50)) ==
         std::future_status::timeout);
  assert(new_failure_byte_count == samples.size() * sizeof(float));
  ReleaseSortformerFeed();
  running.get();
  waiting.get();
  assert(new_failure_byte_count == 0 && SortformerState().feed_count == 1);
  auto result = PushSortformer(second.get(), 1);
  omni_sortformer_result_free(&result);
#endif
}

} // namespace

void RunSortformerFailureCase(const std::string &test) {
  if (test == "sortformer_config_rejected") {
    char *error = reinterpret_cast<char *>(1);
    assert(omni_sortformer_create(std::filesystem::current_path().c_str(),
                                  &error) == nullptr);
    assert(error != nullptr);
    assert(std::strcmp(error, "Sortformer initialization failed.") == 0);
    CheckSortformerError(error);
    assert(SortformerState().load_count == 0);
    assert(SortformerState().live_array_count == 0);
  } else if (test == "sortformer_config_accepted") {
    char *error = reinterpret_cast<char *>(1);
    SortformerModelLease model(
        omni_sortformer_create(std::filesystem::current_path().c_str(), &error),
        &omni_sortformer_destroy);
    assert(model && error == nullptr);
    assert(SortformerState().load_count == 1);
  } else if (test == "sortformer_failure_config") {
    InvalidConfigurations();
  } else if (test == "sortformer_failure_exceptions") {
    ModelExceptions();
  } else if (test == "sortformer_failure_results") {
    InvalidResults();
  } else if (test == "sortformer_failure_allocation") {
    AllocationFailures();
  } else if (test == "sortformer_failure_serialized_admission") {
    SerializedAdmission();
  } else {
    assert(false && "Unknown Sortformer failure case");
  }
}

} // namespace omni_test
