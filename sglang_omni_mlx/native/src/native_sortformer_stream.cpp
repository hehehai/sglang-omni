// SPDX-License-Identifier: Apache-2.0
#include "native_sortformer_worker.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>

using omni_native::ClearSortformerError;
using omni_native::SetError;
using omni_native::SortformerCommand;
using omni_native::SortformerOperation;
using omni_native::SortformerPhase;

namespace {

struct SortformerAdmission {
  OmniSortformerStream &stream;
  bool is_successful = false;

  ~SortformerAdmission() {
    // Note (OpenAI): terminalize admitted failures before unlocking the gate.
    if (!is_successful && stream.IsActive()) {
      stream.SetTerminal(SortformerPhase::Failed);
    } else {
    }
  }
};

} // namespace

OmniSortformerStream *
omni_sortformer_stream_create(OmniSortformerHandle *handle,
                              const OmniSortformerSettings *settings,
                              char **error_message) {
  ClearSortformerError(error_message);
  try {
    if (handle == nullptr || settings == nullptr) {
      SetError(error_message, "Invalid Sortformer stream input.");
      return nullptr;
    } else {
    }
    const auto worker = handle->worker;
    omni_native::ValidateSortformerSettings(*settings, worker->config);
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    const auto slot = std::find(worker->leased_slots.begin(),
                                worker->leased_slots.end(), false);
    if (worker->is_cancelled.load()) {
      SetError(error_message, "Sortformer operation cancelled.");
      return nullptr;
    } else if (slot == worker->leased_slots.end()) {
      SetError(error_message, "Sortformer stream limit exceeded.");
      return nullptr;
    } else {
    }
    auto stream = std::make_unique<OmniSortformerStream>();
    stream->worker = worker;
    stream->options = {settings->threshold, settings->minimum_duration_seconds,
                       settings->merge_gap_seconds,
                       settings->speaker_cache_max_frames,
                       settings->fifo_max_frames};
    stream->slot = static_cast<size_t>(slot - worker->leased_slots.begin());
    SortformerCommand command{.operation = SortformerOperation::Create,
                              .stream = stream.get()};
    worker->Execute(command);
    if (command.error != nullptr) {
      SetError(error_message, command.error);
      return nullptr;
    } else {
      *slot = true;
      return stream.release();
    }
  } catch (...) {
    SetError(error_message,
             "Sortformer stream initialization failed or invalid settings.");
    return nullptr;
  }
}

int omni_sortformer_stream_push(OmniSortformerStream *stream,
                                uint64_t audio_sequence, const float *samples,
                                size_t sample_count,
                                uint64_t *accepted_audio_sequence,
                                OmniSortformerResult *result,
                                char **error_message) {
  ClearSortformerError(error_message);
  if (accepted_audio_sequence != nullptr) {
    *accepted_audio_sequence = 0;
  } else {
  }
  if (result != nullptr) {
    *result = {};
  } else {
  }
  try {
    if (stream == nullptr || result == nullptr ||
        accepted_audio_sequence == nullptr || audio_sequence == 0 ||
        samples == nullptr || sample_count == 0 ||
        sample_count > OMNI_SORTFORMER_MAX_CHUNK_SAMPLES ||
        !std::all_of(samples, samples + sample_count,
                     [](float sample) { return std::isfinite(sample); })) {
      SetError(error_message, "Invalid Sortformer stream input.");
      return 0;
    } else {
    }
    const auto worker = stream->worker;
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    const uint64_t frame_count = (1 + sample_count / 160 + 7) / 8;
    if (!stream->IsActive()) {
      SetError(error_message, "Sortformer stream is terminal.");
      return 0;
    } else if (sample_count > worker->maximum_feed_samples) {
      SetError(error_message,
               "Sortformer input exceeds model-specific feed cap.");
      return 0;
    } else if (stream->accepted_audio_sequence ==
                   std::numeric_limits<uint64_t>::max() ||
               audio_sequence != stream->accepted_audio_sequence + 1) {
      SetError(error_message, "Invalid audio sequence.");
      return 0;
    } else if (stream->processed_frame_count >
               static_cast<uint64_t>(std::numeric_limits<int>::max()) -
                   frame_count) {
      SetError(error_message, "Sortformer frame counter overflow.");
      return 0;
    } else {
    }
    SortformerCommand command{.operation = SortformerOperation::Push,
                              .stream = stream};
    command.audio_samples.assign(samples, samples + sample_count);
    worker->CheckCancelled(*stream);
    SortformerAdmission admission{*stream};
    stream->accepted_audio_sequence = audio_sequence;
    worker->Execute(command);
    if (command.error != nullptr) {
      SetError(error_message, command.error);
      return 0;
    } else {
    }
    const auto &feed_result = command.result;
    std::unique_ptr<float, decltype(&std::free)> probabilities(
        static_cast<float *>(
            std::malloc(feed_result.probabilities.size() * sizeof(float))),
        &std::free);
    if (!probabilities) {
      throw std::bad_alloc();
    } else {
      std::memcpy(probabilities.get(), feed_result.probabilities.data(),
                  feed_result.probabilities.size() * sizeof(float));
    }
    std::unique_ptr<OmniSortformerSegment, decltype(&std::free)> segments(
        nullptr, &std::free);
    if (!feed_result.segments.empty()) {
      segments.reset(static_cast<OmniSortformerSegment *>(std::malloc(
          feed_result.segments.size() * sizeof(OmniSortformerSegment))));
      if (!segments) {
        throw std::bad_alloc();
      } else {
        for (size_t i = 0; i < feed_result.segments.size(); ++i) {
          const auto &segment = feed_result.segments[i];
          segments.get()[i] = {segment.start, segment.end, segment.speaker};
        }
      }
    } else {
    }
    worker->CheckCancelled(*stream);
    *result = {probabilities.release(),        feed_result.probabilities.size(),
               feed_result.frame_count,        feed_result.speaker_count,
               worker->frame_duration_seconds, segments.release(),
               feed_result.segments.size(),    stream->processed_frame_count};
    *accepted_audio_sequence = audio_sequence;
    admission.is_successful = true;
    return 1;
  } catch (const omni_native::SortformerCancelled &) {
    stream->SetTerminal(SortformerPhase::Cancelled);
    SetError(error_message, "Sortformer operation cancelled.");
    return 0;
  } catch (...) {
    SetError(error_message, "Sortformer stream processing failed.");
    return 0;
  }
}

int omni_sortformer_stream_finish(OmniSortformerStream *stream,
                                  char **error_message) {
  ClearSortformerError(error_message);
  try {
    if (stream == nullptr) {
      SetError(error_message, "Invalid Sortformer stream input.");
      return 0;
    } else {
    }
    const auto worker = stream->worker;
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    if (stream->phase.load() == SortformerPhase::Completed) {
      return 1;
    } else if (!stream->IsActive()) {
      SetError(error_message, "Sortformer stream is terminal.");
      return 0;
    } else {
      auto expected = SortformerPhase::Active;
      if (stream->phase.compare_exchange_strong(expected,
                                                SortformerPhase::Completed)) {
        return 1;
      } else {
        SetError(error_message, "Sortformer operation cancelled.");
        return 0;
      }
    }
  } catch (...) {
    SetError(error_message, "Sortformer stream finalization failed.");
    return 0;
  }
}

void omni_sortformer_stream_cancel(OmniSortformerStream *stream) {
  if (stream != nullptr) {
    stream->SetTerminal(SortformerPhase::Cancelled);
  } else {
  }
}

int omni_sortformer_stream_drain(OmniSortformerStream *stream,
                                 char **error_message) {
  ClearSortformerError(error_message);
  try {
    if (stream == nullptr) {
      SetError(error_message, "Invalid Sortformer stream input.");
      return 0;
    } else if (stream->IsActive()) {
      SetError(error_message, "Sortformer stream is not terminal.");
      return 0;
    } else {
      const auto worker = stream->worker;
      std::lock_guard<std::mutex> lock(worker->command_mutex);
      SortformerCommand command{.operation = SortformerOperation::Drain,
                                .stream = stream};
      worker->Execute(command);
      if (command.error != nullptr) {
        SetError(error_message, command.error);
        return 0;
      } else {
        return 1;
      }
    }
  } catch (...) {
    SetError(error_message, "Sortformer stream drain failed.");
    return 0;
  }
}

void omni_sortformer_stream_destroy(OmniSortformerStream *stream) {
  try {
    if (stream != nullptr) {
      stream->SetTerminal(SortformerPhase::Cancelled);
      const auto worker = stream->worker;
      {
        std::lock_guard<std::mutex> lock(worker->command_mutex);
        SortformerCommand command{.operation = SortformerOperation::Drain,
                                  .stream = stream};
        worker->Execute(command);
        worker->leased_slots[stream->slot] = false;
      }
      delete stream;
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore Sortformer shutdown failed; lease retained.\n",
               stderr);
  }
}

void omni_sortformer_result_free(OmniSortformerResult *result) {
  if (result != nullptr) {
    std::free(result->probabilities);
    std::free(result->segments);
    *result = {};
  } else {
  }
}
