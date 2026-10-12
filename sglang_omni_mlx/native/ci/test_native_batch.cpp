// SPDX-License-Identifier: Apache-2.0
#include "omni_native_core.h"

#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "backend.h"
#include "cohere_transcriber.h"
#include "moss_transcriber.h"
#include "nemotron_transcriber.h"
#include "parakeet_transcriber.h"
#include "sensevoice_transcriber.h"
#include "whisper_transcriber.h"

void TestBatchBounds(OmniBatchModelKind model_kind);
void TestBatchLifetime(OmniBatchModelKind model_kind,
                       const std::string &test_case);
void TestBatchFaults(OmniBatchModelKind model_kind,
                     const std::string &test_case);

namespace {

OmniBatchHandle *CreateModel(OmniBatchModelKind model_kind) {
  OmniBatchHandle *handle = nullptr;
  assert(omni_batch_create(model_kind, ".", &handle) == OMNI_BATCH_OK);
  assert(handle != nullptr);
  return handle;
}

OmniBatchStatus Attempt(OmniBatchHandle *handle, const float *samples,
                        size_t sample_count, const OmniBatchOptions &options,
                        OmniBatchResult *result) {
  OmniBatchRequest *request = nullptr;
  assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_OK);
  auto status =
      omni_batch_transcribe(request, samples, sample_count, &options, result);
  OmniBatchResult repeated{};
  assert(omni_batch_transcribe(request, samples, sample_count, &options,
                               &repeated) == OMNI_BATCH_INVALID);
  assert(omni_batch_request_destroy_checked(request) == OMNI_BATCH_OK);
  return status;
}

void CheckDefaultOptions(OmniBatchModelKind model_kind) {
  using namespace batch_test;
  assert(last_model_kind == model_kind);
  switch (model_kind) {
  case OMNI_BATCH_WHISPER: {
    whisper::WhisperOptions baseline;
    assert(last_language == baseline.language);
    assert(last_maximum_token_count == baseline.max_new_tokens);
    assert(last_temperature == baseline.temperature);
    break;
  }
  case OMNI_BATCH_COHERE: {
    cohere_transcribe::CohereOptions baseline;
    assert(last_language == baseline.language);
    assert(last_punctuation == baseline.use_punctuation);
    assert(last_maximum_token_count == baseline.max_new_tokens);
    assert(last_temperature == baseline.temperature);
    assert(last_chunk_duration_seconds == baseline.chunk_duration_seconds);
    assert(last_minimum_chunk_duration_seconds ==
           baseline.min_chunk_duration_seconds);
    break;
  }
  case OMNI_BATCH_MOSS: {
    moss::MossOptions baseline;
    assert(has_prompt == baseline.prompt.has_value());
    assert(has_maximum_token_count == baseline.max_new_tokens.has_value());
    assert(last_end_stop == baseline.stop_at_end_of_text);
    assert(last_loop_stop == baseline.stop_on_token_loop);
    break;
  }
  case OMNI_BATCH_NEMOTRON: {
    nemotron::NemotronOptions baseline;
    assert(has_language == baseline.language.has_value());
    assert(has_chunk_frame_count == baseline.chunk_frames.has_value());
    break;
  }
  case OMNI_BATCH_PARAKEET: {
    parakeet::ParakeetOptions baseline;
    assert(last_chunk_duration_seconds == baseline.chunk_duration_seconds);
    break;
  }
  case OMNI_BATCH_SENSEVOICE: {
    sensevoice::SenseVoiceOptions baseline;
    assert(has_language == baseline.language.has_value());
    assert(last_inverse_text_normalization == baseline.use_itn);
    break;
  }
  default:
    assert(false);
  }
}

void TestOptions(OmniBatchModelKind model_kind, bool use_defaults) {
  auto *handle = CreateModel(model_kind);
  OmniBatchOptions options{};
  assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
  if (!use_defaults) {
    switch (model_kind) {
    case OMNI_BATCH_WHISPER:
      options.family.whisper = {"zh", 11, 0.25f};
      break;
    case OMNI_BATCH_COHERE:
      options.family.cohere = {"ja", 0, 12, 0.5f, 15, 0.75f};
      break;
    case OMNI_BATCH_MOSS:
      options.family.moss = {"<|audio_pad|> text", 13, 1, 1};
      break;
    case OMNI_BATCH_NEMOTRON:
      options.family.nemotron = {"en-US", 14};
      break;
    case OMNI_BATCH_PARAKEET:
      options.family.parakeet = {2.000000000123};
      break;
    case OMNI_BATCH_SENSEVOICE:
      options.family.sensevoice = {"yue", 1};
      break;
    default:
      assert(false);
    }
  } else {
  }
  std::vector<float> samples(OMNI_BATCH_MAX_SAMPLES, 0.125f);
  OmniBatchResult result{};
  for (int i = 0; i < 2; ++i) {
    assert(Attempt(handle, samples.data(), samples.size(), options, &result) ==
           OMNI_BATCH_OK);
    assert(batch_test::last_sample_count == samples.size());
    assert(batch_test::last_sample == samples.back());
    assert(batch_test::loading_thread == batch_test::execution_thread);
    assert(batch_test::loading_thread != std::this_thread::get_id());
    assert(batch_test::load_count == 1);
    assert(batch_test::transcribe_count == i + 1);
    if (i == 0) {
      omni_batch_result_free(&result);
    } else {
    }
  }
  if (use_defaults) {
    CheckDefaultOptions(model_kind);
  } else {
    using namespace batch_test;
    assert(last_model_kind == model_kind);
    switch (model_kind) {
    case OMNI_BATCH_WHISPER:
      assert(last_language == "zh" && last_maximum_token_count == 11 &&
             last_temperature == 0.25f);
      break;
    case OMNI_BATCH_COHERE:
      assert(last_language == "ja" && !last_punctuation &&
             last_maximum_token_count == 12);
      assert(last_temperature == 0.5f && last_chunk_duration_seconds == 15);
      assert(last_minimum_chunk_duration_seconds == 0.75f);
      break;
    case OMNI_BATCH_MOSS:
      assert(has_prompt && last_prompt == "<|audio_pad|> text");
      assert(has_maximum_token_count && last_maximum_token_count == 13);
      assert(last_end_stop && last_loop_stop);
      break;
    case OMNI_BATCH_NEMOTRON:
      assert(has_language && last_language == "en-US");
      assert(has_chunk_frame_count && last_chunk_frame_count == 14);
      break;
    case OMNI_BATCH_PARAKEET:
      assert(last_chunk_duration_seconds == 2.000000000123);
      break;
    case OMNI_BATCH_SENSEVOICE:
      assert(has_language && last_language == "yue" &&
             last_inverse_text_normalization);
      break;
    default:
      assert(false);
    }
  }
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
  assert(batch_test::destroy_count == 1);
  assert(batch_test::loading_thread == batch_test::destruction_thread);
  assert(std::strcmp(result.text, "héllo 世界") == 0);
  assert(std::strcmp(result.language, "en") == 0);
  assert(result.generated_token_count == 3 &&
         result.finish_reason == OMNI_BATCH_STOP);
  assert(result.segment_count == 2);
  assert(result.segments[0].start_seconds == 0.125 &&
         result.segments[0].end_seconds == 1.75);
  assert(std::strcmp(result.segments[0].text, result.text) == 0);
  assert(std::strcmp(result.segments[0].speaker, "S01") == 0);
  assert(std::strcmp(result.segments[0].language, "en") == 0);
  assert(std::strcmp(result.segments[0].emotion, "happy") == 0);
  assert(std::strcmp(result.segments[0].event, "speech") == 0);
  assert(result.segments[1].language == nullptr &&
         result.segments[1].event == nullptr);
  assert(result.segments[1].emotion != nullptr &&
         result.segments[1].emotion[0] == '\0');
  omni_batch_result_free(&result);
  omni_batch_result_free(&result);
  assert(result.text == nullptr && result.segment_count == 0 &&
         result.generated_token_count == 0);
}

void TestInputs(OmniBatchModelKind model_kind) {
  auto *handle = CreateModel(model_kind);
  OmniBatchOptions options{};
  assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
  OmniBatchResult result{};
  float sample = 0;
  assert(Attempt(handle, nullptr, 1, options, &result) == OMNI_BATCH_INVALID);
  assert(Attempt(handle, &sample, 0, options, &result) == OMNI_BATCH_INVALID);
  assert(Attempt(handle, &sample, OMNI_BATCH_MAX_SAMPLES + 1, options,
                 &result) == OMNI_BATCH_INVALID);
  assert(Attempt(handle, &sample, std::numeric_limits<size_t>::max(), options,
                 &result) == OMNI_BATCH_INVALID);
  sample = std::numeric_limits<float>::quiet_NaN();
  assert(Attempt(handle, &sample, 1, options, &result) == OMNI_BATCH_INVALID);
  sample = std::numeric_limits<float>::infinity();
  assert(Attempt(handle, &sample, 1, options, &result) == OMNI_BATCH_INVALID);
  sample = 0;
  assert(Attempt(handle, &sample, 1, options, nullptr) == OMNI_BATCH_INVALID);
  options.model_kind = 100;
  assert(Attempt(handle, &sample, 1, options, &result) == OMNI_BATCH_INVALID);
  assert(batch_test::transcribe_count == 0);
  assert(result.text == nullptr);
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
}

void TestInvalidOptions(OmniBatchModelKind model_kind) {
  auto *handle = CreateModel(model_kind);
  for (int i = 0; i < 7; ++i) {
    OmniBatchOptions options{};
    assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
    std::string too_long_language(129, 'x');
    std::string too_long_prompt(8193, 'x');
    switch (model_kind) {
    case OMNI_BATCH_WHISPER:
      if (i < 2) {
        options.family.whisper.maximum_token_count = i == 0 ? -1 : 4097;
      } else if (i == 2) {
        options.family.whisper.language = too_long_language.c_str();
      } else {
        options.family.whisper.temperature =
            i == 3 ? -1 : std::numeric_limits<float>::infinity();
      }
      break;
    case OMNI_BATCH_COHERE:
      if (i == 0) {
        options.family.cohere.maximum_token_count = 4097;
      } else if (i == 1) {
        options.family.cohere.use_punctuation = 2;
      } else if (i == 2) {
        options.family.cohere.language = too_long_language.c_str();
      } else if (i == 3) {
        options.family.cohere.chunk_duration_seconds =
            std::numeric_limits<float>::max();
      } else if (i == 4) {
        options.family.cohere.minimum_chunk_duration_seconds = 31;
      } else if (i == 5) {
        options.family.cohere.chunk_duration_seconds = 0;
      } else {
        options.family.cohere.temperature =
            std::numeric_limits<float>::quiet_NaN();
      }
      break;
    case OMNI_BATCH_MOSS:
      if (i == 0) {
        options.family.moss.maximum_token_count = -2;
      } else if (i == 1) {
        options.family.moss.maximum_token_count = 4097;
      } else if (i == 2) {
        options.family.moss.prompt = too_long_prompt.c_str();
      } else if (i == 3) {
        options.family.moss.stop_at_end_of_text = 2;
      } else if (i == 4) {
        options.family.moss.stop_on_token_loop = -1;
      } else {
        options.family.moss.prompt = "<|audio_pad|> twice <|audio_pad|>";
      }
      break;
    case OMNI_BATCH_NEMOTRON:
      if (i == 0) {
        options.family.nemotron.language = too_long_language.c_str();
      } else {
        options.family.nemotron.chunk_frame_count = i == 1 ? -1 : 4097;
      }
      break;
    case OMNI_BATCH_PARAKEET:
      options.family.parakeet.chunk_duration_seconds =
          i == 0   ? 1.99
          : i == 1 ? 1201
          : i == 2 ? 300.1
          : i == 3 ? 1198
                   : std::numeric_limits<double>::quiet_NaN();
      break;
    case OMNI_BATCH_SENSEVOICE:
      if (i == 0) {
        options.family.sensevoice.language = too_long_language.c_str();
      } else {
        options.family.sensevoice.use_inverse_text_normalization =
            i == 1 ? -1 : 2;
      }
      break;
    default:
      assert(false);
    }
    float sample = 0;
    OmniBatchResult result{};
    assert(Attempt(handle, &sample, 1, options, &result) == OMNI_BATCH_INVALID);
  }
  assert(batch_test::transcribe_count == 0);
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
}

void TestResults(OmniBatchModelKind model_kind) {
  auto *handle = CreateModel(model_kind);
  OmniBatchOptions options{};
  assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
  for (int i = 1; i <= static_cast<int>(batch_test::OutputMode::InvalidFinish);
       ++i) {
    const auto mode = static_cast<batch_test::OutputMode>(i);
    batch_test::output_mode = mode;
    float sample = 0;
    OmniBatchResult result{};
    const auto status = Attempt(handle, &sample, 1, options, &result);
    if (mode == batch_test::OutputMode::Empty) {
      assert(status == OMNI_BATCH_OK && result.text && result.text[0] == '\0');
      assert(result.language == nullptr && result.segment_count == 0);
      assert(result.finish_reason == OMNI_BATCH_LENGTH);
      omni_batch_result_free(&result);
    } else if (mode == batch_test::OutputMode::Throw ||
               mode == batch_test::OutputMode::InvalidTime ||
               mode == batch_test::OutputMode::ReversedTime ||
               mode == batch_test::OutputMode::InvalidFinish) {
      assert(status == OMNI_BATCH_FAILED);
    } else if (mode == batch_test::OutputMode::OutOfMemory) {
      assert(status == OMNI_BATCH_OUT_OF_MEMORY);
    } else {
      assert(status == OMNI_BATCH_LIMIT);
    }
    assert(result.text == nullptr && result.segments == nullptr &&
           result.segment_count == 0);
  }
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
}

} // namespace

int main(int argument_count, char **arguments) {
  assert(argument_count == 3);
  const int model_kind = std::stoi(arguments[1]);
  const std::string test_case = arguments[2];
  if (test_case == "defaults" || test_case == "custom") {
    TestOptions(model_kind, test_case == "defaults");
  } else if (test_case == "inputs") {
    TestInputs(model_kind);
  } else if (test_case == "settings") {
    TestInvalidOptions(model_kind);
  } else if (test_case == "outputs") {
    TestResults(model_kind);
  } else if (test_case == "bounds") {
    TestBatchBounds(model_kind);
  } else if (test_case.starts_with("lifetime_")) {
    TestBatchLifetime(model_kind, test_case);
  } else {
    TestBatchFaults(model_kind, test_case);
  }
  return 0;
}
