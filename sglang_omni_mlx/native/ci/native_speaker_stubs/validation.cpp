// SPDX-License-Identifier: Apache-2.0
#include "support.h"
#include <limits>
namespace native_test {
void validation_case(OmniSpeakerModelKind kind, const std::string &name) {
  if (name.starts_with("directory_") || name == "nulls") {
    OmniSpeakerHandle *model = nullptr;
    if (name == "nulls") {
      OmniSpeakerRealtimeSettings settings{};
      expect_status(omni_speaker_settings_default(99, &settings),
                    OMNI_BATCH_INVALID, "unknown default");
      expect_status(omni_speaker_settings_default(kind, nullptr),
                    OMNI_BATCH_INVALID, "null settings output");
      expect_status(omni_speaker_create(kind, ".", nullptr), OMNI_BATCH_INVALID,
                    "null model output");
      expect_status(omni_speaker_create(99, ".", &model), OMNI_BATCH_INVALID,
                    "unknown model kind");
      expect_status(
          omni_speaker_realtime_create(nullptr, 1, &settings, nullptr),
          OMNI_BATCH_INVALID, "null lease output");
      uint64_t accepted = 999;
      expect_status(
          omni_speaker_realtime_push(nullptr, 1, nullptr, 1, &accepted),
          OMNI_BATCH_INVALID, "null stream");
      require(accepted == 0, "Null stream ACK not cleared");
      expect_status(omni_speaker_realtime_commit(nullptr), OMNI_BATCH_INVALID,
                    "null commit");
      expect_status(omni_speaker_realtime_finish(nullptr), OMNI_BATCH_INVALID,
                    "null finish");
      OmniSpeakerRealtimeEvent event{};
      require(omni_speaker_realtime_poll(nullptr, &event) == -1 &&
                  event.failure_status == OMNI_BATCH_INVALID,
              "null poll status");
      require(omni_speaker_realtime_poll(nullptr, nullptr) == -1,
              "null poll output");
      omni_speaker_cancel(nullptr);
      omni_speaker_realtime_cancel(nullptr);
      omni_speaker_realtime_event_free(nullptr);
      expect_status(omni_speaker_realtime_drain(nullptr), OMNI_BATCH_OK,
                    "null drain");
      expect_status(omni_speaker_realtime_destroy_checked(nullptr),
                    OMNI_BATCH_OK, "null stream destroy");
      expect_status(omni_speaker_destroy_checked(nullptr), OMNI_BATCH_OK,
                    "null model destroy");
    } else {
      std::string directory =
          name == "directory_long"      ? std::string(8193, 'd')
          : name == "directory_8192"    ? std::string(8192, 'd')
          : name == "directory_utf8"    ? std::string("\xc0\xaf")
          : name == "directory_missing" ? "not-existing-native-model"
                                        : "";
      const char *path = name == "directory_null" ? nullptr : directory.c_str();
      expect_status(omni_speaker_create(kind, path, &model),
                    name == "directory_long" ? OMNI_BATCH_LIMIT
                                             : OMNI_BATCH_INVALID,
                    name);
    }
    require(model == nullptr && script.thread_count == 0,
            "Prevalidation admitted worker/model");
    return;
  } else {
  }
  Fixture fixture(kind, false);
  if (name.starts_with("settings_") || name == "session_zero" ||
      name == "wrong_kind") {
    OmniBatchStatus expected = OMNI_BATCH_INVALID;
    std::string text;
    if (name == "wrong_kind") {
      fixture.settings.model_kind = kind == OMNI_SPEAKER_MOSS ? 2 : 1;
    } else if (name == "settings_long") {
      text.assign(kind == OMNI_SPEAKER_MOSS ? 8193 : 129, 'x');
      expected = OMNI_BATCH_LIMIT;
    } else if (name == "settings_utf8") {
      text = "\xed\xa0\x80";
    } else if (name == "settings_prompt") {
      text = "<|audio_pad|><|audio_pad|>";
    } else if (name == "settings_flag" || name == "settings_negative_flag") {
      fixture.settings.family.nemotron.has_chunk =
          name == "settings_flag" ? 2 : -1;
    } else if (name == "settings_absent_chunk") {
      fixture.settings.family.nemotron.chunk_milliseconds = 1;
    } else if (name == "settings_nan" || name == "settings_inf" ||
               name == "settings_zero" || name == "settings_negative" ||
               name == "settings_chunk_limit") {
      auto &options = fixture.settings.family.nemotron;
      options.has_chunk = 1;
      options.chunk_milliseconds =
          name == "settings_nan"    ? std::numeric_limits<double>::quiet_NaN()
          : name == "settings_inf"  ? std::numeric_limits<double>::infinity()
          : name == "settings_zero" ? 0
          : name == "settings_negative" ? -1
                                        : 120001;
      expected = name == "settings_chunk_limit" ? OMNI_BATCH_LIMIT
                                                : OMNI_BATCH_INVALID;
    } else {
    }
    if (!text.empty()) {
      if (kind == OMNI_SPEAKER_MOSS) {
        fixture.settings.family.moss.prompt = text.c_str();
      } else {
        fixture.settings.family.nemotron.language = text.c_str();
      }
    } else {
    }
    const size_t before_threads = script.thread_count;
    expect_status(omni_speaker_realtime_create(
                      fixture.model, name == "session_zero" ? 0 : 73,
                      name == "settings_null" ? nullptr : &fixture.settings,
                      &fixture.stream),
                  expected, name);
    require(fixture.stream == nullptr && script.thread_count == before_threads,
            "Invalid settings admitted engine/stream");
  } else {
    fixture.create_stream();
    std::vector<float> samples = audio(name == "chunk_limit" ? 32001 : 1);
    uint64_t sequence = name == "sequence_zero"  ? 0
                        : name == "sequence_gap" ? 2
                                                 : 1;
    uint64_t accepted = 999;
    const float *pointer = name == "audio_null" ? nullptr : samples.data();
    size_t sample_count = name == "audio_empty" ? 0 : samples.size();
    if (name == "audio_nan") {
      samples[0] = std::numeric_limits<float>::quiet_NaN();
    } else if (name == "audio_inf") {
      samples[0] = std::numeric_limits<float>::infinity();
    } else if (name == "total_limit") {
      for (size_t i = 0; i < 15; ++i) {
        fixture.push(audio(32000, i * 32000));
      }
      sequence = 16;
    } else if (name == "sequence_repeat") {
      fixture.push(audio(1));
      sequence = 1;
    } else {
    }
    const size_t before_allocations = new_count;
    const auto status = omni_speaker_realtime_push(
        fixture.stream, sequence, pointer, sample_count,
        name == "ack_null" ? nullptr : &accepted);
    const size_t allocations = new_count - before_allocations;
    expect_status(status,
                  name == "chunk_limit" || name == "total_limit"
                      ? OMNI_BATCH_LIMIT
                      : OMNI_BATCH_INVALID,
                  name);
    require(name == "ack_null" || accepted == 0, "Rejected push consumed ACK");
    require(allocations == 0,
            "Invalid/LIMIT input copied/allocated before rejection");
    if (name != "total_limit") {
      fixture.push(audio(1));
    } else {
    }
  }
  fixture.close();
}
} // namespace native_test
