// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <memory>
#include <mutex>
#include <string_view>
#include <vector>

#include "worker.h"

namespace omni_native {

struct RealtimeState;

struct ModelState {
  std::mutex mutex;
  bool is_cancelled = false;
  qwen3_asr::Qwen3ASRTranscriber *transcriber = nullptr;
  std::unique_ptr<qwen3_asr::TranscriptionWorker> worker;
  std::vector<std::weak_ptr<RealtimeState>> sessions;

  void Stop(bool drain);
};

char *CopyString(std::string_view string);
void SetError(char **error_message, const char *message) noexcept;

} // namespace omni_native

struct OmniQwenHandle {
  std::shared_ptr<omni_native::ModelState> state;
};
