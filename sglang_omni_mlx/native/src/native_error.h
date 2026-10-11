// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <string_view>

namespace omni_native {

char *CopyString(std::string_view string);
void SetError(char **error_message, const char *message) noexcept;

} // namespace omni_native
