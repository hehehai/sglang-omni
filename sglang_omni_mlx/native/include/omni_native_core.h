// SPDX-License-Identifier: Apache-2.0
#ifndef OMNI_NATIVE_CORE_H
#define OMNI_NATIVE_CORE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define OMNI_CORE_EXPORT __attribute__((visibility("default")))
#else
#define OMNI_CORE_EXPORT
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

#ifdef __cplusplus
}
#endif

#endif
