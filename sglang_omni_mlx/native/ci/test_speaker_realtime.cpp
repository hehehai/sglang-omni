// SPDX-License-Identifier: Apache-2.0
#include "speaker_realtime_stubs/support.h"

#include <iostream>

int main(int argument_count, char **arguments) {
  try {
    speaker_test::require(argument_count == 4, "Expected mode family case");
    const std::string mode = arguments[1];
    const std::string family_name = arguments[2];
    speaker_test::require(family_name == "moss" || family_name == "nemotron",
                          "Unknown family");
    const auto family = family_name == "moss" ? speaker_test::Family::kMoss
                                              : speaker_test::Family::kNemotron;
    const std::string name = arguments[3];
    nlohmann::ordered_json trace;
    if (mode == "http") {
      trace = speaker_test::http_case(family, name);
    } else if (mode == "http_race") {
      trace = speaker_test::http_race_case(family, name);
#ifndef SPEAKER_BASELINE
    } else if (mode == "engine") {
      trace = speaker_test::engine_case(family, name);
    } else if (mode == "engine_race") {
      trace = speaker_test::engine_race_case(family, name);
#endif
    } else {
      throw std::invalid_argument("Unknown mode");
    }
    std::cout << trace.dump() << '\n';
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
