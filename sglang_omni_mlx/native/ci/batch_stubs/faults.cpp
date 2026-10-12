// SPDX-License-Identifier: Apache-2.0
#include "omni_native_batch.h"

#include <atomic>
#include <cassert>
#include <cstdlib>
#include <new>
#include <string>

#include "backend.h"

namespace {
std::atomic<int> allocation_countdown{-1};
std::atomic<int> snapshot_countdown{-1};

bool ShouldFail(std::atomic<int> &countdown) noexcept {
  int remaining = countdown.load();
  while (remaining >= 0) {
    if (countdown.compare_exchange_weak(remaining, remaining - 1)) {
      return remaining == 0;
    } else {
    }
  }
  return false;
}
} // namespace

#ifdef OMNI_BATCH_FAULT_WRAP
extern "C" void *__real_malloc(size_t byte_count);
extern "C" void *__real_calloc(size_t count, size_t byte_count);
extern "C" void *__wrap_malloc(size_t byte_count) {
  return ShouldFail(snapshot_countdown) ? nullptr : __real_malloc(byte_count);
}
extern "C" void *__wrap_calloc(size_t count, size_t byte_count) {
  return ShouldFail(snapshot_countdown) ? nullptr
                                        : __real_calloc(count, byte_count);
}
#endif

void *operator new(size_t byte_count) {
  if (ShouldFail(allocation_countdown)) {
    throw std::bad_alloc();
  } else {
#ifdef OMNI_BATCH_FAULT_WRAP
    void *allocation = __real_malloc(byte_count == 0 ? 1 : byte_count);
#else
    void *allocation = std::malloc(byte_count == 0 ? 1 : byte_count);
#endif
    if (allocation == nullptr) {
      throw std::bad_alloc();
    } else {
      return allocation;
    }
  }
}
void operator delete(void *allocation) noexcept { std::free(allocation); }
void operator delete(void *allocation, size_t) noexcept {
  std::free(allocation);
}
void *operator new[](size_t byte_count) { return ::operator new(byte_count); }
void operator delete[](void *allocation) noexcept { std::free(allocation); }
void operator delete[](void *allocation, size_t) noexcept {
  std::free(allocation);
}

void TestBatchFaults(OmniBatchModelKind model_kind,
                     const std::string &test_case) {
  OmniBatchHandle *handle = nullptr;
  if (test_case == "load_failures") {
    assert(omni_batch_create(model_kind, nullptr, &handle) ==
           OMNI_BATCH_INVALID);
    assert(omni_batch_create(model_kind, "", &handle) == OMNI_BATCH_INVALID);
    assert(omni_batch_create(model_kind, "missing-model", &handle) ==
           OMNI_BATCH_INVALID);
    assert(omni_batch_create(100, ".", &handle) == OMNI_BATCH_INVALID);
    assert(omni_batch_create(model_kind, ".", nullptr) == OMNI_BATCH_INVALID);
    assert(handle == nullptr);
    batch_test::should_fail_load = true;
    assert(omni_batch_create(model_kind, ".", &handle) == OMNI_BATCH_FAILED);
    assert(handle == nullptr);
    batch_test::should_fail_load = false;
    batch_test::should_fail_load_allocation = true;
    assert(omni_batch_create(model_kind, ".", &handle) ==
           OMNI_BATCH_OUT_OF_MEMORY);
    assert(handle == nullptr);
    batch_test::should_fail_load_allocation = false;
  } else if (test_case == "allocation_create") {
    int failures = 0;
    for (int i = 0; i < 24; ++i) {
      allocation_countdown = i;
      const auto status = omni_batch_create(model_kind, ".", &handle);
      allocation_countdown = -1;
      if (status == OMNI_BATCH_OK) {
        assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
      } else {
        assert(status == OMNI_BATCH_OUT_OF_MEMORY && handle == nullptr);
        ++failures;
      }
    }
    assert(failures >= 4);
    assert(batch_test::load_count == batch_test::destroy_count);
  } else {
    assert(test_case == "allocation_request" ||
           test_case == "allocation_audio" ||
           test_case == "allocation_snapshot");
    assert(omni_batch_create(model_kind, ".", &handle) == OMNI_BATCH_OK);
    OmniBatchOptions options{};
    assert(omni_batch_options_default(model_kind, &options) == OMNI_BATCH_OK);
    float sample = 0;
    for (int i = 0; i < 12; ++i) {
      OmniBatchRequest *request = nullptr;
      if (test_case == "allocation_request") {
        allocation_countdown = i;
      } else {
      }
      const auto admission = omni_batch_request_create(handle, &request);
      allocation_countdown = -1;
      if (admission == OMNI_BATCH_OUT_OF_MEMORY) {
        assert(request == nullptr);
        assert(omni_batch_request_create(handle, &request) == OMNI_BATCH_OK);
      } else {
        assert(admission == OMNI_BATCH_OK);
      }
      if (test_case == "allocation_audio") {
        allocation_countdown = 0;
      } else if (test_case == "allocation_snapshot") {
        snapshot_countdown = i;
      } else {
      }
      OmniBatchResult result{};
      const auto status =
          omni_batch_transcribe(request, &sample, 1, &options, &result);
      allocation_countdown = -1;
      snapshot_countdown = -1;
      if (test_case == "allocation_audio" ||
          (test_case == "allocation_snapshot" && i < 11)) {
        assert(status == OMNI_BATCH_OUT_OF_MEMORY);
        assert(result.text == nullptr && result.segments == nullptr &&
               result.segment_count == 0);
      } else {
        assert(status == OMNI_BATCH_OK);
        omni_batch_result_free(&result);
      }
      assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_BUSY);
      assert(omni_batch_request_destroy_checked(request) == OMNI_BATCH_OK);
    }
    if (test_case == "allocation_audio") {
      assert(batch_test::transcribe_count == 0);
    } else {
    }
    assert(omni_batch_destroy_checked(handle) == OMNI_BATCH_OK);
  }
}
