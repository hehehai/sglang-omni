// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "omni_native_core.h"
#include "sortformer.h"

namespace omni_native {

size_t ValidateSortformerConfig(const sortformer::Config &config);
void ValidateSortformerSettings(const OmniSortformerSettings &settings,
                                const sortformer::Config &config);
void ValidateSortformerResult(const sortformer::FeedResult &result,
                              int expected_frame_count,
                              uint64_t previous_frame_count,
                              float frame_duration_seconds);

} // namespace omni_native
