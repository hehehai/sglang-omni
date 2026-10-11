// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <vector>

namespace sortformer {

struct Segment {
  float start = 0.0f;
  float end = 0.0f;
  int speaker = 0;
};

// Swift feed arguments; the defaults are the values Voxt passes.
struct FeedOptions {
  float threshold = 0.5f;
  float min_duration = 0.0f;
  float merge_gap = 0.18f;
  int spkcache_max = 188;
  int fifo_max = 188;
};

struct FeedResult {
  // Row-major (frames, speakers) probabilities of this feed's frames.
  std::vector<float> probabilities;
  int frame_count = 0;
  int speaker_count = 0;
  // Segments in seconds from the start of the stream (framesProcessed before
  // this feed times the frame duration), sorted by start.
  std::vector<Segment> segments;
};

// Per-speaker segments of frames with probability > threshold, as Swift
// predsToSegments: probabilities is row-major (frame_count, speaker_count).
std::vector<Segment> ProbabilitiesToSegments(
    const std::vector<float> &probabilities, int frame_count, int speaker_count,
    float frame_duration, float threshold, float min_duration, float merge_gap);

} // namespace sortformer
