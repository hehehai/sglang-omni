// SPDX-License-Identifier: Apache-2.0
#include "support.h"
#include <cstdlib>
#include <new>
namespace native_test {
thread_local long fail_new_after = -1;
thread_local long fail_malloc_after = -1;
thread_local size_t new_count = 0;
thread_local size_t malloc_count = 0;
} // namespace native_test
#ifdef OMNI_SPEAKER_FAULT_WRAP
extern "C" void *__real_malloc(size_t size);
extern "C" void *__real_calloc(size_t count, size_t size);
extern "C" void *__wrap_malloc(size_t size) {
  ++native_test::malloc_count;
  if (native_test::fail_malloc_after == 0) {
    native_test::fail_malloc_after = -1;
    return nullptr;
  } else if (native_test::fail_malloc_after > 0) {
    --native_test::fail_malloc_after;
  } else {
  }
  return __real_malloc(size);
}
extern "C" void *__wrap_calloc(size_t count, size_t size) {
  ++native_test::malloc_count;
  if (native_test::fail_malloc_after == 0) {
    native_test::fail_malloc_after = -1;
    return nullptr;
  } else if (native_test::fail_malloc_after > 0) {
    --native_test::fail_malloc_after;
  } else {
  }
  return __real_calloc(count, size);
}
void *operator new(size_t size) {
  ++native_test::new_count;
  if (native_test::fail_new_after == 0) {
    native_test::fail_new_after = -1;
    throw std::bad_alloc();
  } else if (native_test::fail_new_after > 0) {
    --native_test::fail_new_after;
  } else {
  }
  void *allocation = __real_malloc(size == 0 ? 1 : size);
  if (allocation == nullptr) {
    throw std::bad_alloc();
  } else {
    return allocation;
  }
}
void *operator new[](size_t size) { return ::operator new(size); }
void operator delete(void *allocation) noexcept { std::free(allocation); }
void operator delete[](void *allocation) noexcept { std::free(allocation); }
void operator delete(void *allocation, size_t) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, size_t) noexcept {
  std::free(allocation);
}
#endif
namespace native_test {
void fault_case(OmniSpeakerModelKind kind, const std::string &name,
                int allocation_index) {
  if (name == "create") {
    OmniSpeakerHandle *model = nullptr;
    fail_new_after = allocation_index;
    const auto status = omni_speaker_create(kind, ".", &model);
    const bool fault_triggered = fail_new_after == -1;
    fail_new_after = -1;
    expect_status(status,
                  fault_triggered ? OMNI_BATCH_OUT_OF_MEMORY : OMNI_BATCH_OK,
                  "new create fault");
    expect_status(omni_speaker_destroy_checked(model), OMNI_BATCH_OK,
                  "create fault original retry");
    require(script.live_models == 0, "Create allocation leaked model");
    return;
  } else {
  }
  Fixture fixture(kind, name != "stream");
  if (name == "stream") {
    fail_new_after = allocation_index;
    const auto status = omni_speaker_realtime_create(
        fixture.model, 73, &fixture.settings, &fixture.stream);
    const bool fault_triggered = fail_new_after == -1;
    fail_new_after = -1;
    expect_status(status,
                  fault_triggered ? OMNI_BATCH_OUT_OF_MEMORY : OMNI_BATCH_OK,
                  "new stream fault");
  } else if (name == "push") {
    auto samples = audio(100);
    uint64_t accepted = 99;
    fail_new_after = 0;
    const auto status = omni_speaker_realtime_push(
        fixture.stream, 1, samples.data(), samples.size(), &accepted);
    fail_new_after = -1;
    expect_status(status, OMNI_BATCH_OUT_OF_MEMORY, "new audio fault");
    require(accepted == 0 && script.decode_count == 0,
            "Failed audio copy consumed/decoded");
    const auto events = fixture.events();
    require(events.back().at("failure_status") == OMNI_BATCH_OUT_OF_MEMORY,
            "OOM terminal not retained");
  } else if (name == "destroy") {
    fail_new_after = 0;
    const auto status = omni_speaker_realtime_destroy_checked(fixture.stream);
    fail_new_after = -1;
    expect_status(status, OMNI_BATCH_OUT_OF_MEMORY,
                  "Cleanup control allocation");
    require(script.live_models == 1, "Cleanup allocation freed model");
    expect_status(omni_speaker_destroy_checked(fixture.model), OMNI_BATCH_BUSY,
                  "Failed destroy keeps original lease");
  } else if (name == "cancel_terminal") {
    fixture.events();
    OmniSpeakerRealtimeEvent event{};
    const size_t before_new = new_count;
    const size_t before_malloc = malloc_count;
    fail_new_after = 0;
    fail_malloc_after = 0;
    omni_speaker_realtime_cancel(fixture.stream);
    const int polled = omni_speaker_realtime_poll(fixture.stream, &event);
    const bool no_allocation = new_count == before_new &&
                               malloc_count == before_malloc &&
                               fail_new_after == 0 && fail_malloc_after == 0;
    fail_new_after = -1;
    fail_malloc_after = -1;
    require(no_allocation && polled == 1 &&
                event.kind == OMNI_SPEAKER_CANCELLED &&
                event.failure_status == OMNI_BATCH_CANCELLED &&
                event.text == nullptr && event.segments == nullptr,
            "Terminal status depends on allocating an error string");
    require(event.event_sequence == fixture.next_event_sequence++,
            "Terminal sequence changed");
    omni_speaker_realtime_event_free(&event);
  } else if (name == "poll") {
    fixture.push(audio(1));
    if (kind == OMNI_SPEAKER_NEMOTRON) {
      wait_callbacks(1);
    } else {
    }
    fixture.events();
    expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                  "poll prepare final");
    const int decodes_before = script.decode_count;
    const uint64_t expected_sequence = fixture.next_event_sequence;
    OmniSpeakerRealtimeEvent event{};
    fail_malloc_after = allocation_index;
    const int polled = omni_speaker_realtime_poll(fixture.stream, &event);
    const bool fault_triggered = fail_malloc_after == -1;
    fail_malloc_after = -1;
    if (fault_triggered) {
      require(polled == -1 &&
                  event.failure_status == OMNI_BATCH_OUT_OF_MEMORY &&
                  event.kind == 0 && event.session_id == 0 &&
                  event.event_sequence == 0 && event.text == nullptr &&
                  event.segments == nullptr && event.segment_count == 0,
              "Poll failure did not roll back partial owned snapshot");
      omni_speaker_realtime_event_free(&event);
      event = fixture.poll();
    } else {
      require(polled == 1, "Successful poll lost snapshot");
      ++fixture.next_event_sequence;
    }
    require(event.kind == OMNI_SPEAKER_SEGMENT &&
                event.event_sequence == expected_sequence &&
                event.segment_count == 2 &&
                script.decode_count == decodes_before,
            "Poll OOM consumed event/sequence or replayed audio");
    omni_speaker_realtime_event_free(&event);
    event = fixture.poll();
    require(event.kind == OMNI_SPEAKER_COMPLETED &&
                event.event_sequence == expected_sequence + 1,
            "Poll retry duplicated event");
    omni_speaker_realtime_event_free(&event);
  } else {
    throw std::invalid_argument("Unknown fault case");
  }
  fixture.close();
}
} // namespace native_test
