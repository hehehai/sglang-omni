// SPDX-License-Identifier: Apache-2.0
#ifndef OMNI_NATIVE_CORE_H
#define OMNI_NATIVE_CORE_H

#include <stddef.h>

#if defined(__GNUC__) || defined(__clang__)
#define OMNI_CORE_EXPORT __attribute__((visibility("default")))
#else
#define OMNI_CORE_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OmniQwenHandle OmniQwenHandle;
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

// Cancels queued/running requests and prevents later submissions on this
// handle. Create a new handle after cancellation; repeated calls and NULL are
// safe.
OMNI_CORE_EXPORT void omni_qwen_cancel(OmniQwenHandle *handle);

// Cancels and joins the worker before releasing its model. May overlap requests
// already submitted, but callers must prevent new calls (including cancel) once
// destruction begins. Destroy exactly once; NULL is safe.
OMNI_CORE_EXPORT void omni_qwen_destroy(OmniQwenHandle *handle);

// Frees owned strings and zeroes the result; repeated calls and NULL are safe.
OMNI_CORE_EXPORT void omni_qwen_result_free(OmniQwenResult *result);
OMNI_CORE_EXPORT void omni_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
