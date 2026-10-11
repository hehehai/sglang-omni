// SPDX-License-Identifier: Apache-2.0
// Real checkpoint/config translation unit; only MLX file/tensor calls stubbed.
#include "sortformer_checkpoint.h"
#include "sortformer_config_fixture.h"

#include <cassert>
#include <iostream>

int main(int argument_count, char **arguments) {
  assert(argument_count == 2);
  const std::string mode = arguments[1];
  assert(mode == "legacy" || mode == "strict");
  try {
    const auto directory = std::filesystem::current_path();
    const auto config =
        mode == "legacy" ? sortformer::LoadConfig(directory)
                         : sortformer::LoadConfig(
                               directory, sortformer::ConfigParseMode::Strict);
    std::cout << omni_test::ConfigJson(config).dump() << '\n';
    return 0;
  } catch (const std::exception &) {
    std::cerr << "Invalid configuration.\n";
    return 1;
  }
}
