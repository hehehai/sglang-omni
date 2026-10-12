// SPDX-License-Identifier: Apache-2.0
#include "omni_native_batch.h"

#include <cassert>
#include <chrono>
#include <future>
#include <string>
#include <thread>
#include <vector>

#include "backend.h"

void TestBatchLifetime(OmniBatchModelKind model_kind,
                       const std::string &test_case) {
  OmniBatchHandle *handle = nullptr;
  assert(omni_batch_create(model_kind, ".", &handle) == OMNI_BATCH_OK);
  OmniBatchOptions options{};
  assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
  OmniBatchRequest *request = nullptr;
  assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_OK);
  float sample = 0;
  OmniBatchResult result{};
  OmniBatchRequest *rejected = nullptr;
  assert(omni_batch_request_create(handle, &rejected) == OMNI_BATCH_BUSY);
  assert(rejected == nullptr);
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_BUSY);
  if (test_case == "lifetime_cancel_before") {
    omni_batch_request_cancel(request);
    omni_batch_request_cancel(request);
    assert(omni_batch_transcribe(request, &sample, 1, &options, &result) ==
           OMNI_BATCH_CANCELLED);
    assert(batch_test::transcribe_count == 0);
  } else if (test_case == "lifetime_drain_before") {
    assert(omni_batch_request_drain(request) == OMNI_BATCH_OK);
    assert(omni_batch_transcribe(request, &sample, 1, &options, &result) ==
           OMNI_BATCH_INVALID);
    assert(batch_test::transcribe_count == 0);
  } else if (test_case == "lifetime_contention") {
    std::vector<std::thread> contenders;
    for (int i = 0; i < 16; ++i) {
      contenders.emplace_back([handle] {
        OmniBatchRequest *other = nullptr;
        assert(omni_batch_request_create(handle, &other) == OMNI_BATCH_BUSY);
        assert(other == nullptr);
      });
    }
    for (auto &contender : contenders) {
      contender.join();
    }
    assert(omni_batch_transcribe(request, &sample, 1, &options, &result) ==
           OMNI_BATCH_OK);
    omni_batch_result_free(&result);
  } else {
    batch_test::BlockNextTranscription();
    auto transcription = std::async(std::launch::async, [&] {
      return omni_batch_transcribe(request, &sample, 1, &options, &result);
    });
    batch_test::WaitForTranscription();
    assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_BUSY);
    OmniBatchResult simultaneous{};
    assert(omni_batch_transcribe(request, &sample, 1, &options,
                                 &simultaneous) == OMNI_BATCH_BUSY);
    if (test_case == "lifetime_model_cancel") {
      omni_batch_cancel(handle);
      omni_batch_cancel(handle);
      assert(omni_batch_request_create(handle, &rejected) ==
             OMNI_BATCH_CANCELLED);
    } else {
      assert(test_case == "lifetime_cancel_active" ||
             test_case == "lifetime_drain_active");
      omni_batch_request_cancel(request);
    }
    assert(transcription.wait_for(std::chrono::milliseconds(20)) ==
           std::future_status::timeout);
    auto drain = std::async(std::launch::async,
                            [&] { return omni_batch_request_drain(request); });
    assert(drain.wait_for(std::chrono::milliseconds(20)) ==
           std::future_status::timeout);
    assert(batch_test::destroy_count == 0);
    assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_BUSY);
    batch_test::ReleaseTranscription();
    assert(transcription.get() == OMNI_BATCH_CANCELLED);
    assert(drain.get() == OMNI_BATCH_OK);
    assert(result.text == nullptr);
  }
  assert(omni_batch_request_drain(request) == OMNI_BATCH_OK);
  assert(omni_batch_request_drain(request) == OMNI_BATCH_OK);
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_BUSY);
  assert(omni_batch_request_destroy_checked(request) == OMNI_BATCH_OK);
  assert(batch_test::destroy_count == 0);
  if (test_case == "lifetime_model_cancel") {
    assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_CANCELLED);
    assert(request == nullptr);
  } else {
    assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_OK);
    assert(omni_batch_transcribe(request, &sample, 1, &options, &result) ==
           OMNI_BATCH_OK);
    omni_batch_result_free(&result);
    assert(omni_batch_request_destroy_checked(request) == OMNI_BATCH_OK);
  }
  assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
  assert(batch_test::load_count == 1 && batch_test::destroy_count == 1);
  assert(batch_test::loading_thread == batch_test::destruction_thread);
  assert(batch_test::loading_thread != std::this_thread::get_id());
  assert(omni_batch_destroy_checked(nullptr) == OMNI_BATCH_OK);
  assert(omni_batch_request_destroy_checked(nullptr) == OMNI_BATCH_OK);
  assert(omni_batch_request_drain(nullptr) == OMNI_BATCH_OK);
  omni_batch_cancel(nullptr);
  omni_batch_request_cancel(nullptr);
}
