// SPDX-License-Identifier: Apache-2.0
#ifndef OMNI_NATIVE_SPEAKER_H
#define OMNI_NATIVE_SPEAKER_H

#include "omni_native_batch.h"

#ifdef __cplusplus
extern "C" {
#endif

#define OMNI_SPEAKER_SAMPLE_RATE 16000
#define OMNI_SPEAKER_MAX_CHUNK_SAMPLES 32000
#define OMNI_SPEAKER_MAX_SESSION_SAMPLES 480000
#define OMNI_SPEAKER_MAX_TEXT_BYTES 65536
#define OMNI_SPEAKER_MAX_METADATA_BYTES 128
#define OMNI_SPEAKER_MAX_PROMPT_BYTES 8192
#define OMNI_SPEAKER_MAX_SEGMENTS 512
#define OMNI_SPEAKER_MAX_EVENT_STRING_BYTES 262144
#define OMNI_SPEAKER_MAX_QUEUED_EVENTS 64
#define OMNI_SPEAKER_MAX_QUEUE_STRING_BYTES 4194304

typedef int32_t OmniSpeakerModelKind;
#define OMNI_SPEAKER_MOSS 1
#define OMNI_SPEAKER_NEMOTRON 2

typedef struct OmniSpeakerRealtimeSettings {
  OmniSpeakerModelKind model_kind;
  union {
    struct {
      const char *prompt;
    } moss;
    struct {
      const char *language;
      int32_t has_chunk;
      double chunk_milliseconds;
    } nemotron;
  } family;
} OmniSpeakerRealtimeSettings;

typedef int32_t OmniSpeakerRealtimeEventKind;
#define OMNI_SPEAKER_UPDATED 1
#define OMNI_SPEAKER_SEGMENT 2
#define OMNI_SPEAKER_COMPLETED 3
#define OMNI_SPEAKER_CANCELLED 4
#define OMNI_SPEAKER_FAILED 5

typedef struct OmniSpeakerRealtimeEvent {
  uint64_t session_id;
  uint64_t event_sequence;
  OmniSpeakerRealtimeEventKind kind;
  int32_t segment_id;
  int32_t is_final;
  char *text;
  int32_t has_segments;
  OmniBatchSegment *segments;
  size_t segment_count;
  OmniBatchStatus failure_status;
} OmniSpeakerRealtimeEvent;

typedef struct OmniSpeakerHandle OmniSpeakerHandle;
typedef struct OmniSpeakerRealtime OmniSpeakerRealtime;

// ABI8 opt-in bounded mono16k realtime, not longform. Exceptions contained.
// Inputs borrowed until return; outputs owned, no private exception strings.
// Defaults: NULL prompt/language, has_chunk=0/chunk=0. Kind must match model.
// Present chunk: finite >0..120000 milliseconds; has_chunk strictly 0 or 1.
// UTF8 prompt<=8192 bytes with <=1 audio placeholder; language<=128 bytes.
OMNI_CORE_EXPORT OmniBatchStatus omni_speaker_settings_default(
    OmniSpeakerModelKind kind, OmniSpeakerRealtimeSettings *settings);

// Independent model, not a Batch handle. Existing nonempty directory<=8192
// UTF8 bytes. Model construction, evaluation and destruction share one worker.
// Both create functions clear *out first. Pre-admission failures return NULL.
// IMPORTANT: post-admission failure with unproven cleanup returns NONNULL plus
// failure status. Caller owns that exact handle and MUST retry checked destroy.
OMNI_CORE_EXPORT OmniBatchStatus
omni_speaker_create(OmniSpeakerModelKind kind, const char *model_directory,
                    OmniSpeakerHandle **handle);
// Sticky admission stop; cancels current stream. NOT a worker/GPU drain.
OMNI_CORE_EXPORT void omni_speaker_cancel(OmniSpeakerHandle *handle);
// BUSY while any stream lease exists, including drained streams. On OK frees
// handle; failure retains it for retry. NULL safe. Caller must synchronize raw
// destruction against ALL calls; never drain/destroy from the model worker.
OMNI_CORE_EXPORT OmniBatchStatus
omni_speaker_destroy_checked(OmniSpeakerHandle *handle);

// Nonzero caller-unique session_id. One lease until checked destruction, even
// after finish/drain. Immutable copied settings. BUSY before settings copy.
// A failed create may return a NONNULL owned lease: see creation rule above.
OMNI_CORE_EXPORT OmniBatchStatus omni_speaker_realtime_create(
    OmniSpeakerHandle *handle, uint64_t session_id,
    const OmniSpeakerRealtimeSettings *settings, OmniSpeakerRealtime **stream);
// Command trylock BUSY before audio copy. Finite 1..32000 samples/chunk,
// <=480000 cumulative; strict contiguous nonzero sequence starting at 1.
// Rejection leaves accepted_sequence=0 and does not consume sequence/audio.
// OK acknowledges bounded copy/engine admission, NOT numerical success/drain.
// Backend failure events may arrive before or after the ACK. Never replay.
OMNI_CORE_EXPORT OmniBatchStatus omni_speaker_realtime_push(
    OmniSpeakerRealtime *stream, uint64_t audio_sequence, const float *samples,
    size_t sample_count, uint64_t *accepted_sequence);
// MOSS commit nonterminal; Nemotron commit seals audio. Finish once emits
// completion; further pushes/finishes reject INVALID. Empty finish is allowed.
OMNI_CORE_EXPORT OmniBatchStatus
omni_speaker_realtime_commit(OmniSpeakerRealtime *stream);
OMNI_CORE_EXPORT OmniBatchStatus
omni_speaker_realtime_finish(OmniSpeakerRealtime *stream);

// Poll: 1 snapshot, 0 empty, -1 failure (event.failure_status, including OOM).
// Output zeroed first: free old snapshot before reuse. Copy failure retains
// queue item/sequence for retry. Ring has 64 slots, one reserved for terminal,
// <=4MiB queued string storage. No truncation; invalid/oversize output ->
// LIMIT. Text<=65536, metadata<=128, segments<=512, total strings including
// NULs
// <=262144 per event. Times finite nonnegative ordered seconds; UTF8/no NUL.
// Preview has_segments=0; final/completed has_segments=1 even when empty.
// Updated/error/cancel text absent. Metadata preserves absent vs empty.
OMNI_CORE_EXPORT int
omni_speaker_realtime_poll(OmniSpeakerRealtime *stream,
                           OmniSpeakerRealtimeEvent *event);
// Independent durable cancellation; never releases GPU reader or model lease.
OMNI_CORE_EXPORT void omni_speaker_realtime_cancel(OmniSpeakerRealtime *stream);
// Closes admission, cancels, waits actual jobs/callbacks and explicit worker
// sync/cache cleanup. Engine/stream destruction occurs on the loading thread.
// Failure retains the original lease/handle for retry; success still holds the
// lease until checked destroy. Repeated/NULL safe; cancellation != drain.
// Completion, timeout, or disconnection alone never proves GPU-reader release.
OMNI_CORE_EXPORT OmniBatchStatus
omni_speaker_realtime_drain(OmniSpeakerRealtime *stream);
// Drain then release lease. Failure retains exact raw handle for retry. Caller
// synchronizes raw destruction against ALL calls. NULL is OK.
OMNI_CORE_EXPORT OmniBatchStatus
omni_speaker_realtime_destroy_checked(OmniSpeakerRealtime *stream);
// Frees all owned snapshot strings/segments, zeroes fields; repeated/NULL safe.
OMNI_CORE_EXPORT void
omni_speaker_realtime_event_free(OmniSpeakerRealtimeEvent *event);

#ifdef __cplusplus
}
#endif
#endif
