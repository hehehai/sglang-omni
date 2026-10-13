// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "native_error.h"
#include "native_silero_lifetime.h"
#include "omni_native_core.h"
#include "silero_timestamps.h"

namespace omni_native {

enum class SileroPhase { Active, Completed, Cancelled, Failed };
enum class SileroOperation { Offline, Create, Push, Finish, Drain, DrainAll };

struct SileroCommand {
  SileroOperation operation;
  OmniSileroStream *stream = nullptr;
  std::shared_ptr<std::atomic<bool>> cancel{};
  std::vector<float> audio_samples{};
  silero_vad::TimestampOptions options{};
  std::vector<float> probabilities{};
  std::vector<silero_vad::Timestamp> timestamps{};
  const char *error = nullptr;
};

class SileroWorker {
public:
  SileroWorker() = default;
  bool Load(std::filesystem::path model_directory);
  ~SileroWorker();
  SileroWorker(const SileroWorker &) = delete;
  SileroWorker &operator=(const SileroWorker &) = delete;

  // Note (OpenAI): callers hold command_mutex before copying audio, bounding
  // both the command slot and copied input even with arbitrarily many callers.
  void Execute(SileroCommand &command);
  void CheckCancelled(const SileroCommand &command) const;

  std::mutex command_mutex;
  std::atomic<bool> is_cancelled{false};
  std::array<bool, OMNI_SILERO_MAX_STREAMS> leased_slots{};

private:
  void Run(const std::filesystem::path &model_directory) noexcept;
  std::mutex worker_mutex;
  std::condition_variable worker_condition;
  SileroCommand *queued_command = nullptr;
  bool is_ready = false;
  bool load_failed = false;
  bool is_stopping = false;
  std::thread worker_thread;
};

struct SileroCancelled {};

void ClearSileroError(char **error_message) noexcept;
bool ValidSileroSamples(const float *samples, size_t sample_count,
                        size_t maximum_sample_count) noexcept;

} // namespace omni_native

struct OmniSileroHandle : omni_native::SileroLifetime {
  std::shared_ptr<omni_native::SileroWorker> worker;
};

struct OmniSileroRequest : omni_native::SileroLifetime {
  std::atomic<bool> is_used{false};
  const std::shared_ptr<std::atomic<bool>> cancel =
      std::make_shared<std::atomic<bool>>(false);
};

struct OmniSileroStream : omni_native::SileroLifetime {
  std::shared_ptr<omni_native::SileroWorker> worker;
  std::atomic<omni_native::SileroPhase> phase{omni_native::SileroPhase::Active};
  size_t slot = 0;
  std::array<float, OMNI_SILERO_FRAME_SAMPLES> pending_samples{};
  size_t pending_sample_count = 0;
  uint64_t processed_sample_count = 0;
  uint64_t accepted_audio_sequence = 0;

  void SetTerminal(omni_native::SileroPhase terminal) noexcept;
  bool IsActive() noexcept;
};
