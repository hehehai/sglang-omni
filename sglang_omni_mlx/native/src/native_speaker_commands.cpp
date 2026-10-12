// SPDX-License-Identifier: Apache-2.0
#include "native_speaker_state.h"

#include <cmath>
#include <limits>
#include <utility>
#include <vector>

OmniBatchStatus omni_speaker_realtime_push(OmniSpeakerRealtime *stream,
                                           uint64_t audio_sequence,
                                           const float *samples,
                                           size_t sample_count,
                                           uint64_t *accepted_sequence) {
  if (accepted_sequence == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
    *accepted_sequence = 0;
  }
  if (stream == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
  }
  try {
    std::unique_lock lock(stream->command_mutex, std::try_to_lock);
    if (!lock.owns_lock()) {
      return OMNI_BATCH_BUSY;
    } else if (stream->status.load() != OMNI_BATCH_OK) {
      return stream->status.load();
    } else if (stream->cancel->load()) {
      return OMNI_BATCH_CANCELLED;
    } else if (stream->is_drained || stream->is_finished ||
               stream->is_committed || samples == nullptr ||
               sample_count == 0 || audio_sequence == 0 ||
               stream->audio_sequence == std::numeric_limits<uint64_t>::max() ||
               audio_sequence != stream->audio_sequence + 1) {
      return OMNI_BATCH_INVALID;
    } else if (sample_count > OMNI_SPEAKER_MAX_CHUNK_SAMPLES ||
               sample_count > OMNI_SPEAKER_MAX_SESSION_SAMPLES -
                                  stream->admitted_samples) {
      return OMNI_BATCH_LIMIT;
    } else {
    }
    for (size_t i = 0; i < sample_count; ++i) {
      if (!std::isfinite(samples[i])) {
        return OMNI_BATCH_INVALID;
      } else {
      }
    }
    std::vector<float> copied_samples(samples, samples + sample_count);
    if (stream->cancel->load()) {
      return OMNI_BATCH_CANCELLED;
    } else if (stream->moss_engine) {
      stream->moss_engine->Append(std::move(copied_samples));
    } else {
      stream->nemotron_engine->Append(std::move(copied_samples));
    }
    stream->admitted_samples += sample_count;
    stream->audio_sequence = audio_sequence;
    *accepted_sequence = audio_sequence;
    return OMNI_BATCH_OK;
  } catch (...) {
    const auto status = omni_native::SpeakerExceptionStatus();
    stream->Fail(status);
    return status;
  }
}

OmniBatchStatus omni_speaker_realtime_commit(OmniSpeakerRealtime *stream) {
  if (stream == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
  }
  try {
    std::unique_lock lock(stream->command_mutex, std::try_to_lock);
    if (!lock.owns_lock()) {
      return OMNI_BATCH_BUSY;
    } else if (stream->status.load() != OMNI_BATCH_OK) {
      return stream->status.load();
    } else if (stream->cancel->load()) {
      return OMNI_BATCH_CANCELLED;
    } else if (stream->is_drained || stream->is_finished ||
               stream->is_committed) {
      return OMNI_BATCH_INVALID;
    } else if (stream->moss_engine) {
      stream->moss_engine->Commit();
    } else {
      stream->is_committed = true;
      stream->nemotron_engine->Commit();
    }
    return stream->status.load();
  } catch (...) {
    const auto status = omni_native::SpeakerExceptionStatus();
    stream->Fail(status);
    return status;
  }
}

OmniBatchStatus omni_speaker_realtime_finish(OmniSpeakerRealtime *stream) {
  if (stream == nullptr) {
    return OMNI_BATCH_INVALID;
  } else {
  }
  try {
    std::unique_lock lock(stream->command_mutex, std::try_to_lock);
    if (!lock.owns_lock()) {
      return OMNI_BATCH_BUSY;
    } else if (stream->status.load() != OMNI_BATCH_OK) {
      return stream->status.load();
    } else if (stream->cancel->load()) {
      return OMNI_BATCH_CANCELLED;
    } else if (stream->is_drained || stream->is_finished) {
      return OMNI_BATCH_INVALID;
    } else {
      stream->is_finished = true;
      if (stream->moss_engine) {
        stream->moss_engine->Finish();
      } else {
        stream->nemotron_engine->Finish();
      }
      return stream->status.load();
    }
  } catch (...) {
    const auto status = omni_native::SpeakerExceptionStatus();
    stream->Fail(status);
    return status;
  }
}
