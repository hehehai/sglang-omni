// SPDX-License-Identifier: Apache-2.0
// Explicit CPU stand-in: tracks array ownership, not MLX computation.
#pragma once

#include <memory>

namespace omni_test {
struct ArrayLifetime;
}

namespace mlx::core {
class array {
public:
  explicit array(bool is_model);

private:
  std::shared_ptr<omni_test::ArrayLifetime> lifetime;
};

void synchronize();
void clear_cache();
} // namespace mlx::core
