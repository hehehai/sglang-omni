// SPDX-License-Identifier: Apache-2.0
#ifndef OMNI_NATIVE_CORE_H
#define OMNI_NATIVE_CORE_H

#include <stddef.h>
#include <stdint.h>

#include "omni_native_batch.h"
#include "omni_native_speaker.h"

#ifndef OMNI_CORE_EXPORT
#if defined(__GNUC__) || defined(__clang__)
#define OMNI_CORE_EXPORT __attribute__((visibility("default")))
#else
#define OMNI_CORE_EXPORT
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OmniQwenHandle OmniQwenHandle;
typedef struct OmniQwenRequest OmniQwenRequest;
typedef struct OmniQwenResult {
  char *text;
  char *language;
  int generated_token_count;
  int hit_length_limit;
} OmniQwenResult;

OMNI_CORE_EXPORT unsigned int omni_core_abi_version(void);

// Synchronous load of an existing model directory; NULL on failure.
// Optional error output is cleared first. Release errors with omni_string_free.
OMNI_CORE_EXPORT OmniQwenHandle *omni_qwen_create(const char *model_directory,
                                                  char **error_message);

// Mono 16 kHz Float32: 1..480000 finite samples; token budget: 1..4096.
// NULL/blank language selects detection; NULL context means no prompt.
// Returns 1 on success, 0 on error. Outputs are cleared before use.
// Free a previous result/error before reusing its output storage. Successful
// text is owned even when empty; language is NULL when not detected.
// Release results with omni_qwen_result_free and errors with omni_string_free.
// Error storage is optional; allocation failure may leave the message NULL.
// Inputs must remain valid for the call. Requests on one handle are serialized.
OMNI_CORE_EXPORT int
omni_qwen_transcribe(OmniQwenHandle *handle, const float *samples,
                     size_t sample_count, const char *language,
                     const char *context, int maximum_token_count,
                     OmniQwenResult *result, char **error_message);

// ABI v2: independent, single-use cancellation token; NULL on allocation
// failure. Tokens are not bound to a model until transcription is attempted.
OMNI_CORE_EXPORT OmniQwenRequest *omni_qwen_request_create(void);

// Durable even before submission; never cancels the model or another token.
// Repeated calls and NULL are safe. Cancellation is cooperative, not a rollback
// of a result already completed by the worker.
OMNI_CORE_EXPORT void omni_qwen_request_cancel(OmniQwenRequest *request);

// Cancels and releases the token without joining the model worker. An already-
// submitted transcription is safe: the worker retains cancellation ownership.
// Callers must prevent new token calls once destruction begins and synchronize
// with other token calls or transcriptions not yet submitted. Destroy exactly
// once; NULL is safe. Only live tokens returned by create may be used.
OMNI_CORE_EXPORT void omni_qwen_request_destroy(OmniQwenRequest *request);

// Same input/output ownership and limits as omni_qwen_transcribe. A non-NULL
// token is required and consumed by the first attempt, even on invalid input,
// cancellation, or failure. Concurrent/repeated use fails without cancelling
// the first attempt. Fresh tokens reuse the loaded model without another load.
// Model-wide cancellation remains sticky and applies to both transcription
// APIs.
OMNI_CORE_EXPORT int omni_qwen_transcribe_request(
    OmniQwenHandle *handle, OmniQwenRequest *request, const float *samples,
    size_t sample_count, const char *language, const char *context,
    int maximum_token_count, OmniQwenResult *result, char **error_message);

// Cancels queued/running requests and prevents later submissions on this
// handle. Create a new handle after cancellation; repeated calls and NULL are
// safe. ABI3 also cancels all live realtime sessions; this is not a worker
// drain.
OMNI_CORE_EXPORT void omni_qwen_cancel(OmniQwenHandle *handle);

// Cancels and joins the worker before releasing its model. May overlap requests
// already submitted, but callers must prevent new calls (including cancel) once
// destruction begins. Synchronize realtime creation with model destruction.
// Destroy exactly once; NULL is safe.
// ABI3: live realtime leases are cancelled and drained first; they may retain
// the model/worker until the last realtime handle is destroyed.
OMNI_CORE_EXPORT void omni_qwen_destroy(OmniQwenHandle *handle);

// Frees owned strings and zeroes the result; repeated calls and NULL are safe.
OMNI_CORE_EXPORT void omni_qwen_result_free(OmniQwenResult *result);
OMNI_CORE_EXPORT void omni_string_free(char *string);

// ABI3 only. No borrowed output strings or callbacks cross this boundary.
// Optional error outputs are cleared first; free previous errors before reuse.
// Release errors with omni_string_free; allocation failure may leave them NULL.
typedef struct OmniQwenRealtime OmniQwenRealtime;
#define OMNI_QWEN_REALTIME_MAX_CHUNK_SAMPLES 32000
#define OMNI_QWEN_REALTIME_MAX_SESSION_SAMPLES 480000
#define OMNI_QWEN_REALTIME_MAX_QUEUED_EVENTS 64
#define OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES 65536
#define OMNI_QWEN_REALTIME_MAX_FINAL_SEGMENTS 512
#define OMNI_QWEN_REALTIME_MAX_TRANSCRIPT_BYTES 65536
#define OMNI_QWEN_REALTIME_MAX_QUEUED_STRING_BYTES 4194304
#define OMNI_QWEN_REALTIME_MAX_LANGUAGE_BYTES 128
#define OMNI_QWEN_REALTIME_MAX_CONTEXT_BYTES 8192
#define OMNI_QWEN_REALTIME_MAX_TOKEN_COUNT 4096

typedef struct OmniQwenRealtimeSettings {
  int32_t decode_interval_samples;
  int32_t first_decode_samples;
  int32_t maximum_segment_samples;
  int32_t maximum_token_count;
} OmniQwenRealtimeSettings;

// Fixed-width storage, independent of compiler enum sizing flags.
typedef int32_t OmniQwenRealtimeEventKind;
#define OMNI_QWEN_REALTIME_UPDATED 1
#define OMNI_QWEN_REALTIME_SEGMENT 2
#define OMNI_QWEN_REALTIME_COMPLETED 3
#define OMNI_QWEN_REALTIME_CANCELLED 4
#define OMNI_QWEN_REALTIME_FAILED 5

typedef struct OmniQwenRealtimeEvent {
  uint64_t session_id;
  uint64_t event_sequence;
  OmniQwenRealtimeEventKind kind;
  int32_t segment_id;
  int32_t is_final;
  char *text;
  char *error_message;
} OmniQwenRealtimeEvent;

// Nonzero caller identity; settings required, all sample intervals 1..480000,
// token count 1..4096. NULL/blank language detects; NULL context has no prompt.
// Strings are bounded UTF-8 C strings; byte limits exclude their terminator.
// Final-segment count and committed transcript bytes are bounded even when
// the consumer continuously polls. Transcript budget includes a potential
// joining separator between nonempty segments.
// Native decodes use kVoxtSwift layout, EOS/loop stopping and these base
// options. One existing model is leased; no model is loaded by session
// creation.
OMNI_CORE_EXPORT OmniQwenRealtime *
omni_qwen_realtime_create(OmniQwenHandle *handle, uint64_t session_id,
                          const OmniQwenRealtimeSettings *settings,
                          const char *language, const char *context,
                          char **error_message);

// Mono 16kHz finite samples. Sequence starts at 1 and advances only on
// admission. ACK is cleared first and required. Returns 1 for admission, even
// if processing then fails/cancels (poll the terminal); 0 rejects without
// consuming sequence. Input/queue backpressure never silently drops audio.
// Retry rejected sequences.
OMNI_CORE_EXPORT int omni_qwen_realtime_push(OmniQwenRealtime *session,
                                             uint64_t audio_sequence,
                                             const float *samples,
                                             size_t sample_count,
                                             uint64_t *accepted_audio_sequence,
                                             char **error_message);
// Returns 1 completed/already completed, 0 cancelled/failed/invalid.
// Exactly one terminal is latched; success never overwrites
// failure/cancellation.
OMNI_CORE_EXPORT int omni_qwen_realtime_finish(OmniQwenRealtime *session,
                                               char **error_message);

// Returns 1 event, 0 empty, -1 error; never waits for an event. Outputs cleared
// first: free previous outputs before reuse. Segment/completed text is owned,
// even when empty; only FAILED owns error_message (sanitized). Other strings
// are NULL. Event sequences start at 1, without coalescing or gaps. At most 63
// nonterminals plus one reserved terminal; overflow fails/cancels the engine.
// Allocation failure preserves the queued event for a later poll. The aggregate
// queued string limit includes NUL terminators; each-string limits exclude NUL.
OMNI_CORE_EXPORT int omni_qwen_realtime_poll(OmniQwenRealtime *session,
                                             OmniQwenRealtimeEvent *event,
                                             char **error_message);

// Durable and idempotent; bypasses command serialization, never cancels model.
// Cancellation acknowledgement is not a worker drain. NULL is safe.
OMNI_CORE_EXPORT void omni_qwen_realtime_cancel(OmniQwenRealtime *session);
// Terminal required (need not be polled). Waits commands/callbacks/worker
// barriers; returns 1 drained, 0 error. Never call on a model worker/event sink
// thread.
OMNI_CORE_EXPORT int omni_qwen_realtime_drain(OmniQwenRealtime *session,
                                              char **error_message);
// Cancel + drain before releasing the lease. Callers synchronize raw handle
// destruction against all other calls; destroy once, NULL safe. Push/finish/
// drain serialize internally; cancel/poll may overlap them. A retained session
// after model destroy remains pollable but cannot accept more audio.
OMNI_CORE_EXPORT void omni_qwen_realtime_destroy(OmniQwenRealtime *session);
// Frees owned strings and clears every field; repeated calls and NULL are safe.
OMNI_CORE_EXPORT void
omni_qwen_realtime_event_free(OmniQwenRealtimeEvent *event);

// ABI4: bounded Silero VAD, mono 16 kHz Float32. No callbacks or borrowed
// outputs. All calls contain exceptions; errors are sanitized, optional, and
// cleared first. Free old results/errors before reuse (omni_string_free).
#define OMNI_SILERO_SAMPLE_RATE 16000
#define OMNI_SILERO_FRAME_SAMPLES 512
#define OMNI_SILERO_MAX_OFFLINE_SAMPLES 480000
#define OMNI_SILERO_MAX_CHUNK_SAMPLES 32000
#define OMNI_SILERO_MAX_STREAMS 16
#define OMNI_SILERO_MAX_OPTION_MILLISECONDS 30000

typedef struct OmniSileroHandle OmniSileroHandle;
typedef struct OmniSileroRequest OmniSileroRequest;
typedef struct OmniSileroStream OmniSileroStream;
typedef struct OmniSileroSettings {
  float threshold;
  int32_t minimum_speech_milliseconds;
  int32_t minimum_silence_milliseconds;
  int32_t speech_padding_milliseconds;
} OmniSileroSettings;
typedef struct OmniSileroTimestamp {
  int64_t start_sample;
  int64_t end_sample;
} OmniSileroTimestamp;
typedef struct OmniSileroResult {
  OmniSileroTimestamp *timestamps;
  size_t timestamp_count;
} OmniSileroResult;
typedef struct OmniSileroStreamResult {
  float *probabilities;
  size_t probability_count;
  uint64_t processed_sample_count;
} OmniSileroStreamResult;

// Synchronous, nonpreemptible config/weights load; NULL on failure. A dedicated
// persistent worker owns the model and all native MLX stream states, including
// their destruction. All inference is serialized; at most one command and its
// bounded audio copy are queued/running per model. Call inputs stay valid until
// return. Cancellation checks surround each 512-sample Feed, not GPU execution.
OMNI_CORE_EXPORT OmniSileroHandle *
omni_silero_create(const char *model_directory, char **error_message);
// Sticky stop-admission/cancellation of offline and live stream work, not
// drain. Repeated calls and NULL are safe; completed streams remain completed.
OMNI_CORE_EXPORT void omni_silero_cancel(OmniSileroHandle *handle);
// Cancel + drain. May overlap submitted operations; callers prevent new raw
// model calls and synchronize stream creation with model destroy.
// Live stream leases retain the worker/model until destroyed; never free early.
// Destroy exactly once; NULL safe. Never call from the model worker.
OMNI_CORE_EXPORT void omni_silero_destroy(OmniSileroHandle *handle);

// Required single-use token; NULL on allocation failure. Consumed on the first
// timestamp attempt, including invalid input/failure/cancellation. Cancellation
// is durable before submission and independent of other requests/the model.
OMNI_CORE_EXPORT OmniSileroRequest *omni_silero_request_create(void);
OMNI_CORE_EXPORT void omni_silero_request_cancel(OmniSileroRequest *request);
// Cancel without draining; submitted work retains cancellation ownership.
// Synchronize raw token calls/destruction and prevent new calls after destroy.
// Both token cancel/destroy are NULL safe; repeated cancel is safe.
OMNI_CORE_EXPORT void omni_silero_request_destroy(OmniSileroRequest *request);
// Returns 1/0 success/error. Settings/result required; result cleared first.
// Finite threshold 0..1; all millisecond options 0..30000. Finite samples,
// count 1..480000. Final partial frame is zero-padded; timestamps use real
// sample positions bounded by input length. A fresh token reuses the model.
OMNI_CORE_EXPORT int omni_silero_speech_timestamps(
    OmniSileroHandle *handle, OmniSileroRequest *request, const float *samples,
    size_t sample_count, const OmniSileroSettings *settings,
    OmniSileroResult *result, char **error_message);
OMNI_CORE_EXPORT void omni_silero_result_free(OmniSileroResult *result);

// Independent stream state, no model load. At most 16 live leases, including
// terminal/drained leases until destroyed. No session-total audio duration cap.
OMNI_CORE_EXPORT OmniSileroStream *
omni_silero_stream_create(OmniSileroHandle *handle, char **error_message);
// Synchronous; returns 1/0 success/error. Sequence starts at 1. ACK and result
// required, cleared first. Finite samples, count 1..32000. Invalid input,
// sequence/bounds or pre-admission copy allocation failure leaves
// state/sequence unchanged (retry allowed). Success ACK consumes sequence.
// After admission, inference/output allocation failure or cancellation is
// terminal: ACK may be zero but NEVER replay. Returned probabilities are finite
// 0..1, at most ceil(chunk sample count / 512), with fewer than 512 pending
// samples retained. processed_sample_count counts inferred whole frames in
// samples (multiples of 512), not received audio. Counter/sequence overflow
// rejects admission.
OMNI_CORE_EXPORT int
omni_silero_stream_push(OmniSileroStream *stream, uint64_t audio_sequence,
                        const float *samples, size_t sample_count,
                        uint64_t *accepted_audio_sequence,
                        OmniSileroStreamResult *result, char **error_message);
// Pads pending samples; returns 0/1 probabilities and final processed count.
// Completed state is immutable: repeated finish succeeds with empty output and
// the same count; push rejects. Cancelled/failed finish returns 0.
OMNI_CORE_EXPORT int omni_silero_stream_finish(OmniSileroStream *stream,
                                               OmniSileroStreamResult *result,
                                               char **error_message);
// Idempotent independent cancellation bypasses command serialization; no drain.
OMNI_CORE_EXPORT void omni_silero_stream_cancel(OmniSileroStream *stream);
// Requires completed/cancelled/failed; waits for commands and clears native MLX
// state on the worker. Returns 1/0 drained/error. Never call from that worker.
OMNI_CORE_EXPORT int omni_silero_stream_drain(OmniSileroStream *stream,
                                              char **error_message);
// Cancel + drain + release lease. Synchronize raw stream destruction against
// all stream calls. Push/finish/drain serialize; cancel can overlap them.
// A live lease after model destroy remains drainable, never accepts more audio.
OMNI_CORE_EXPORT void omni_silero_stream_destroy(OmniSileroStream *stream);
// Owned arrays only for nonempty successes. Both result free functions clear
// all fields, are repeated/NULL safe; stream cancel/destroy are NULL safe too.
OMNI_CORE_EXPORT void
omni_silero_stream_result_free(OmniSileroStreamResult *result);

// ABI5: Sortformer streaming, explicit settings; no HTTP policy defaults.
#define OMNI_SORTFORMER_SAMPLE_RATE 16000
#define OMNI_SORTFORMER_MAX_CHUNK_SAMPLES 32000
#define OMNI_SORTFORMER_MAX_STREAMS 16
#define OMNI_SORTFORMER_MAX_STATE_FRAMES 4096
#define OMNI_SORTFORMER_MAX_CHUNK_FRAMES 26
#define OMNI_SORTFORMER_MAX_SPEAKERS 4
#define OMNI_SORTFORMER_MAX_SEGMENTS 104

typedef struct OmniSortformerHandle OmniSortformerHandle;
typedef struct OmniSortformerStream OmniSortformerStream;
typedef struct OmniSortformerSettings {
  float threshold;
  float minimum_duration_seconds;
  float merge_gap_seconds;
  int32_t speaker_cache_max_frames;
  int32_t fifo_max_frames;
} OmniSortformerSettings;
typedef struct OmniSortformerSegment {
  double start_seconds;
  double end_seconds;
  int32_t speaker_index;
} OmniSortformerSegment;
typedef struct OmniSortformerResult {
  float *probabilities;
  size_t probability_count;
  int32_t frame_count;
  int32_t speaker_count;
  double frame_duration_seconds;
  OmniSortformerSegment *segments;
  size_t segment_count;
  uint64_t processed_frame_count;
} OmniSortformerResult;

// Synchronous nonpreemptible load on a dedicated persistent worker. Initially
// supports only four-speaker AOSC checkpoints with 16kHz/hop160/subsampling8
// and validated architecture/config bounds. NULL on failure. All MLX model and
// stream arrays are created/released on that worker. No exceptions cross C;
// optional sanitized errors are cleared first and freed with omni_string_free.
OMNI_CORE_EXPORT OmniSortformerHandle *
omni_sortformer_create(const char *model_directory, char **error_message);
// Sticky model-wide cancellation stops admission, not a worker drain.
OMNI_CORE_EXPORT void omni_sortformer_cancel(OmniSortformerHandle *handle);
// Cancel + drain, retaining the worker/model while any stream lease lives.
// Synchronize stream creation/raw model calls against destroy, preventing new
// calls once destruction begins. Submitted stream work may overlap destroy.
OMNI_CORE_EXPORT void omni_sortformer_destroy(OmniSortformerHandle *handle);
// Returns 1 after destruction; on 0 the handle remains owned and retryable.
// Checked model destruction requires all stream handles to be destroyed first.
OMNI_CORE_EXPORT int
omni_sortformer_destroy_checked(OmniSortformerHandle *handle,
                                char **error_message);

// Required settings: finite threshold 0..1, durations 0..3600 seconds, cache
// 1..4096 and FIFO 0..4096, also constrained by the model's encoder positions
// and compression bounds: (cache_max + 1 + silence_frames_per_speaker)*4
// must fill the model's fixed cache length, and max_index must remain outside
// flattened candidate indices. At most 16 live leases, including drained
// streams.
OMNI_CORE_EXPORT OmniSortformerStream *
omni_sortformer_stream_create(OmniSortformerHandle *handle,
                              const OmniSortformerSettings *settings,
                              char **error_message);
// Synchronous 1/0 success/error, sequence starts at 1, strictly consecutive.
// Finite mono samples, count 1..32000, additionally <= update_period*1280-1;
// exceeding a model-specific cap is a pre-admission error. Inputs stay valid
// until return. ACK/result required, cleared first; free old outputs first.
// One command/copy per model, gate BEFORE copy. Invalid input/sequence/bounds
// or pre-admission copy failure consumes no sequence. Post-admission inference
// or output allocation failure is terminal: NEVER replay even with ACK zero.
// Cancellation is cooperative before/after Feed, not GPU preemption. Native
// int frame-counter overflow rejects BEFORE Feed. No audio/output history.
// Owned row-major probabilities are finite 0..1, at most 26x4 per feed;
// segments use absolute stream seconds converted from the original floats.
// processed_frame_count counts emitted frames, not samples received.
OMNI_CORE_EXPORT int omni_sortformer_stream_push(
    OmniSortformerStream *stream, uint64_t audio_sequence, const float *samples,
    size_t sample_count, uint64_t *accepted_audio_sequence,
    OmniSortformerResult *result, char **error_message);
// No extra audio, padding or model tail. Completed is immutable; repeated
// finish succeeds (1). Failed/cancelled finish returns 0. Drain still required.
OMNI_CORE_EXPORT int omni_sortformer_stream_finish(OmniSortformerStream *stream,
                                                   char **error_message);
// Independent, durable, idempotent cancellation bypasses command serialization.
OMNI_CORE_EXPORT void
omni_sortformer_stream_cancel(OmniSortformerStream *stream);
// Terminal required. Waits commands and releases arrays on the loading worker.
// Returns 1/0 drained/error; repeated drain succeeds. Never call on that
// worker.
OMNI_CORE_EXPORT int omni_sortformer_stream_drain(OmniSortformerStream *stream,
                                                  char **error_message);
// Cancel + drain + release lease. Callers synchronize raw stream destruction
// against all stream calls. Push/finish/drain serialize; cancel may overlap.
// A lease after model destroy remains drainable, never accepts more audio.
// All cancel/destroy/free functions are NULL safe; destroy exactly once.
OMNI_CORE_EXPORT void
omni_sortformer_stream_destroy(OmniSortformerStream *stream);
// Returns 1 after destruction; on 0 the stream remains owned and retryable.
OMNI_CORE_EXPORT int
omni_sortformer_stream_destroy_checked(OmniSortformerStream *stream,
                                       char **error_message);
// Frees both owned arrays and clears ALL fields; repeated/NULL safe.
OMNI_CORE_EXPORT void omni_sortformer_result_free(OmniSortformerResult *result);

#ifdef __cplusplus
}
#endif

#endif
