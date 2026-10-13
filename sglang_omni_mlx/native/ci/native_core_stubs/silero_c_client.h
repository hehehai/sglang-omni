// SPDX-License-Identifier: Apache-2.0
// Compiled as C11: additive ABI widths, layouts, signatures and linkage.
#include "omni_native_core.h"

#define FIELD_TYPE(structure, field, type)                                     \
  _Static_assert(_Generic(((structure *)0)->field, type: 1, default: 0),       \
                 #field " type")
FIELD_TYPE(OmniSileroSettings, threshold, float);
FIELD_TYPE(OmniSileroSettings, minimum_speech_milliseconds, int32_t);
FIELD_TYPE(OmniSileroSettings, minimum_silence_milliseconds, int32_t);
FIELD_TYPE(OmniSileroSettings, speech_padding_milliseconds, int32_t);
FIELD_TYPE(OmniSileroTimestamp, start_sample, int64_t);
FIELD_TYPE(OmniSileroTimestamp, end_sample, int64_t);
FIELD_TYPE(OmniSileroResult, timestamps, OmniSileroTimestamp *);
FIELD_TYPE(OmniSileroResult, timestamp_count, size_t);
FIELD_TYPE(OmniSileroStreamResult, probabilities, float *);
FIELD_TYPE(OmniSileroStreamResult, probability_count, size_t);
FIELD_TYPE(OmniSileroStreamResult, processed_sample_count, uint64_t);
#undef FIELD_TYPE

_Static_assert(sizeof(OmniSileroSettings) == 16, "Silero settings size");
_Static_assert(offsetof(OmniSileroSettings, threshold) == 0,
               "threshold layout");
_Static_assert(offsetof(OmniSileroSettings, minimum_speech_milliseconds) == 4,
               "speech layout");
_Static_assert(offsetof(OmniSileroSettings, minimum_silence_milliseconds) == 8,
               "silence layout");
_Static_assert(offsetof(OmniSileroSettings, speech_padding_milliseconds) == 12,
               "padding layout");
_Static_assert(sizeof(((OmniSileroSettings *)0)->threshold) == sizeof(float),
               "threshold width");
_Static_assert(sizeof(((OmniSileroSettings *)0)->minimum_speech_milliseconds) ==
                   sizeof(int32_t),
               "speech width");
_Static_assert(
    sizeof(((OmniSileroSettings *)0)->minimum_silence_milliseconds) ==
        sizeof(int32_t),
    "silence width");
_Static_assert(sizeof(((OmniSileroSettings *)0)->speech_padding_milliseconds) ==
                   sizeof(int32_t),
               "padding width");
_Static_assert(sizeof(OmniSileroTimestamp) == 16, "timestamp size");
_Static_assert(offsetof(OmniSileroTimestamp, start_sample) == 0,
               "start layout");
_Static_assert(offsetof(OmniSileroTimestamp, end_sample) == 8, "end layout");
_Static_assert(sizeof(((OmniSileroTimestamp *)0)->start_sample) ==
                   sizeof(int64_t),
               "start width");
_Static_assert(sizeof(((OmniSileroTimestamp *)0)->end_sample) ==
                   sizeof(int64_t),
               "end width");
_Static_assert(offsetof(OmniSileroResult, timestamps) == 0,
               "timestamps layout");
_Static_assert(offsetof(OmniSileroResult, timestamp_count) == sizeof(void *),
               "timestamp count layout");
_Static_assert(sizeof(OmniSileroResult) == sizeof(void *) + sizeof(size_t),
               "result size");
_Static_assert(offsetof(OmniSileroStreamResult, probabilities) == 0,
               "probability layout");
_Static_assert(offsetof(OmniSileroStreamResult, probability_count) ==
                   sizeof(void *),
               "probability count layout");
_Static_assert(offsetof(OmniSileroStreamResult, processed_sample_count) ==
                   ALIGN_UP(sizeof(void *) + sizeof(size_t),
                            _Alignof(uint64_t)),
               "processed count layout");
_Static_assert(sizeof(OmniSileroStreamResult) ==
                   offsetof(OmniSileroStreamResult, processed_sample_count) +
                       sizeof(uint64_t),
               "stream result size");
_Static_assert(sizeof(((OmniSileroResult *)0)->timestamp_count) ==
                   sizeof(size_t),
               "timestamp count width");
_Static_assert(sizeof(((OmniSileroStreamResult *)0)->probability_count) ==
                   sizeof(size_t),
               "probability count width");
_Static_assert(sizeof(((OmniSileroStreamResult *)0)->processed_sample_count) ==
                   sizeof(uint64_t),
               "processed count width");
_Static_assert(OMNI_SILERO_SAMPLE_RATE == 16000 &&
                   OMNI_SILERO_FRAME_SAMPLES == 512 &&
                   OMNI_SILERO_MAX_OFFLINE_SAMPLES == 480000 &&
                   OMNI_SILERO_MAX_CHUNK_SAMPLES == 32000 &&
                   OMNI_SILERO_MAX_STREAMS == 16 &&
                   OMNI_SILERO_MAX_OPTION_MILLISECONDS == 30000,
               "Silero public limits");

static void check_silero_c_abi(void) {
  OmniSileroHandle *(*create)(const char *, char **) = omni_silero_create;
  int (*create_checked)(const char *, OmniSileroHandle **, char **) =
      omni_silero_create_checked;
  void (*cancel)(OmniSileroHandle *) = omni_silero_cancel;
  void (*destroy)(OmniSileroHandle *) = omni_silero_destroy;
  int (*destroy_checked)(OmniSileroHandle *, char **) =
      omni_silero_destroy_checked;
  OmniSileroRequest *(*request_create)(void) = omni_silero_request_create;
  void (*request_cancel)(OmniSileroRequest *) = omni_silero_request_cancel;
  void (*request_destroy)(OmniSileroRequest *) = omni_silero_request_destroy;
  int (*speech_timestamps)(OmniSileroHandle *, OmniSileroRequest *,
                           const float *, size_t, const OmniSileroSettings *,
                           OmniSileroResult *, char **) =
      omni_silero_speech_timestamps;
  void (*result_free)(OmniSileroResult *) = omni_silero_result_free;
  OmniSileroStream *(*stream_create)(OmniSileroHandle *, char **) =
      omni_silero_stream_create;
  int (*push)(OmniSileroStream *, uint64_t, const float *, size_t, uint64_t *,
              OmniSileroStreamResult *, char **) = omni_silero_stream_push;
  int (*finish)(OmniSileroStream *, OmniSileroStreamResult *, char **) =
      omni_silero_stream_finish;
  void (*stream_cancel)(OmniSileroStream *) = omni_silero_stream_cancel;
  int (*drain)(OmniSileroStream *, char **) = omni_silero_stream_drain;
  void (*stream_destroy)(OmniSileroStream *) = omni_silero_stream_destroy;
  int (*stream_destroy_checked)(OmniSileroStream *, char **) =
      omni_silero_stream_destroy_checked;
  void (*stream_result_free)(OmniSileroStreamResult *) =
      omni_silero_stream_result_free;
  char *error = NULL;
  assert(create(NULL, &error) == NULL && error != NULL);
  omni_string_free(error);
  OmniSileroHandle *model = (OmniSileroHandle *)(uintptr_t)1;
  assert(create_checked(NULL, &model, &error) == 0);
  assert(model == NULL && error != NULL);
  omni_string_free(error);
  assert(create_checked(".", NULL, &error) == 0 && error != NULL);
  omni_string_free(error);
  assert(create_checked("", &model, &error) == 0);
  assert(model == NULL && error != NULL);
  omni_string_free(error);
  cancel(NULL);
  destroy(NULL);
  assert(destroy_checked(NULL, &error) == 1 && error == NULL);
  assert(stream_destroy_checked(NULL, &error) == 1 && error == NULL);
  OmniSileroRequest *request = request_create();
  assert(request != NULL);
  request_cancel(request);
  request_cancel(request);
  OmniSileroResult result = {0};
  assert(speech_timestamps(NULL, request, NULL, 0, NULL, &result, &error) == 0);
  assert(result.timestamps == NULL && result.timestamp_count == 0);
  omni_string_free(error);
  result_free(&result);
  result_free(&result);
  result_free(NULL);
  request_destroy(request);
  request_cancel(NULL);
  request_destroy(NULL);
  assert(stream_create(NULL, NULL) == NULL);
  OmniSileroStreamResult stream_result = {0};
  uint64_t accepted_sequence = UINT64_MAX;
  assert(push(NULL, 1, NULL, 0, &accepted_sequence, &stream_result, NULL) == 0);
  assert(accepted_sequence == 0 && stream_result.probabilities == NULL &&
         stream_result.probability_count == 0 &&
         stream_result.processed_sample_count == 0);
  assert(finish(NULL, &stream_result, NULL) == 0);
  assert(drain(NULL, NULL) == 0);
  stream_cancel(NULL);
  stream_destroy(NULL);
  stream_result_free(&stream_result);
  stream_result_free(&stream_result);
  stream_result_free(NULL);
}
