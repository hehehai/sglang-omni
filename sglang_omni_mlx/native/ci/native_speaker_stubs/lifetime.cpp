// SPDX-License-Identifier: Apache-2.0
#include "support.h"
#include "worker.h"
namespace native_test {
void lifetime_case(OmniSpeakerModelKind kind, const std::string &name) {
  if (name == "load_blocked" || name == "load_failure" ||
      name == "load_failure_retained") {
    script.blocks_load = name == "load_blocked";
    script.fails_load = name != "load_blocked";
    script.sync_failures = name == "load_failure_retained" ? 1 : 0;
    OmniSpeakerHandle *model = nullptr;
    auto loading = std::async(std::launch::async, [&] {
      return omni_speaker_create(kind, ".", &model);
    });
    if (name == "load_blocked") {
      script.load_gate.wait();
      require(loading.wait_for(std::chrono::milliseconds(40)) ==
                  std::future_status::timeout,
              "Nonpreemptible load acknowledged before model return");
      script.load_gate.release();
    } else {
    }
    expect_status(loading.get(),
                  name == "load_blocked" ? OMNI_BATCH_OK : OMNI_BATCH_FAILED,
                  "load status");
    require((model != nullptr) == (name != "load_failure"),
            "Create lost original cleanup scope");
    expect_status(omni_speaker_destroy_checked(model), OMNI_BATCH_OK,
                  "load scope retry");
    require(script.live_models == 0, "Load cleanup leaked model");
    check_threads();
    return;
  } else if (name == "worker_cancel") {
    auto cancel = qwen3_asr::NewCancelFlag();
    auto queued_cancel = qwen3_asr::NewCancelFlag();
    auto worker = std::make_unique<qwen3_asr::TranscriptionWorker>([] {});
    std::promise<void> completed;
    worker->Submit(
        [](const std::atomic<bool> &) {
          script.decode_gate.block();
          return qwen3_asr::TranscriptionResult{};
        },
        cancel,
        [&](std::optional<qwen3_asr::TranscriptionResult>,
            std::exception_ptr error) {
          require(!error, "Unexpected blocked worker failure");
          completed.set_value();
        });
    script.decode_gate.wait();
    std::atomic<bool> queued_ran{false};
    std::promise<bool> cancelled_completion;
    worker->Submit(
        [&](const std::atomic<bool> &) {
          queued_ran = true;
          return qwen3_asr::TranscriptionResult{};
        },
        queued_cancel,
        [&](std::optional<qwen3_asr::TranscriptionResult>,
            std::exception_ptr error) {
          try {
            std::rethrow_exception(error);
          } catch (const qwen3_asr::TranscriptionCancelled &) {
            cancelled_completion.set_value(true);
          } catch (...) {
            cancelled_completion.set_exception(std::current_exception());
          }
        });
    worker->CancelAll();
    require(cancel->load() && queued_cancel->load(),
            "Worker cancellation not acknowledged");
    auto joined = std::async(std::launch::async, [&] { worker.reset(); });
    require(joined.wait_for(std::chrono::milliseconds(40)) ==
                std::future_status::timeout,
            "Worker join released active GPU job on cancellation ACK");
    script.decode_gate.release();
    joined.get();
    completed.get_future().get();
    require(cancelled_completion.get_future().get() && !queued_ran,
            "Cancelled pending work executed");
    require(script.sync_count > 0 && script.cache_count > 0,
            "Original default idle cache policy changed");
    return;
  } else {
  }
  Fixture fixture(kind, name != "stream_failure" &&
                            name != "stream_failure_retained");
  if (name == "lease_completed" || name == "lease_drained" ||
      name == "stream_cancel" || name == "model_cancel") {
    if (name == "lease_completed") {
      expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                    "complete lease");
      fixture.events();
    } else if (name == "lease_drained") {
      expect_status(omni_speaker_realtime_drain(fixture.stream), OMNI_BATCH_OK,
                    "drain lease");
    } else if (name == "model_cancel") {
      omni_speaker_cancel(fixture.model);
    } else {
      omni_speaker_realtime_cancel(fixture.stream);
    }
    uint64_t rejected_sequence = 99;
    const float sample = 0.25f;
    expect_status(omni_speaker_realtime_push(fixture.stream, 1, &sample, 1,
                                             &rejected_sequence),
                  name == "lease_completed" ? OMNI_BATCH_INVALID
                                            : OMNI_BATCH_CANCELLED,
                  "Closed original lease");
    require(rejected_sequence == 0, "Closed original lease accepted audio");
    const std::string copied_setting(128, 's');
    if (kind == OMNI_SPEAKER_MOSS) {
      fixture.settings.family.moss.prompt = copied_setting.c_str();
    } else {
      fixture.settings.family.nemotron.language = copied_setting.c_str();
    }
    OmniSpeakerRealtime *other = nullptr;
    const size_t before_new = new_count;
    const auto status = omni_speaker_realtime_create(fixture.model, 74,
                                                     &fixture.settings, &other);
    const size_t allocations = new_count - before_new;
    expect_status(status, OMNI_BATCH_BUSY, "One lease retained");
    require(other == nullptr && allocations == 0,
            "BUSY copied settings or allocated second lease");
    expect_status(omni_speaker_destroy_checked(fixture.model), OMNI_BATCH_BUSY,
                  "Model leased destroy");
    expect_status(omni_speaker_realtime_destroy_checked(fixture.stream),
                  OMNI_BATCH_OK, "release lease");
    fixture.stream = nullptr;
    const auto replacement = omni_speaker_realtime_create(
        fixture.model, 75, &fixture.settings, &fixture.stream);
    expect_status(replacement,
                  name == "model_cancel" ? OMNI_BATCH_CANCELLED : OMNI_BATCH_OK,
                  "replacement admission");
  } else if (name == "late_stream_sync" || name == "late_model_sync" ||
             name == "stream_cache_failure" || name == "model_cache_failure") {
    const bool destroys_model =
        name == "late_model_sync" || name == "model_cache_failure";
    if (destroys_model) {
      expect_status(omni_speaker_realtime_destroy_checked(fixture.stream),
                    OMNI_BATCH_OK, "Release before late model cleanup");
      fixture.stream = nullptr;
    } else {
    }
    if (name.starts_with("late_")) {
      script.fail_sync_call = script.sync_count + 2;
    } else {
      script.cache_failures = 1;
    }
    expect_status(destroys_model
                      ? omni_speaker_destroy_checked(fixture.model)
                      : omni_speaker_realtime_destroy_checked(fixture.stream),
                  OMNI_BATCH_FAILED, "Late checked cleanup fault");
    OmniSpeakerRealtime *replacement = nullptr;
    expect_status(omni_speaker_realtime_create(fixture.model, 74,
                                               &fixture.settings, &replacement),
                  destroys_model ? OMNI_BATCH_CANCELLED : OMNI_BATCH_BUSY,
                  "Late cleanup does not free model slot");
    require(replacement == nullptr, "Late cleanup silently recreated model");
    if (destroys_model) {
      expect_status(omni_speaker_destroy_checked(fixture.model), OMNI_BATCH_OK,
                    "Same late-failed model handle retry");
      fixture.model = nullptr;
    } else {
      expect_status(omni_speaker_realtime_destroy_checked(fixture.stream),
                    OMNI_BATCH_OK, "Same late-failed lease retry");
      fixture.stream = nullptr;
      fixture.create_stream();
    }
  } else if (name == "stream_cleanup_retry" || name == "model_cleanup_retry") {
    if (name == "model_cleanup_retry") {
      expect_status(omni_speaker_realtime_destroy_checked(fixture.stream),
                    OMNI_BATCH_OK, "pre-model release");
      fixture.stream = nullptr;
    } else {
    }
    script.sync_failures = 1;
    const auto failed =
        name == "stream_cleanup_retry"
            ? omni_speaker_realtime_destroy_checked(fixture.stream)
            : omni_speaker_destroy_checked(fixture.model);
    expect_status(failed, OMNI_BATCH_FAILED, "Injected explicit cleanup sync");
    require(script.live_models == 1,
            "Failed checked cleanup released original model owner");
    if (name == "stream_cleanup_retry") {
      require(kind != OMNI_SPEAKER_NEMOTRON || script.live_streams == 1,
              "Failed sync released stream/cache reader");
      OmniSpeakerRealtime *replacement = nullptr;
      expect_status(omni_speaker_realtime_create(
                        fixture.model, 74, &fixture.settings, &replacement),
                    OMNI_BATCH_BUSY, "Failed cleanup replacement");
      expect_status(omni_speaker_destroy_checked(fixture.model),
                    OMNI_BATCH_BUSY, "Failed lease pins model");
      expect_status(omni_speaker_realtime_destroy_checked(fixture.stream),
                    OMNI_BATCH_OK, "Original stream retry");
      fixture.stream = nullptr;
      fixture.create_stream();
      fixture.push(audio(1));
      expect_status(omni_speaker_realtime_finish(fixture.stream), OMNI_BATCH_OK,
                    "Same original model remains healthy");
    } else {
      expect_status(omni_speaker_destroy_checked(fixture.model), OMNI_BATCH_OK,
                    "Original model retry");
      fixture.model = nullptr;
    }
  } else if (name == "stream_failure" || name == "stream_failure_retained") {
    require(kind == OMNI_SPEAKER_NEMOTRON,
            "Only Nemo has eager stream boundary");
    script.fails_stream = true;
    fixture.session_id = 73;
    script.sync_failures = name == "stream_failure_retained" ? 1 : 0;
    expect_status(omni_speaker_realtime_create(
                      fixture.model, 73, &fixture.settings, &fixture.stream),
                  OMNI_BATCH_OUT_OF_MEMORY, "Eager stream allocation");
    require((fixture.stream != nullptr) == (name == "stream_failure_retained"),
            "Failed create lost retry lease");
    if (fixture.stream != nullptr) {
      OmniSpeakerRealtime *replacement = nullptr;
      expect_status(omni_speaker_realtime_create(
                        fixture.model, 74, &fixture.settings, &replacement),
                    OMNI_BATCH_BUSY, "Retained create lease");
      expect_status(omni_speaker_realtime_destroy_checked(fixture.stream),
                    OMNI_BATCH_OK, "Unpublished original lease retry");
      fixture.stream = nullptr;
    } else {
    }
    script.fails_stream = false;
    fixture.create_stream();
  } else if (name == "decode_failure" || name == "decode_allocation") {
    script.fails_decode = name == "decode_failure";
    script.fails_allocation = name == "decode_allocation";
    fixture.push(audio(32000));
    auto event = fixture.wait_segment();
    require(event.kind == OMNI_SPEAKER_FAILED &&
                event.failure_status == OMNI_BATCH_FAILED &&
                event.text == nullptr,
            "Backend failure status leaked or lost");
    omni_speaker_realtime_event_free(&event);
  } else if (name == "blocked_sink") {
    script.blocks_sink = true;
    fixture.push(audio(32000));
    script.sink_gate.wait();
    auto cancelling = std::async(std::launch::async, [&] {
      omni_speaker_realtime_cancel(fixture.stream);
    });
    require(cancelling.wait_for(std::chrono::milliseconds(40)) ==
                std::future_status::timeout,
            "Cancel did not honor actual engine sink barrier");
    OmniSpeakerRealtime *replacement = nullptr;
    expect_status(omni_speaker_realtime_create(fixture.model, 74,
                                               &fixture.settings, &replacement),
                  OMNI_BATCH_BUSY, "In-flight sink still owns lease");
    script.sink_gate.release();
    cancelling.get();
    require(script.sync_count == 0 && script.live_models == 1 &&
                (kind == OMNI_SPEAKER_MOSS || script.live_streams == 1),
            "Sink cancellation falsely released GPU reader/cache/model");
    const auto events = fixture.events();
    require(events.back().at("kind") == OMNI_SPEAKER_CANCELLED,
            "Sink cancellation lost terminal");
    expect_status(omni_speaker_realtime_drain(fixture.stream), OMNI_BATCH_OK,
                  "Sink owner actual worker drain");
    require(script.sync_count >= 2,
            "Sink drain omitted explicit synchronization");
  } else if (name == "blocked_decode" || name == "blocked_finish" ||
             name == "blocked_callback" || name == "blocked_sync") {
    script.blocks_decode = name == "blocked_decode" || name == "blocked_finish";
    script.blocks_callback = name == "blocked_callback";
    fixture.push(audio(32000));
    if (script.blocks_decode) {
      script.decode_gate.wait();
    } else if (script.blocks_callback) {
      script.callback_gate.wait();
    } else {
      wait_callbacks(1);
    }
    if (name == "blocked_finish") {
      script.blocks_finish = true;
      auto finish = std::async(std::launch::async, [&] {
        return omni_speaker_realtime_finish(fixture.stream);
      });
      script.finish_gate.wait();
      const size_t before = new_count;
      const size_t before_malloc = malloc_count;
      uint64_t accepted = 9;
      const float sample = 0.3f;
      fail_new_after = 0;
      fail_malloc_after = 0;
      const auto status =
          omni_speaker_realtime_push(fixture.stream, 2, &sample, 1, &accepted);
      const size_t allocated = new_count - before;
      const size_t malloc_allocated = malloc_count - before_malloc;
      const bool hooks_untouched =
          fail_new_after == 0 && fail_malloc_after == 0;
      fail_new_after = -1;
      fail_malloc_after = -1;
      expect_status(status, OMNI_BATCH_BUSY,
                    "Controlled finish holds command admission");
      require(accepted == 0 && allocated == 0 && malloc_allocated == 0 &&
                  hooks_untouched,
              "BUSY allocated/copied audio before admission");
      script.finish_gate.release();
      omni_speaker_realtime_cancel(fixture.stream);
      expect_status(finish.get(), OMNI_BATCH_CANCELLED,
                    "Cancelled finish wakeup");
    } else {
      omni_speaker_realtime_cancel(fixture.stream);
    }
    require(script.live_models == 1, "Cancel ACK released model");
    if (name == "blocked_sync") {
      script.blocks_sync = true;
    } else {
    }
    auto draining = std::async(std::launch::async, [&] {
      return omni_speaker_realtime_drain(fixture.stream);
    });
    if (name == "blocked_sync") {
      script.sync_gate.wait();
    } else {
    }
    require(
        draining.wait_for(std::chrono::milliseconds(40)) ==
            std::future_status::timeout,
        "Drain falsely succeeded before blocked job/callback/sync returned");
    OmniSpeakerRealtime *replacement = nullptr;
    expect_status(omni_speaker_realtime_create(fixture.model, 74,
                                               &fixture.settings, &replacement),
                  OMNI_BATCH_BUSY, "Blocked GPU slot");
    expect_status(omni_speaker_destroy_checked(fixture.model), OMNI_BATCH_BUSY,
                  "Blocked reader pins model");
    script.decode_gate.release();
    script.callback_gate.release();
    script.sync_gate.release();
    expect_status(draining.get(), OMNI_BATCH_OK, "Actual queued drain barrier");
    require(script.sync_count >= 2, "Drain omitted explicit GPU sync");
    expect_status(omni_speaker_realtime_create(fixture.model, 74,
                                               &fixture.settings, &replacement),
                  OMNI_BATCH_BUSY, "Drained slot still leased");
  } else {
    throw std::invalid_argument("Unknown lifetime case");
  }
  fixture.close();
}
} // namespace native_test
