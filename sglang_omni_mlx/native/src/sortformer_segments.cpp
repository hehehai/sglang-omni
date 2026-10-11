// SPDX-License-Identifier: Apache-2.0
#include "sortformer_segments.h"

#include <algorithm>
#include <utility>

// Note (Jiaxin Deng): Swift never fuses a multiply and an add; segment times
// must not either.
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#endif

namespace sortformer {

std::vector<Segment>
ProbabilitiesToSegments(const std::vector<float> &probabilities,
                        int frame_count, int speaker_count,
                        float frame_duration, float threshold,
                        float min_duration, float merge_gap) {
  std::vector<Segment> segments;
  for (int speaker = 0; speaker < speaker_count; ++speaker) {
    std::vector<Segment> speaker_segments;
    int segment_start = -1;
    const auto close = [&](int end_frame) {
      const float start_time =
          static_cast<float>(segment_start) * frame_duration;
      const float end_time = static_cast<float>(end_frame) * frame_duration;
      if (end_time - start_time >= min_duration) {
        speaker_segments.push_back({start_time, end_time, speaker});
      } else {
      }
    };
    for (int frame = 0; frame < frame_count; ++frame) {
      const bool active =
          probabilities[static_cast<size_t>(frame) * speaker_count + speaker] >
          threshold;
      if (active) {
        if (segment_start < 0) {
          segment_start = frame;
        } else {
        }
      } else if (segment_start >= 0) {
        close(frame);
        segment_start = -1;
      } else {
      }
    }
    if (segment_start >= 0) {
      close(frame_count);
    } else {
    }
    if (merge_gap > 0 && speaker_segments.size() > 1) {
      std::vector<Segment> merged = {speaker_segments.front()};
      for (size_t i = 1; i < speaker_segments.size(); ++i) {
        const Segment &segment = speaker_segments[i];
        if (segment.start - merged.back().end <= merge_gap) {
          merged.back() = {merged.back().start, segment.end, segment.speaker};
        } else {
          merged.push_back(segment);
        }
      }
      speaker_segments = std::move(merged);
    } else {
    }
    segments.insert(segments.end(), speaker_segments.begin(),
                    speaker_segments.end());
  }
  // Note (Jiaxin Deng): Swift's sort is stable in practice; ties keep speaker
  // order.
  std::stable_sort(
      segments.begin(), segments.end(),
      [](const Segment &a, const Segment &b) { return a.start < b.start; });
  return segments;
}

} // namespace sortformer
