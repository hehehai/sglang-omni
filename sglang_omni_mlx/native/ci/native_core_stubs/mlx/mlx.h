// SPDX-License-Identifier: Apache-2.0
// Explicit CPU stand-in: tracks array ownership, not MLX computation.
#pragma once

#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace omni_test {
struct ArrayLifetime;
struct SortformerArrayLifetime;
} // namespace omni_test

namespace mlx::core {
class array {
public:
  array() = default;
  explicit array(bool is_model);
  array(bool is_model, std::vector<int> dimensions);
  int shape(int axis) const { return dimensions.at(axis); }
  size_t ndim() const { return dimensions.size(); }

private:
  std::shared_ptr<omni_test::ArrayLifetime> lifetime;
  std::shared_ptr<omni_test::SortformerArrayLifetime> sortformer_lifetime;
  std::vector<int> dimensions;
};

// Note (OpenAI): the real checkpoint translation unit is linked, but tests
// must never mistake these file/tensor boundaries for actual weight loading.
inline array transpose(const array &, const std::vector<int> &) {
  throw std::logic_error("MLX transpose is unavailable in CPU tests.");
}
inline std::pair<std::unordered_map<std::string, array>,
                 std::unordered_map<std::string, std::string>>
load_safetensors(const std::string &) {
  throw std::logic_error("MLX file loading is unavailable in CPU tests.");
}
inline void eval(const std::vector<array> &) {
  throw std::logic_error("MLX evaluation is unavailable in CPU tests.");
}

void synchronize();
void clear_cache();
} // namespace mlx::core
