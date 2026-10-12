// SPDX-License-Identifier: Apache-2.0
#include "omni_native_batch.h"

#include <cassert>
#include <cstring>
#include <string>

#include "backend.h"

void TestBatchBounds(OmniBatchModelKind model_kind) {
  OmniBatchHandle *handle = nullptr;
  assert(omni_batch_create(model_kind, ".", &handle) == OMNI_BATCH_OK);
  assert(omni_batch_options_default(model_kind, nullptr) == OMNI_BATCH_INVALID);
  assert(omni_batch_request_create(handle, nullptr) == OMNI_BATCH_INVALID);
  OmniBatchRequest *request = nullptr;
  assert(omni_batch_request_create(nullptr, &request) == OMNI_BATCH_INVALID);
  assert(request == nullptr);
  OmniBatchResult result{};
  assert(omni_batch_transcribe(nullptr, nullptr, 0, nullptr, &result) ==
         OMNI_BATCH_INVALID);
  assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_OK);
  float sample = 0;
  assert(omni_batch_transcribe(request, &sample, 1, nullptr, &result) ==
         OMNI_BATCH_INVALID);
  assert(omni_batch_request_destroy_checked(request) == OMNI_BATCH_OK);
  std::string language(OMNI_BATCH_MAX_LANGUAGE_BYTES, 'l');
  std::string prompt(OMNI_BATCH_MAX_PROMPT_BYTES, 'p');
  for (int i = 0; i < 4; ++i) {
    OmniBatchOptions options{};
    assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
    const int maximum_token_count = i % 2 == 0 ? 0 : OMNI_BATCH_MAX_TOKENS;
    const double chunk_seconds[] = {2, 300, 1199, 1200};
    switch (model_kind) {
    case OMNI_BATCH_WHISPER:
      options.family.whisper.language = language.c_str();
      options.family.whisper.maximum_token_count = maximum_token_count;
      break;
    case OMNI_BATCH_COHERE:
      options.family.cohere.language = language.c_str();
      options.family.cohere.maximum_token_count = maximum_token_count;
      options.family.cohere.minimum_chunk_duration_seconds = 30;
      break;
    case OMNI_BATCH_MOSS:
      options.family.moss.prompt = prompt.c_str();
      options.family.moss.maximum_token_count = maximum_token_count;
      options.family.moss.stop_at_end_of_text = i % 2;
      options.family.moss.stop_on_token_loop = i / 2;
      break;
    case OMNI_BATCH_NEMOTRON:
      options.family.nemotron.language = language.c_str();
      options.family.nemotron.chunk_frame_count = 4096;
      break;
    case OMNI_BATCH_PARAKEET:
      options.family.parakeet.chunk_duration_seconds = chunk_seconds[i];
      break;
    case OMNI_BATCH_SENSEVOICE:
      options.family.sensevoice.language = language.c_str();
      options.family.sensevoice.use_inverse_text_normalization = i % 2;
      break;
    default:
      assert(false);
    }
    assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_OK);
    batch_test::output_mode = batch_test::OutputMode::Boundary;
    assert(omni_batch_transcribe(request, &sample, 1, &options, &result) ==
           OMNI_BATCH_OK);
    assert(std::strlen(result.text) == OMNI_BATCH_MAX_TEXT_BYTES);
    assert(std::strlen(result.language) == OMNI_BATCH_MAX_LANGUAGE_BYTES);
    assert(result.segment_count == OMNI_BATCH_MAX_SEGMENTS);
    assert(result.generated_token_count == OMNI_BATCH_MAX_TOKENS);
    assert(std::strlen(result.segments[0].speaker) ==
           OMNI_BATCH_MAX_LANGUAGE_BYTES);
    assert(std::strlen(result.segments[0].language) ==
           OMNI_BATCH_MAX_LANGUAGE_BYTES);
    assert(std::strlen(result.segments[0].emotion) ==
           OMNI_BATCH_MAX_LANGUAGE_BYTES);
    assert(std::strlen(result.segments[0].event) ==
           OMNI_BATCH_MAX_LANGUAGE_BYTES);
    if (model_kind == OMNI_BATCH_MOSS) {
      assert(batch_test::last_prompt == prompt && batch_test::has_prompt);
      assert(batch_test::last_end_stop == (i % 2 != 0));
      assert(batch_test::last_loop_stop == (i / 2 != 0));
      assert(batch_test::has_maximum_token_count);
      assert(batch_test::last_maximum_token_count == maximum_token_count);
    } else if (model_kind == OMNI_BATCH_PARAKEET) {
      assert(batch_test::last_chunk_duration_seconds == chunk_seconds[i]);
    } else {
      assert(batch_test::last_language == language);
    }
    omni_batch_result_free(&result);
    assert(omni_batch_request_destroy_checked(request) == OMNI_BATCH_OK);
  }
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
}
