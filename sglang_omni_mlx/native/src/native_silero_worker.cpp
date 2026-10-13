// SPDX-License-Identifier: Apache-2.0
#include "native_silero_worker.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <stdexcept>
#include <utility>

#include "silero_vad.h"

namespace omni_native {

static_assert(OMNI_SILERO_FRAME_SAMPLES == silero_vad::kChunkSamples);
static_assert(OMNI_SILERO_SAMPLE_RATE == silero_vad::kSampleRate);

bool SileroWorker::Load(std::filesystem::path model_directory) {
  worker_thread = std::thread(
      [this, directory = std::move(model_directory)] { Run(directory); });
  std::unique_lock<std::mutex> lock(worker_mutex);
  worker_condition.wait(lock, [this] { return is_ready; });
  return !load_failed;
}

SileroWorker::~SileroWorker() {
  {
    std::lock_guard<std::mutex> lock(worker_mutex);
    is_stopping = true;
  }
  worker_condition.notify_one();
  if (worker_thread.joinable()) {
    worker_thread.join();
  } else {
  }
}

void SileroWorker::Execute(SileroCommand &command) {
  // Note (OpenAI): thread startup failure leaves an owned shell with no work.
  if (!worker_thread.joinable()) {
    return;
  } else {
  }
  std::unique_lock<std::mutex> lock(worker_mutex);
  queued_command = &command;
  worker_condition.notify_one();
  worker_condition.wait(lock, [this] { return queued_command == nullptr; });
}

void SileroWorker::CheckCancelled(const SileroCommand &command) const {
  if (is_cancelled.load() || (command.cancel && command.cancel->load()) ||
      (command.stream != nullptr &&
       command.stream->phase.load() != SileroPhase::Active)) {
    throw SileroCancelled{};
  } else {
  }
}

void SileroWorker::Run(const std::filesystem::path &model_directory) noexcept {
  std::unique_ptr<silero_vad::SileroVAD> model;
  std::array<std::optional<silero_vad::StreamState>, OMNI_SILERO_MAX_STREAMS>
      stream_states;
  bool initialization_failed = false;
  try {
    model = std::make_unique<silero_vad::SileroVAD>(model_directory);
  } catch (...) {
    initialization_failed = true;
  }
  {
    std::lock_guard<std::mutex> lock(worker_mutex);
    load_failed = initialization_failed;
    is_ready = true;
  }
  worker_condition.notify_one();
  // Note (OpenAI): failed construction can leave queued GPU work for DrainAll.
  while (true) {
    SileroCommand *command;
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
      const auto feed = [&](const float *samples,
                            silero_vad::StreamState &state) {
        CheckCancelled(*command);
        const float probability = model->Feed(samples, state);
        CheckCancelled(*command);
        if (!std::isfinite(probability) || probability < 0.0f ||
            probability > 1.0f) {
          throw std::runtime_error("Invalid Silero probability.");
        } else {
          return probability;
        }
      };
      switch (command->operation) {
      case SileroOperation::Offline: {
        CheckCancelled(*command);
        silero_vad::StreamState state;
        const size_t sample_count = command->audio_samples.size();
        command->probabilities.reserve(
            (sample_count + OMNI_SILERO_FRAME_SAMPLES - 1) /
            OMNI_SILERO_FRAME_SAMPLES);
        for (size_t offset = 0; offset < sample_count;
             offset += OMNI_SILERO_FRAME_SAMPLES) {
          std::array<float, OMNI_SILERO_FRAME_SAMPLES> frame{};
          const size_t frame_sample_count = std::min(
              sample_count - offset, size_t{OMNI_SILERO_FRAME_SAMPLES});
          std::copy_n(command->audio_samples.data() + offset,
                      frame_sample_count, frame.data());
          command->probabilities.push_back(feed(frame.data(), state));
        }
        command->timestamps = silero_vad::ProbabilitiesToTimestamps(
            command->probabilities, static_cast<long>(sample_count),
            command->options);
        CheckCancelled(*command);
        break;
      }
      case SileroOperation::Create:
        CheckCancelled(*command);
        stream_states[command->stream->slot].emplace();
        break;
      case SileroOperation::Push: {
        CheckCancelled(*command);
        auto &stream = *command->stream;
        auto &state = *stream_states[stream.slot];
        command->probabilities.reserve(
            (stream.pending_sample_count + command->audio_samples.size()) /
            OMNI_SILERO_FRAME_SAMPLES);
        size_t offset = 0;
        while (offset < command->audio_samples.size()) {
          const size_t copied_sample_count =
              std::min(command->audio_samples.size() - offset,
                       OMNI_SILERO_FRAME_SAMPLES - stream.pending_sample_count);
          std::copy_n(
              command->audio_samples.data() + offset, copied_sample_count,
              stream.pending_samples.data() + stream.pending_sample_count);
          stream.pending_sample_count += copied_sample_count;
          offset += copied_sample_count;
          if (stream.pending_sample_count == OMNI_SILERO_FRAME_SAMPLES) {
            command->probabilities.push_back(
                feed(stream.pending_samples.data(), state));
            stream.processed_sample_count += OMNI_SILERO_FRAME_SAMPLES;
            stream.pending_sample_count = 0;
          } else {
          }
        }
        CheckCancelled(*command);
        break;
      }
      case SileroOperation::Finish: {
        CheckCancelled(*command);
        auto &stream = *command->stream;
        if (stream.pending_sample_count != 0) {
          std::fill(stream.pending_samples.begin() +
                        stream.pending_sample_count,
                    stream.pending_samples.end(), 0.0f);
          command->probabilities.push_back(
              feed(stream.pending_samples.data(), *stream_states[stream.slot]));
          stream.processed_sample_count += OMNI_SILERO_FRAME_SAMPLES;
          stream.pending_sample_count = 0;
        } else {
        }
        CheckCancelled(*command);
        break;
      }
      case SileroOperation::Drain:
        mlx::core::synchronize();
        stream_states[command->stream->slot].reset();
        command->stream->pending_sample_count = 0;
        mlx::core::synchronize();
        break;
      case SileroOperation::DrainAll:
        mlx::core::synchronize();
        for (auto &state : stream_states) {
          state.reset();
        }
        model.reset();
        mlx::core::clear_cache();
        mlx::core::synchronize();
        break;
      }
    } catch (const SileroCancelled &) {
      command->error = "Silero operation cancelled.";
      if (command->stream != nullptr) {
        command->stream->SetTerminal(SileroPhase::Cancelled);
      } else {
      }
    } catch (...) {
      command->error = "Silero processing failed.";
      if (command->stream != nullptr) {
        command->stream->SetTerminal(SileroPhase::Failed);
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

void ClearSileroError(char **error_message) noexcept {
  if (error_message != nullptr) {
    *error_message = nullptr;
  } else {
  }
}

bool ValidSileroSamples(const float *samples, size_t sample_count,
                        size_t maximum_sample_count) noexcept {
  return samples != nullptr && sample_count > 0 &&
         sample_count <= maximum_sample_count &&
         std::all_of(samples, samples + sample_count,
                     [](float sample) { return std::isfinite(sample); });
}

} // namespace omni_native

void OmniSileroStream::SetTerminal(omni_native::SileroPhase terminal) noexcept {
  auto expected = omni_native::SileroPhase::Active;
  phase.compare_exchange_strong(expected, terminal);
}

bool OmniSileroStream::IsActive() noexcept {
  if (worker->is_cancelled.load()) {
    SetTerminal(omni_native::SileroPhase::Cancelled);
  } else {
  }
  return phase.load() == omni_native::SileroPhase::Active;
}
