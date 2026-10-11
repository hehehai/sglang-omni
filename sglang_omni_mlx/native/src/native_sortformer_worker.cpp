// SPDX-License-Identifier: Apache-2.0
#include "native_sortformer_worker.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>
#include <stdexcept>
#include <utility>

#include "sortformer_checkpoint.h"

namespace omni_native {

SortformerWorker::SortformerWorker(std::filesystem::path model_directory)
    : worker_thread(
          [this, directory = std::move(model_directory)] { Run(directory); }) {
  std::unique_lock<std::mutex> lock(worker_mutex);
  worker_condition.wait(lock, [this] { return is_ready; });
  if (load_failed) {
    lock.unlock();
    worker_thread.join();
    throw std::runtime_error("Sortformer initialization failed.");
  } else {
  }
}

SortformerWorker::~SortformerWorker() {
  {
    std::lock_guard<std::mutex> lock(worker_mutex);
    is_stopping = true;
  }
  worker_condition.notify_one();
  worker_thread.join();
}

void SortformerWorker::Execute(SortformerCommand &command) {
  std::unique_lock<std::mutex> lock(worker_mutex);
  queued_command = &command;
  worker_condition.notify_one();
  worker_condition.wait(lock, [this] { return queued_command == nullptr; });
}

void SortformerWorker::CheckCancelled(
    const OmniSortformerStream &stream) const {
  if (is_cancelled.load() || stream.phase.load() != SortformerPhase::Active) {
    throw SortformerCancelled{};
  } else {
  }
}

void SortformerWorker::Run(
    const std::filesystem::path &model_directory) noexcept {
  std::unique_ptr<sortformer::SortformerModel> model;
  std::array<std::optional<sortformer::StreamingState>,
             OMNI_SORTFORMER_MAX_STREAMS>
      stream_states;
  bool initialization_failed = false;
  try {
    config = sortformer::LoadConfig(model_directory,
                                    sortformer::ConfigParseMode::Strict);
    maximum_feed_samples = ValidateSortformerConfig(config);
    model =
        std::make_unique<sortformer::SortformerModel>(model_directory, config);
    frame_duration_seconds = model->frame_duration();
    if (!std::isfinite(frame_duration_seconds) || frame_duration_seconds <= 0 ||
        frame_duration_seconds != 1280.0f / OMNI_SORTFORMER_SAMPLE_RATE) {
      throw std::runtime_error("Unsupported Sortformer frame duration.");
    } else {
    }
  } catch (...) {
    initialization_failed = true;
  }
  {
    std::lock_guard<std::mutex> lock(worker_mutex);
    load_failed = initialization_failed;
    is_ready = true;
  }
  worker_condition.notify_one();
  if (initialization_failed) {
    return;
  } else {
  }
  while (true) {
    SortformerCommand *command;
    {
      std::unique_lock<std::mutex> lock(worker_mutex);
      worker_condition.wait(
          lock, [this] { return is_stopping || queued_command != nullptr; });
      if (is_stopping) {
        return;
      } else {
        command = queued_command;
      }
    }
    try {
      switch (command->operation) {
      case SortformerOperation::Create:
        CheckCancelled(*command->stream);
        stream_states[command->stream->slot].emplace(
            model->InitStreamingState());
        // Note (OpenAI): a raced create must not strand arrays in an unleased
        // slot.
        try {
          CheckCancelled(*command->stream);
        } catch (...) {
          stream_states[command->stream->slot].reset();
          throw;
        }
        break;
      case SortformerOperation::Push: {
        auto &stream = *command->stream;
        CheckCancelled(stream);
        auto &state = stream_states[stream.slot].value();
        const int frame_count =
            static_cast<int>((1 + command->audio_samples.size() / 160 + 7) / 8);
        // Note (OpenAI): guard the actual int counter BEFORE Feed increments
        // it.
        if (state.frames_processed < 0 ||
            state.frames_processed >
                std::numeric_limits<int>::max() - frame_count ||
            static_cast<uint64_t>(state.frames_processed) !=
                stream.processed_frame_count) {
          throw std::runtime_error("Sortformer frame counter overflow.");
        } else {
        }
        command->result =
            model->Feed(command->audio_samples, state, stream.options);
        CheckCancelled(stream);
        ValidateSortformerResult(command->result, frame_count,
                                 stream.processed_frame_count,
                                 frame_duration_seconds);
        if (static_cast<uint64_t>(state.frames_processed) !=
                stream.processed_frame_count + frame_count ||
            state.spkcache_length() < 0 ||
            state.spkcache_length() > std::max(stream.options.spkcache_max,
                                               config.modules.spkcache_len) ||
            state.fifo_length() < 0 ||
            state.fifo_length() > stream.options.fifo_max) {
          throw std::runtime_error("Invalid Sortformer state bounds.");
        } else {
          stream.processed_frame_count += frame_count;
        }
        break;
      }
      case SortformerOperation::Drain:
        stream_states[command->stream->slot].reset();
        break;
      case SortformerOperation::DrainAll:
        for (auto &state : stream_states) {
          state.reset();
        }
        break;
      }
    } catch (const SortformerCancelled &) {
      command->error = "Sortformer operation cancelled.";
      command->stream->SetTerminal(SortformerPhase::Cancelled);
    } catch (...) {
      command->error = "Sortformer processing failed.";
      if (command->stream != nullptr) {
        command->stream->SetTerminal(SortformerPhase::Failed);
      } else {
      }
    }
    {
      std::lock_guard<std::mutex> lock(worker_mutex);
      queued_command = nullptr;
    }
    worker_condition.notify_one();
  }
}

void ClearSortformerError(char **error_message) noexcept {
  if (error_message != nullptr) {
    *error_message = nullptr;
  } else {
  }
}

} // namespace omni_native

void OmniSortformerStream::SetTerminal(
    omni_native::SortformerPhase terminal) noexcept {
  auto expected = omni_native::SortformerPhase::Active;
  phase.compare_exchange_strong(expected, terminal);
}

bool OmniSortformerStream::IsActive() noexcept {
  if (worker->is_cancelled.load()) {
    SetTerminal(omni_native::SortformerPhase::Cancelled);
  } else {
  }
  return phase.load() == omni_native::SortformerPhase::Active;
}
