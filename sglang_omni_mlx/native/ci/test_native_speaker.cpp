// SPDX-License-Identifier: Apache-2.0
#include "native_speaker_stubs/support.h"
#include <iostream>
int main(int argument_count, char **arguments) {
  try {
    native_test::require(argument_count >= 4,
                         "Expected kind category case [allocation index]");
    const int kind = std::stoi(arguments[1]);
    native_test::require(kind == OMNI_SPEAKER_MOSS ||
                             kind == OMNI_SPEAKER_NEMOTRON,
                         "Unknown model kind");
    const std::string category = arguments[2];
    const std::string name = arguments[3];
    if (category == "protocol") {
      native_test::protocol_case(kind, name);
    } else if (category == "validation") {
      native_test::validation_case(kind, name);
    } else if (category == "outputs") {
      native_test::output_case(kind, name);
    } else if (category == "lifetime") {
      native_test::lifetime_case(kind, name);
    } else if (category == "fault") {
      native_test::fault_case(kind, name,
                              argument_count > 4 ? std::stoi(arguments[4]) : 0);
    } else if (category == "trace") {
      std::cout << native_test::trace_case(kind, name).dump() << '\n';
      return 0;
    } else {
      throw std::invalid_argument("Unknown test category");
    }
    std::cout << nlohmann::ordered_json{{"passed", name}, {"kind", kind}}.dump()
              << '\n';
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
