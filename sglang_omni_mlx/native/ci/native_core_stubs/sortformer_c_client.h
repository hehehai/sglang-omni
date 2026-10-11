// SPDX-License-Identifier: Apache-2.0
// Compiled as C11: all ABI5 field widths/layouts and function pointer linkage.
#include "omni_native_core.h"

#define FIELD_TYPE(structure, field, type)                                     \
  _Static_assert(_Generic(((structure *)0)->field, type: 1, default: 0),       \
                 #field " type")
FIELD_TYPE(OmniSortformerSettings, threshold, float);
FIELD_TYPE(OmniSortformerSettings, minimum_duration_seconds, float);
FIELD_TYPE(OmniSortformerSettings, merge_gap_seconds, float);
FIELD_TYPE(OmniSortformerSettings, speaker_cache_max_frames, int32_t);
FIELD_TYPE(OmniSortformerSettings, fifo_max_frames, int32_t);
FIELD_TYPE(OmniSortformerSegment, start_seconds, double);
FIELD_TYPE(OmniSortformerSegment, end_seconds, double);
FIELD_TYPE(OmniSortformerSegment, speaker_index, int32_t);
FIELD_TYPE(OmniSortformerResult, probabilities, float *);
FIELD_TYPE(OmniSortformerResult, probability_count, size_t);
FIELD_TYPE(OmniSortformerResult, frame_count, int32_t);
FIELD_TYPE(OmniSortformerResult, speaker_count, int32_t);
FIELD_TYPE(OmniSortformerResult, frame_duration_seconds, double);
FIELD_TYPE(OmniSortformerResult, segments, OmniSortformerSegment *);
FIELD_TYPE(OmniSortformerResult, segment_count, size_t);
FIELD_TYPE(OmniSortformerResult, processed_frame_count, uint64_t);
#undef FIELD_TYPE

_Static_assert(sizeof(OmniSortformerSettings) == 20, "settings size");
_Static_assert(offsetof(OmniSortformerSettings, threshold) == 0,
               "threshold layout");
_Static_assert(offsetof(OmniSortformerSettings, minimum_duration_seconds) == 4,
               "duration layout");
_Static_assert(offsetof(OmniSortformerSettings, merge_gap_seconds) == 8,
               "gap layout");
_Static_assert(offsetof(OmniSortformerSettings, speaker_cache_max_frames) == 12,
               "cache layout");
_Static_assert(offsetof(OmniSortformerSettings, fifo_max_frames) == 16,
               "FIFO layout");
_Static_assert(offsetof(OmniSortformerSegment, start_seconds) == 0,
               "start layout");
_Static_assert(offsetof(OmniSortformerSegment, end_seconds) == 8, "end layout");
_Static_assert(offsetof(OmniSortformerSegment, speaker_index) == 16,
               "speaker layout");
_Static_assert(sizeof(OmniSortformerSegment) == ALIGN_UP(20, _Alignof(double)),
               "segment size");
_Static_assert(offsetof(OmniSortformerResult, probabilities) == 0,
               "probabilities layout");
_Static_assert(offsetof(OmniSortformerResult, probability_count) ==
                   sizeof(void *),
               "probability count layout");
_Static_assert(offsetof(OmniSortformerResult, frame_count) ==
                   sizeof(void *) + sizeof(size_t),
               "frame layout");
_Static_assert(offsetof(OmniSortformerResult, speaker_count) ==
                   offsetof(OmniSortformerResult, frame_count) + 4,
               "speakers layout");
_Static_assert(offsetof(OmniSortformerResult, frame_duration_seconds) ==
                   ALIGN_UP(offsetof(OmniSortformerResult, speaker_count) + 4,
                            _Alignof(double)),
               "frame duration layout");
_Static_assert(
    offsetof(OmniSortformerResult, segments) ==
        ALIGN_UP(offsetof(OmniSortformerResult, frame_duration_seconds) + 8,
                 _Alignof(void *)),
    "segments layout");
_Static_assert(offsetof(OmniSortformerResult, segment_count) ==
                   offsetof(OmniSortformerResult, segments) + sizeof(void *),
               "segment count layout");
_Static_assert(offsetof(OmniSortformerResult, processed_frame_count) ==
                   ALIGN_UP(offsetof(OmniSortformerResult, segment_count) +
                                sizeof(size_t),
                            _Alignof(uint64_t)),
               "processed frames layout");
_Static_assert(sizeof(OmniSortformerResult) ==
                   offsetof(OmniSortformerResult, processed_frame_count) +
                       sizeof(uint64_t),
               "result size");
_Static_assert(OMNI_SORTFORMER_SAMPLE_RATE == 16000 &&
                   OMNI_SORTFORMER_MAX_CHUNK_SAMPLES == 32000 &&
                   OMNI_SORTFORMER_MAX_STREAMS == 16 &&
                   OMNI_SORTFORMER_MAX_STATE_FRAMES == 4096 &&
                   OMNI_SORTFORMER_MAX_CHUNK_FRAMES == 26 &&
                   OMNI_SORTFORMER_MAX_SPEAKERS == 4 &&
                   OMNI_SORTFORMER_MAX_SEGMENTS == 104,
               "Sortformer limits");

static void check_sortformer_c_abi(void) {
  OmniSortformerHandle *(*create)(const char *, char **) =
      omni_sortformer_create;
  void (*cancel)(OmniSortformerHandle *) = omni_sortformer_cancel;
  void (*destroy)(OmniSortformerHandle *) = omni_sortformer_destroy;
  OmniSortformerStream *(*stream_create)(
      OmniSortformerHandle *, const OmniSortformerSettings *, char **) =
      omni_sortformer_stream_create;
  int (*push)(OmniSortformerStream *, uint64_t, const float *, size_t,
              uint64_t *, OmniSortformerResult *, char **) =
      omni_sortformer_stream_push;
  int (*finish)(OmniSortformerStream *, char **) =
      omni_sortformer_stream_finish;
  void (*stream_cancel)(OmniSortformerStream *) = omni_sortformer_stream_cancel;
  int (*drain)(OmniSortformerStream *, char **) = omni_sortformer_stream_drain;
  void (*stream_destroy)(OmniSortformerStream *) =
      omni_sortformer_stream_destroy;
  void (*result_free)(OmniSortformerResult *) = omni_sortformer_result_free;
  char *error = NULL;
  assert(create(NULL, &error) == NULL && error != NULL);
  omni_string_free(error);
  cancel(NULL);
  destroy(NULL);
  assert(stream_create(NULL, NULL, NULL) == NULL);
  OmniSortformerResult result = {0};
  uint64_t accepted = UINT64_MAX;
  assert(push(NULL, 1, NULL, 0, &accepted, &result, NULL) == 0);
  assert(accepted == 0 && result.probabilities == NULL &&
         result.probability_count == 0 && result.frame_count == 0 &&
         result.speaker_count == 0 && result.frame_duration_seconds == 0 &&
         result.segments == NULL && result.segment_count == 0 &&
         result.processed_frame_count == 0);
  assert(finish(NULL, NULL) == 0 && drain(NULL, NULL) == 0);
  stream_cancel(NULL);
  stream_destroy(NULL);
  result_free(&result);
  result_free(&result);
  result_free(NULL);
}
