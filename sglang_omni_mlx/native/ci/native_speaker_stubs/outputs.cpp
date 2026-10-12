// SPDX-License-Identifier: Apache-2.0
#include "support.h"
#include <limits>
namespace native_test {
void output_case(OmniSpeakerModelKind kind, const std::string &name) {
  Fixture fixture(kind);
  auto &output = script.output;
  if (name == "text_limit") {
    output.text.assign(65537, 'x');
  } else if (name == "segment_text_limit") {
    output.segments[0].text.assign(65537, 'x');
  } else if (name == "text_utf8") {
    output.text = "\xc0\xaf";
  } else if (name == "text_nul") {
    output.text = std::string("a\0b", 3);
  } else if (name == "metadata_utf8") {
    output.segments[0].language = "\xf4\x90\x80\x80";
  } else if (name == "metadata_nul") {
    output.segments[0].speaker = std::string("s\0p", 3);
  } else if (name == "speaker_limit") {
    output.segments[0].speaker.assign(129, 's');
  } else if (name == "language_limit") {
    output.segments[0].language = std::string(129, 'l');
  } else if (name == "emotion_limit") {
    output.segments[0].emotion = std::string(129, 'e');
  } else if (name == "event_limit") {
    output.segments[0].event = std::string(129, 'e');
  } else if (name == "segments_limit") {
    output.segments.resize(513);
  } else if (name == "time_nan") {
    output.segments[0].start_seconds = std::numeric_limits<double>::quiet_NaN();
  } else if (name == "time_inf") {
    output.segments[0].end_seconds = std::numeric_limits<double>::infinity();
  } else if (name == "time_negative") {
    output.segments[0].start_seconds = -0.1;
  } else if (name == "time_reversed") {
    output.segments[0].end_seconds = 0;
  } else if (name == "aggregate_limit") {
    output.segments.resize(4);
    for (auto &segment : output.segments) {
      segment.text.assign(65536, 'x');
    }
  } else if (name == "exact_aggregate" || name == "aggregate_one_over") {
    output.text.assign(65536, 'x');
    output.segments.assign(3, qwen3_asr::SpeakerSegment{});
    for (auto &segment : output.segments) {
      segment.text.assign(65536, 's');
    }
    output.segments.back().text.resize(name == "exact_aggregate" ? 65529
                                                                 : 65530);
  } else if (name == "unicode_bounds") {
    output.text.clear();
    for (size_t i = 0; i < 32768; ++i) {
      output.text += "\xc3\xa9";
    }
    output.segments.resize(512);
  } else if (name == "exact_bounds") {
    output.text.assign(65536, 'x');
    output.segments[0].speaker.assign(128, 's');
    output.segments[0].language = std::string(128, 'l');
    output.segments.resize(512);
  } else if (name == "queue_slots" || name == "queue_bytes") {
    if (name == "queue_bytes") {
      if (kind == OMNI_SPEAKER_MOSS) {
        output.segments.resize(4);
        for (auto &segment : output.segments) {
          segment.text.assign(60000, 'x');
        }
      } else {
        output.text.assign(65530, 'x');
        output.segments.resize(3);
        for (auto &segment : output.segments) {
          segment.text.assign(60000, 'x');
        }
        script.varies_text = true;
      }
    } else {
      script.varies_text = true;
    }
    bool failed = false;
    const bool nemo_byte_limit =
        kind == OMNI_SPEAKER_NEMOTRON && name == "queue_bytes";
    for (int i = 0; i < (nemo_byte_limit ? 61 : 70); ++i) {
      uint64_t accepted = 0;
      const auto samples = audio(1);
      const auto status = omni_speaker_realtime_push(
          fixture.stream, fixture.next_audio_sequence, samples.data(), 1,
          &accepted);
      if (status == OMNI_BATCH_LIMIT) {
        failed = true;
        break;
      } else {
        expect_status(status, OMNI_BATCH_OK, "queue push");
        require(accepted == fixture.next_audio_sequence++, "Queue ACK");
      }
      if (kind == OMNI_SPEAKER_MOSS) {
        const auto commit = omni_speaker_realtime_commit(fixture.stream);
        if (commit == OMNI_BATCH_LIMIT) {
          failed = true;
          break;
        } else {
          expect_status(commit, OMNI_BATCH_OK, "queue commit");
        }
      } else {
        wait_callbacks(i + 1);
      }
    }
    if (nemo_byte_limit) {
      expect_status(omni_speaker_realtime_commit(fixture.stream),
                    OMNI_BATCH_LIMIT,
                    "Nemo final exceeds aggregate queued bytes");
      failed = true;
    } else {
    }
    require(failed, "Queue did not fail closed at bounded capacity");
    auto events = fixture.events();
    require(events.size() <= 64 &&
                events.back().at("kind") == OMNI_SPEAKER_FAILED &&
                events.back().at("failure_status") == OMNI_BATCH_LIMIT,
            "Reserved terminal lost");
    if (name == "queue_slots") {
      require(events.size() == 64, "Ring capacity/reserved slot mismatch");
    } else {
      require(events.size() < 64, "Aggregate queue-byte bound ignored");
    }
    fixture.close();
    return;
  } else {
    throw std::invalid_argument("Unknown output case");
  }
  fixture.push(audio(1));
  const auto status = omni_speaker_realtime_finish(fixture.stream);
  const bool valid_boundary = name == "exact_bounds" ||
                              name == "exact_aggregate" ||
                              name == "unicode_bounds";
  expect_status(status, valid_boundary ? OMNI_BATCH_OK : OMNI_BATCH_LIMIT,
                "output finish " + name);
  const auto events = fixture.events();
  if (valid_boundary) {
    require(events.back().at("kind") == OMNI_SPEAKER_COMPLETED &&
                events.back().at("text").get<std::string>() == output.text &&
                events.back().at("segments").size() == output.segments.size(),
            "Boundary output truncated");
  } else {
    require(events.back().at("kind") == OMNI_SPEAKER_FAILED &&
                events.back().at("failure_status") == OMNI_BATCH_LIMIT &&
                events.back().at("text").is_null(),
            "Invalid output missing bounded failure terminal");
  }
  fixture.close();
}
} // namespace native_test
