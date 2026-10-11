// SPDX-License-Identifier: Apache-2.0
#include <iostream>
#include <string>

#include "realtime_stubs/support.h"

int main(int argument_count, char **arguments) {
  try {
    qwen3_asr::realtime_test::require(argument_count == 3,
                                      "Usage: realtime_cases http|engine CASE");
    const std::string mode = arguments[1];
    const std::string case_name = arguments[2];
    if (mode == "http") {
      std::cout << qwen3_asr::realtime_test::run_http_case(case_name).dump()
                << '\n';
#ifndef OMNI_REALTIME_BASELINE
    } else if (mode == "engine") {
      std::cout << qwen3_asr::realtime_test::run_engine_case(case_name).dump()
                << '\n';
#endif
    } else {
      throw std::invalid_argument("Unknown test mode: " + mode);
    }
    return 0;
  } catch (const std::exception &failure) {
    std::cerr << failure.what() << '\n';
    return 1;
  }
}
