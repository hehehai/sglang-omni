// SPDX-License-Identifier: Apache-2.0
#include "native_speaker_state.h"

#include <cstdlib>
#include <cstring>
#include <new>

namespace omni_native {
namespace {

char *CopyString(const std::string &text) {
  auto *copy = static_cast<char *>(std::malloc(text.size() + 1));
  if (copy == nullptr) {
    throw std::bad_alloc();
  } else {
    std::memcpy(copy, text.c_str(), text.size() + 1);
    return copy;
  }
}

char *CopyString(const std::optional<std::string> &text) {
  return text ? CopyString(*text) : nullptr;
}

} // namespace

void SpeakerCopyEvent(const SpeakerQueuedEvent &source, uint64_t session_id,
                      OmniSpeakerRealtimeEvent &event) {
  event.session_id = session_id;
  event.event_sequence = source.sequence;
  event.kind = source.kind;
  event.failure_status = source.failure_status;
  const std::vector<qwen3_asr::SpeakerSegment> *segments = nullptr;
  if (const auto *segment =
          std::get_if<qwen3_asr::SpeakerRealtimeSegment>(&source.source)) {
    event.segment_id = segment->segment_id;
    event.is_final = segment->is_final;
    event.text = CopyString(segment->text);
    event.has_segments = segment->segments.has_value();
    segments = segment->segments ? &*segment->segments : nullptr;
  } else if (const auto *completed =
                 std::get_if<qwen3_asr::SpeakerRealtimeCompleted>(
                     &source.source)) {
    event.is_final = 1;
    event.has_segments = 1;
    event.text = CopyString(completed->text);
    segments = &completed->segments;
  } else {
  }
  if (segments == nullptr || segments->empty()) {
    return;
  } else {
    event.segments = static_cast<OmniBatchSegment *>(
        std::calloc(segments->size(), sizeof(OmniBatchSegment)));
    if (event.segments == nullptr) {
      throw std::bad_alloc();
    } else {
      event.segment_count = segments->size();
    }
  }
  for (size_t i = 0; i < segments->size(); ++i) {
    const auto &segment = (*segments)[i];
    auto &copy = event.segments[i];
    copy.start_seconds = segment.start_seconds;
    copy.end_seconds = segment.end_seconds;
    copy.text = CopyString(segment.text);
    copy.speaker = CopyString(segment.speaker);
    copy.language = CopyString(segment.language);
    copy.emotion = CopyString(segment.emotion);
    copy.event = CopyString(segment.event);
  }
}

} // namespace omni_native

void OmniSpeakerRealtime::FailLocked(OmniBatchStatus failure) {
  cancel->store(true);
  if (has_terminal) {
    return;
  } else {
    status.store(failure);
    auto &event = events[(queue_head + queue_count) % events.size()];
    event = {};
    event.sequence = next_event_sequence++;
    event.kind = failure == OMNI_BATCH_CANCELLED ? OMNI_SPEAKER_CANCELLED
                                                 : OMNI_SPEAKER_FAILED;
    event.failure_status = failure;
    ++queue_count;
    has_terminal = true;
  }
}

void OmniSpeakerRealtime::Fail(OmniBatchStatus failure) noexcept {
  try {
    std::lock_guard lock(event_mutex);
    FailLocked(failure);
  } catch (...) {
    status.store(failure);
    cancel->store(true);
  }
}

void OmniSpeakerRealtime::Receive(
    const qwen3_asr::SpeakerRealtimeEvent &event) noexcept {
  try {
    std::lock_guard lock(event_mutex);
    if (has_terminal || cancel->load()) {
      return;
    } else if (std::holds_alternative<qwen3_asr::SpeakerRealtimeFailure>(
                   event)) {
      FailLocked(OMNI_BATCH_FAILED);
      return;
    } else {
    }
    const bool terminal =
        std::holds_alternative<qwen3_asr::SpeakerRealtimeCompleted>(event);
    size_t string_bytes = 0;
    if (omni_native::SpeakerEventBytes(event, string_bytes) != OMNI_BATCH_OK ||
        queue_count >= events.size() - (terminal ? 0 : 1) ||
        string_bytes >
            OMNI_SPEAKER_MAX_QUEUE_STRING_BYTES - queued_string_bytes) {
      FailLocked(OMNI_BATCH_LIMIT);
    } else {
      try {
        omni_native::SpeakerQueuedEvent copy;
        copy.source = event;
        copy.string_bytes = string_bytes;
        copy.kind =
            terminal ? OMNI_SPEAKER_COMPLETED
            : std::holds_alternative<qwen3_asr::SpeakerRealtimeSegment>(event)
                ? OMNI_SPEAKER_SEGMENT
                : OMNI_SPEAKER_UPDATED;
        copy.sequence = next_event_sequence;
        events[(queue_head + queue_count) % events.size()] = std::move(copy);
        ++next_event_sequence;
        ++queue_count;
        queued_string_bytes += string_bytes;
        has_terminal = terminal;
      } catch (...) {
        FailLocked(omni_native::SpeakerExceptionStatus());
      }
    }
  } catch (...) {
    // Note (OpenAI): even a mutex failure cannot escape a worker completion.
    status.store(omni_native::SpeakerExceptionStatus());
    cancel->store(true);
  }
}

int omni_speaker_realtime_poll(OmniSpeakerRealtime *stream,
                               OmniSpeakerRealtimeEvent *event) {
  if (event == nullptr) {
    return -1;
  } else {
    *event = {};
  }
  if (stream == nullptr) {
    event->failure_status = OMNI_BATCH_INVALID;
    return -1;
  } else {
  }
  try {
    std::lock_guard lock(stream->event_mutex);
    if (stream->queue_count == 0) {
      return 0;
    } else {
      auto &source = stream->events[stream->queue_head];
      omni_native::SpeakerCopyEvent(source, stream->session_id, *event);
      stream->queued_string_bytes -= source.string_bytes;
      source = {};
      stream->queue_head = (stream->queue_head + 1) % stream->events.size();
      --stream->queue_count;
      return 1;
    }
  } catch (...) {
    const auto status = omni_native::SpeakerExceptionStatus();
    omni_speaker_realtime_event_free(event);
    event->failure_status = status;
    return -1;
  }
}

void omni_speaker_realtime_event_free(OmniSpeakerRealtimeEvent *event) {
  if (event == nullptr) {
    return;
  } else {
    for (size_t i = 0; i < event->segment_count; ++i) {
      std::free(event->segments[i].text);
      std::free(event->segments[i].speaker);
      std::free(event->segments[i].language);
      std::free(event->segments[i].emotion);
      std::free(event->segments[i].event);
    }
    std::free(event->segments);
    std::free(event->text);
    *event = {};
  }
}
