// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

#include "native_error.h"
#include "native_sortformer_validation.h"

namespace omni_native {

enum class SortformerPhase { Active, Completed, Cancelled, Failed };
enum class SortformerOperation { Create, Push, Drain, DrainAll };

struct SortformerCommand {
  SortformerOperation operation;
  OmniSortformerStream *stream = nullptr;
  std::vector<float> audio_samples{};
  sortformer::FeedResult result{};
  const char *error = nullptr;
};

class SortformerWorker {
public:
  explicit SortformerWorker(std::filesystem::path model_directory);
  ~SortformerWorker();
  SortformerWorker(const SortformerWorker &) = delete;
  SortformerWorker &operator=(const SortformerWorker &) = delete;

  // Note (OpenAI): callers hold command_mutex BEFORE copying audio, bounding
  // both the command slot and copied input independently of caller count.
  void Execute(SortformerCommand &command);
  void CheckCancelled(const OmniSortformerStream &stream) const;

  std::mutex command_mutex;
  std::atomic<bool> is_cancelled{false};
  std::array<bool, OMNI_SORTFORMER_MAX_STREAMS> leased_slots{};
  sortformer::Config config;
  size_t maximum_feed_samples = 0;
  float frame_duration_seconds = 0;

private:
  void Run(const std::filesystem::path &model_directory) noexcept;
  std::mutex worker_mutex;
  std::condition_variable worker_condition;
  SortformerCommand *queued_command = nullptr;
  bool is_ready = false;
  bool load_failed = false;
  bool is_stopping = false;
  std::thread worker_thread;
};

struct SortformerCancelled {};
void ClearSortformerError(char **error_message) noexcept;

} // namespace omni_native

struct OmniSortformerHandle {
  std::shared_ptr<omni_native::SortformerWorker> worker;
};

struct OmniSortformerStream {
  std::shared_ptr<omni_native::SortformerWorker> worker;
  std::atomic<omni_native::SortformerPhase> phase{
      omni_native::SortformerPhase::Active};
  sortformer::FeedOptions options;
  size_t slot = 0;
  uint64_t processed_frame_count = 0;
  uint64_t accepted_audio_sequence = 0;

  void SetTerminal(omni_native::SortformerPhase terminal) noexcept;
  bool IsActive() noexcept;
};
