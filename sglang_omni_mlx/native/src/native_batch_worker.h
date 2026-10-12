// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "omni_native_batch.h"

namespace qwen3_asr {
struct TranscriptionResult;
}

namespace omni_native {

struct BatchCommand {
  std::vector<float> samples;
  OmniBatchOptions options;
  const std::atomic<bool> &is_cancelled;
  OmniBatchResult *result;
  OmniBatchStatus status = OMNI_BATCH_FAILED;
};

class BatchWorker {
public:
  BatchWorker(OmniBatchModelKind model_kind,
              const std::filesystem::path &model_directory);
  ~BatchWorker();
  BatchWorker(const BatchWorker &) = delete;
  BatchWorker &operator=(const BatchWorker &) = delete;

  void Execute(BatchCommand &command);
  void Shutdown();

  const OmniBatchModelKind model_kind;
  OmniBatchStatus load_status = OMNI_BATCH_FAILED;
  std::mutex lease_mutex;
  std::atomic<bool> is_cancelled{false};
  // Note (OpenAI): the single lease pins this cancellation slot through drain.
  std::atomic<bool> request_is_cancelled{false};
  bool has_request_lease = false;

private:
  void Run(const std::filesystem::path &model_directory) noexcept;
  std::mutex worker_mutex;
  std::condition_variable worker_condition;
  BatchCommand *queued_command = nullptr;
  bool is_ready = false;
  bool is_stopping = false;
  std::thread worker_thread;
};

OmniBatchStatus ValidateBatchInput(OmniBatchModelKind model_kind,
                                   const float *samples, size_t sample_count,
                                   const OmniBatchOptions *options);
OmniBatchStatus CopyBatchResult(const qwen3_asr::TranscriptionResult &source,
                                OmniBatchResult *result);
bool BatchStringFits(const char *text, size_t maximum_bytes) noexcept;

} // namespace omni_native

struct OmniBatchHandle {
  std::shared_ptr<omni_native::BatchWorker> worker;
};

struct OmniBatchRequest {
  std::shared_ptr<omni_native::BatchWorker> worker;
  std::mutex command_mutex;
  bool is_used = false;
};
