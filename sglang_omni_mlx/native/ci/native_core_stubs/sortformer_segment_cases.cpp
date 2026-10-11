// SPDX-License-Identifier: Apache-2.0
// Real CPU segment algorithm: no MLX or model stand-ins linked here.
#include "sortformer_segments.h"

#include <bit>
#include <cassert>
#include <cstdint>
#include <limits>
#include <string>

int main(int argument_count, char **arguments) {
  assert(argument_count == 2);
  const std::string test = arguments[1];
  if (test == "empty_threshold") {
    assert(sortformer::ProbabilitiesToSegments({}, 0, 4, 0.08f, 0.5f, 0, 0)
               .empty());
    assert(sortformer::ProbabilitiesToSegments({0.5f, 0.0f, 0.25f, 0.5f}, 1, 4,
                                               0.08f, 0.5f, 0, 0)
               .empty());
    const auto segments = sortformer::ProbabilitiesToSegments(
        {0.500001f, 0.5f, 1.0f, 0}, 1, 4, 0.08f, 0.5f, 0, 0);
    assert(segments.size() == 2 && segments[0].speaker == 0 &&
           segments[1].speaker == 2);
    assert(segments[0].start == 0 && segments[0].end == 0.08f);
  } else if (test == "duration_before_merge") {
    const std::vector<float> probabilities{1, 0, 1, 1};
    const auto segments = sortformer::ProbabilitiesToSegments(
        probabilities, 4, 1, 0.125f, 0.5f, 0.25f, 1.0f);
    assert(segments.size() == 1 && segments[0].start == 0.25f &&
           segments[0].end == 0.5f);
    assert(sortformer::ProbabilitiesToSegments(probabilities, 4, 1, 0.125f,
                                               0.5f, 0.251f, 1.0f)
               .empty());
  } else if (test == "merge_boundary") {
    const std::vector<float> probabilities{1, 0, 1, 0, 1};
    const auto merged = sortformer::ProbabilitiesToSegments(
        probabilities, 5, 1, 0.125f, 0.5f, 0, 0.125f);
    assert(merged.size() == 1 && merged[0].start == 0 &&
           merged[0].end == 0.625f);
    const auto separated = sortformer::ProbabilitiesToSegments(
        probabilities, 5, 1, 0.125f, 0.5f, 0, 0.124f);
    assert(separated.size() == 3 && separated[1].start == 0.25f &&
           separated[2].end == 0.625f);
  } else if (test == "overlap_stable_order") {
    const std::vector<float> probabilities{0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1};
    const auto segments = sortformer::ProbabilitiesToSegments(
        probabilities, 3, 4, 0.08f, 0.5f, 0, 0);
    assert(segments.size() == 4);
    assert(segments[0].speaker == 1 && segments[1].speaker == 2);
    assert(segments[2].speaker == 0 && segments[3].speaker == 3);
    assert(segments[0].start == 0 && segments[0].end == 2 * 0.08f);
    assert(segments[2].start == 0.08f && segments[2].end == 3 * 0.08f);
  } else if (test == "float_rounding") {
    std::vector<float> probabilities(26 * 4, 0);
    for (int frame = 3; frame < 26; ++frame) {
      probabilities[frame * 4 + 3] = 1;
    }
    const auto segments = sortformer::ProbabilitiesToSegments(
        probabilities, 26, 4, 0.08f, 0.5f, 0, 0);
    assert(segments.size() == 1 && segments[0].speaker == 3);
    assert(std::bit_cast<uint32_t>(segments[0].start) == 0x3e75c28f);
    assert(std::bit_cast<uint32_t>(segments[0].end) == 0x40051eb8);
  } else {
    assert(false && "Unknown segment case");
  }
}
