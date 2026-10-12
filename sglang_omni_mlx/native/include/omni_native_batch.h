// SPDX-License-Identifier: Apache-2.0
#ifndef OMNI_NATIVE_BATCH_H
#define OMNI_NATIVE_BATCH_H

#include <stddef.h>
#include <stdint.h>

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

#define OMNI_BATCH_SAMPLE_RATE 16000
#define OMNI_BATCH_MAX_SAMPLES 480000
#define OMNI_BATCH_MAX_TEXT_BYTES 65536
#define OMNI_BATCH_MAX_LANGUAGE_BYTES 128
#define OMNI_BATCH_MAX_PROMPT_BYTES 8192
#define OMNI_BATCH_MAX_TOKENS 4096
#define OMNI_BATCH_MAX_SEGMENTS 512
#define OMNI_BATCH_MAX_RESULT_STRING_BYTES 262144

typedef int32_t OmniBatchModelKind;
#define OMNI_BATCH_WHISPER 1
#define OMNI_BATCH_COHERE 2
#define OMNI_BATCH_MOSS 3
#define OMNI_BATCH_NEMOTRON 4
#define OMNI_BATCH_PARAKEET 5
#define OMNI_BATCH_SENSEVOICE 6

typedef int32_t OmniBatchStatus;
#define OMNI_BATCH_OK 0
#define OMNI_BATCH_INVALID 1
#define OMNI_BATCH_BUSY 2
#define OMNI_BATCH_CANCELLED 3
#define OMNI_BATCH_FAILED 4
#define OMNI_BATCH_OUT_OF_MEMORY 5
#define OMNI_BATCH_LIMIT 6

typedef int32_t OmniBatchFinishReason;
#define OMNI_BATCH_STOP 0
#define OMNI_BATCH_LENGTH 1

typedef struct OmniBatchOptions {
  OmniBatchModelKind model_kind;
  union {
    struct {
      const char *language;
      int32_t maximum_token_count;
      float temperature;
    } whisper;
    struct {
      const char *language;
      int32_t use_punctuation;
      int32_t maximum_token_count;
      float temperature;
      float chunk_duration_seconds;
      float minimum_chunk_duration_seconds;
    } cohere;
    struct {
      const char *prompt;
      int32_t maximum_token_count;
      int32_t stop_at_end_of_text;
      int32_t stop_on_token_loop;
    } moss;
    struct {
      const char *language;
      int32_t chunk_frame_count;
    } nemotron;
    struct {
      double chunk_duration_seconds;
    } parakeet;
    struct {
      const char *language;
      int32_t use_inverse_text_normalization;
    } sensevoice;
  } family;
} OmniBatchOptions;

typedef struct OmniBatchSegment {
  double start_seconds;
  double end_seconds;
  char *speaker;
  char *text;
  char *language;
  char *emotion;
  char *event;
} OmniBatchSegment;

typedef struct OmniBatchResult {
  char *text;
  char *language;
  int32_t generated_token_count;
  OmniBatchFinishReason finish_reason;
  OmniBatchSegment *segments;
  size_t segment_count;
} OmniBatchResult;

typedef struct OmniBatchHandle OmniBatchHandle;
typedef struct OmniBatchRequest OmniBatchRequest;

// ABI7: bounded final transcription only, never longform or realtime.
// All functions contain exceptions. No callbacks or borrowed output strings.
// Statuses require no allocation; FAILED never exposes private exception text.
// Initialize options with this function, then change only the selected family.
// NULL language preserves the family's default. MOSS token -1 is unset, 0 is
// automatic; other token budgets allow 0..4096. Nemotron frame 0 is unset,
// explicit frame counts 1..4096. Flags must be 0 or 1; temperatures finite >=0.
// Cohere accepts chunk 1..1200 seconds and minimum 0..30 seconds, <= chunk.
// Parakeet accepts chunk 2..300 or 1199..1200 seconds, with native
// interpretation. No VAD or window-offset options; unsupported model
// kinds/settings reject.
OMNI_CORE_EXPORT OmniBatchStatus omni_batch_options_default(
    OmniBatchModelKind model_kind, OmniBatchOptions *options);

// Synchronous nonpreemptible existing-directory load on one persistent worker.
// Model load, all Transcribe calls and model destruction use that same thread.
// Outputs are cleared first. Directory is a nonempty C string <=8192 bytes.
OMNI_CORE_EXPORT OmniBatchStatus
omni_batch_create(OmniBatchModelKind model_kind, const char *model_directory,
                  OmniBatchHandle **handle);
// Sticky stop-admission; cancels the leased request. Not a worker drain.
OMNI_CORE_EXPORT void omni_batch_cancel(OmniBatchHandle *handle);
// Requires every request lease destroyed, otherwise BUSY without destruction.
// On OK the handle is freed; on failure it remains owned and retryable.
// Caller prevents all new/raw model calls during destruction; NULL is OK.
OMNI_CORE_EXPORT OmniBatchStatus
omni_batch_destroy_checked(OmniBatchHandle *handle);

// One live request lease per model, even after completion/drain. BUSY never
// queues or copies audio. Lease pins worker/model until checked destruction.
OMNI_CORE_EXPORT OmniBatchStatus
omni_batch_request_create(OmniBatchHandle *handle, OmniBatchRequest **request);
// Durable independent cancellation; NULL safe. Cancellation is not a drain.
OMNI_CORE_EXPORT void omni_batch_request_cancel(OmniBatchRequest *request);
// Closes request admission, cancels and waits actual command completion.
// Repeated/NULL safe. Never invoke from a model worker thread.
OMNI_CORE_EXPORT OmniBatchStatus
omni_batch_request_drain(OmniBatchRequest *request);
// Cancel + drain + release lease. Failure retains request for explicit retry.
// Synchronize raw request destruction against ALL request calls; NULL is OK.
OMNI_CORE_EXPORT OmniBatchStatus
omni_batch_request_destroy_checked(OmniBatchRequest *request);

// Synchronous single-use request (even invalid input consumes the attempt).
// Finite mono16k Float32, 1..480000 samples; language<=128, prompt<=8192 bytes.
// Validation precedes bounded audio copy; simultaneous request use rejects
// BUSY. All inputs stay valid until return. Options must match the loaded
// family. Result required, cleared first; free any old snapshot before reuse.
// Owned strings preserve absent (NULL) versus present-empty. Invalid/oversize
// output fails without truncation. Times are finite nonnegative ordered
// seconds. Text<=65536 bytes, each metadata string<=128, segments<=512,
// tokens<=4096, total string storage including NULs<=262144. No borrowed native
// state.
OMNI_CORE_EXPORT OmniBatchStatus omni_batch_transcribe(
    OmniBatchRequest *request, const float *samples, size_t sample_count,
    const OmniBatchOptions *options, OmniBatchResult *result);
// Frees all owned snapshot storage and zeroes fields. Repeated/NULL safe.
OMNI_CORE_EXPORT void omni_batch_result_free(OmniBatchResult *result);

#ifdef __cplusplus
}
#endif
#endif
