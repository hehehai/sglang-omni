// SPDX-License-Identifier: Apache-2.0
#include "native_silero_worker.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>

using omni_native::ClearSileroError;
using omni_native::SetError;
using omni_native::SileroCommand;
using omni_native::SileroOperation;
using omni_native::SileroPhase;

namespace {

struct SileroAdmission {
  OmniSileroStream &stream;
  bool is_successful = false;

  ~SileroAdmission() {
    // Note (OpenAI): terminalize failures before releasing command
    // serialization.
    if (!is_successful && stream.IsActive()) {
      stream.SetTerminal(SileroPhase::Failed);
    } else {
    }
  }
};

std::unique_ptr<float, decltype(&std::free)>
CopySileroProbabilities(const SileroCommand &command) {
  std::unique_ptr<float, decltype(&std::free)> probabilities(nullptr,
                                                             &std::free);
  if (!command.probabilities.empty()) {
    const size_t byte_count = command.probabilities.size() * sizeof(float);
    probabilities.reset(static_cast<float *>(std::malloc(byte_count)));
    if (!probabilities) {
      throw std::bad_alloc();
    } else {
      std::memcpy(probabilities.get(), command.probabilities.data(),
                  byte_count);
    }
  } else {
  }
  return probabilities;
}

} // namespace

OmniSileroStream *omni_silero_stream_create(OmniSileroHandle *handle,
                                            char **error_message) {
  ClearSileroError(error_message);
  try {
    if (handle == nullptr) {
      SetError(error_message, "Invalid Silero model.");
      return nullptr;
    } else {
    }
    const auto worker = handle->worker;
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    const auto slot = std::find(worker->leased_slots.begin(),
                                worker->leased_slots.end(), false);
    if (worker->is_cancelled.load()) {
      SetError(error_message, "Silero operation cancelled.");
      return nullptr;
    } else if (slot == worker->leased_slots.end()) {
      SetError(error_message, "Silero stream limit exceeded.");
      return nullptr;
    } else {
    }
    auto stream = std::make_unique<OmniSileroStream>();
    stream->worker = worker;
    stream->slot = static_cast<size_t>(slot - worker->leased_slots.begin());
    SileroCommand command{.operation = SileroOperation::Create,
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
    SetError(error_message, "Silero stream initialization failed.");
    return nullptr;
  }
}

int omni_silero_stream_push(OmniSileroStream *stream, uint64_t audio_sequence,
                            const float *samples, size_t sample_count,
                            uint64_t *accepted_audio_sequence,
                            OmniSileroStreamResult *result,
                            char **error_message) {
  ClearSileroError(error_message);
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
        !omni_native::ValidSileroSamples(samples, sample_count,
                                         OMNI_SILERO_MAX_CHUNK_SAMPLES)) {
      SetError(error_message, "Invalid Silero stream input.");
      return 0;
    } else {
    }
    const auto worker = stream->worker;
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    const size_t processed_samples =
        (stream->pending_sample_count + sample_count) /
        OMNI_SILERO_FRAME_SAMPLES * OMNI_SILERO_FRAME_SAMPLES;
    if (!stream->IsActive()) {
      SetError(error_message, "Silero stream is terminal.");
      return 0;
    } else if (stream->accepted_audio_sequence ==
                   std::numeric_limits<uint64_t>::max() ||
               audio_sequence != stream->accepted_audio_sequence + 1) {
      SetError(error_message, "Invalid audio sequence.");
      return 0;
    } else if (processed_samples > std::numeric_limits<uint64_t>::max() -
                                       stream->processed_sample_count) {
      SetError(error_message, "Silero sample counter overflow.");
      return 0;
    } else {
    }
    SileroCommand command{.operation = SileroOperation::Push, .stream = stream};
    command.audio_samples.assign(samples, samples + sample_count);
    worker->CheckCancelled(command);
    SileroAdmission admission{*stream};
    stream->accepted_audio_sequence = audio_sequence;
    worker->Execute(command);
    if (command.error != nullptr) {
      SetError(error_message, command.error);
      return 0;
    } else {
    }
    auto probabilities = CopySileroProbabilities(command);
    worker->CheckCancelled(command);
    *result = {probabilities.release(), command.probabilities.size(),
               stream->processed_sample_count};
    *accepted_audio_sequence = audio_sequence;
    admission.is_successful = true;
    return 1;
  } catch (const omni_native::SileroCancelled &) {
    stream->SetTerminal(SileroPhase::Cancelled);
    SetError(error_message, "Silero operation cancelled.");
    return 0;
  } catch (...) {
    SetError(error_message, "Silero stream processing failed.");
    return 0;
  }
}

int omni_silero_stream_finish(OmniSileroStream *stream,
                              OmniSileroStreamResult *result,
                              char **error_message) {
  ClearSileroError(error_message);
  if (result != nullptr) {
    *result = {};
  } else {
  }
  try {
    if (stream == nullptr || result == nullptr) {
      SetError(error_message, "Invalid Silero stream input.");
      return 0;
    } else {
    }
    const auto worker = stream->worker;
    std::lock_guard<std::mutex> lock(worker->command_mutex);
    if (stream->phase.load() == SileroPhase::Completed) {
      result->processed_sample_count = stream->processed_sample_count;
      return 1;
    } else if (!stream->IsActive()) {
      SetError(error_message, "Silero stream is terminal.");
      return 0;
    } else if (stream->pending_sample_count != 0 &&
               stream->processed_sample_count >
                   std::numeric_limits<uint64_t>::max() -
                       OMNI_SILERO_FRAME_SAMPLES) {
      SetError(error_message, "Silero sample counter overflow.");
      return 0;
    } else {
    }
    SileroCommand command{.operation = SileroOperation::Finish,
                          .stream = stream};
    SileroAdmission admission{*stream};
    worker->Execute(command);
    if (command.error != nullptr) {
      SetError(error_message, command.error);
      return 0;
    } else {
    }
    auto probabilities = CopySileroProbabilities(command);
    worker->CheckCancelled(command);
    auto expected = SileroPhase::Active;
    if (!stream->phase.compare_exchange_strong(expected,
                                               SileroPhase::Completed)) {
      throw omni_native::SileroCancelled{};
    } else {
      *result = {probabilities.release(), command.probabilities.size(),
                 stream->processed_sample_count};
      admission.is_successful = true;
      return 1;
    }
  } catch (const omni_native::SileroCancelled &) {
    stream->SetTerminal(SileroPhase::Cancelled);
    SetError(error_message, "Silero operation cancelled.");
    return 0;
  } catch (...) {
    SetError(error_message, "Silero stream finalization failed.");
    return 0;
  }
}

void omni_silero_stream_cancel(OmniSileroStream *stream) {
  if (stream != nullptr) {
    stream->SetTerminal(SileroPhase::Cancelled);
  } else {
  }
}

int omni_silero_stream_drain(OmniSileroStream *stream, char **error_message) {
  ClearSileroError(error_message);
  try {
    if (stream == nullptr) {
      SetError(error_message, "Invalid Silero stream input.");
      return 0;
    } else if (stream->IsActive()) {
      SetError(error_message, "Silero stream is not terminal.");
      return 0;
    } else {
      const auto worker = stream->worker;
      std::lock_guard<std::mutex> lock(worker->command_mutex);
      SileroCommand command{.operation = SileroOperation::Drain,
                            .stream = stream};
      worker->Execute(command);
      return 1;
    }
  } catch (...) {
    SetError(error_message, "Silero stream drain failed.");
    return 0;
  }
}

void omni_silero_stream_destroy(OmniSileroStream *stream) {
  try {
    if (stream != nullptr) {
      stream->SetTerminal(SileroPhase::Cancelled);
      const auto worker = stream->worker;
      {
        std::lock_guard<std::mutex> lock(worker->command_mutex);
        SileroCommand command{.operation = SileroOperation::Drain,
                              .stream = stream};
        worker->Execute(command);
        worker->leased_slots[stream->slot] = false;
      }
      delete stream;
    } else {
    }
  } catch (...) {
    std::fputs("OmniCore Silero shutdown failed; lease retained.\n", stderr);
  }
}

void omni_silero_stream_result_free(OmniSileroStreamResult *result) {
  if (result != nullptr) {
    std::free(result->probabilities);
    *result = {};
  } else {
  }
}
