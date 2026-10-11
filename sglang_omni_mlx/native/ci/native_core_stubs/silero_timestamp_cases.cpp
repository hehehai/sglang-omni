// SPDX-License-Identifier: Apache-2.0
// Synthetic probabilities exercise the real pure production timestamp body.
#include "silero_timestamps.h"

#include <cassert>
#include <iostream>
#include <string>

int main(int argument_count, char **arguments) {
  assert(argument_count == 2);
  const std::string test = arguments[1];
  using silero_vad::Timestamp;
  struct TimestampCase {
    std::vector<float> probabilities;
    long sample_count;
    silero_vad::TimestampOptions options;
    std::vector<Timestamp> expected;
  };
  std::vector<TimestampCase> cases;
  if (test == "empty_threshold") {
    cases = {
        {{}, 0, {0.5f, 0, 0, 0}, {}},
        {{0, 0, 0}, 1536, {0.5f, 0, 0, 0}, {}},
        {{0.499f}, 512, {0.5f, 0, 0, 0}, {}},
        {{0.5f}, 512, {0.5f, 0, 0, 0}, {{0, 512}}},
        {{1.0f}, 512, {1.0f, 0, 0, 0}, {{0, 512}}},
        {{0.0f}, 512, {0.0f, 0, 0, 0}, {{0, 512}}},
        {{0.1f, 0.005f}, 1024, {0.1f, 0, 0, 0}, {{0, 512}}},
    };
  } else if (test == "duration_clipping") {
    cases = {
        {{0.8f}, 511, {0.5f, 32, 0, 0}, {}},
        {{0.8f}, 512, {0.5f, 32, 0, 0}, {{0, 512}}},
        {{0.8f}, 512, {0.5f, 33, 0, 0}, {}},
        {{0.8f, 0.8f}, 513, {0.5f, 0, 0, 0}, {{0, 513}}},
        {{0.0f, 0.8f, 0.8f}, 1100, {0.5f, 0, 0, 0}, {{512, 1100}}},
        {{0.8f}, 1024, {0.5f, 0, 0, 0}, {{0, 512}}},
        {{0.8f, 0.8f}, 1024, {0.5f, 30000, 0, 0}, {}},
    };
  } else if (test == "silence_hysteresis") {
    cases = {
        {{0.8f, 0.4f, 0.36f, 0.1f}, 2048, {0.5f, 0, 0, 0}, {{0, 1536}}},
        {{0.8f, 0.8f, 0.0f, 0.0f, 0.0f}, 2560, {0.5f, 32, 64, 0}, {{0, 1024}}},
        {{0.8f, 0.8f, 0.0f, 0.0f}, 2048, {0.5f, 32, 64, 0}, {{0, 2048}}},
        {{0.8f, 0.0f, 0.8f, 0.0f, 0.0f}, 2560, {0.5f, 0, 32, 0}, {{0, 1536}}},
        {{0.8f, 0.0f, 0.0f}, 1536, {0.5f, 33, 32, 0}, {}},
    };
  } else if (test == "padding_merge") {
    cases = {
        {{0.0f, 0.8f, 0.0f}, 1536, {0.5f, 0, 0, 30}, {{32, 1504}}},
        {{0.8f, 0.0f, 0.8f}, 1536, {0.5f, 0, 0, 0}, {{0, 512}, {1024, 1536}}},
        {{0.8f, 0.0f, 0.8f}, 1536, {0.5f, 0, 0, 15}, {{0, 752}, {784, 1536}}},
        {{0.8f, 0.0f, 0.8f}, 1536, {0.5f, 0, 0, 16}, {{0, 1536}}},
        {{0.8f, 0.0f, 0.8f}, 1536, {0.5f, 0, 0, 30}, {{0, 1536}}},
        {{0.8f}, 1, {0.5f, 0, 0, 30000}, {{0, 1}}},
    };
  } else {
    assert(false && "Unknown pure timestamp test");
  }
  for (const auto &input : cases) {
    const auto actual = silero_vad::ProbabilitiesToTimestamps(
        input.probabilities, input.sample_count, input.options);
    assert(actual.size() == input.expected.size());
    for (size_t i = 0; i < actual.size(); ++i) {
      assert(actual[i].start == input.expected[i].start);
      assert(actual[i].end == input.expected[i].end);
    }
  }
  std::cout << "PASS " << test << " (real pure timestamp algorithm)\n";
}
