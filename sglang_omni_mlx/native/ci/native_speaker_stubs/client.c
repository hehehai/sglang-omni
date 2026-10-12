// SPDX-License-Identifier: Apache-2.0
#include "omni_native_speaker.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
_Static_assert(sizeof(OmniSpeakerModelKind) == 4, "kind is int32");
_Static_assert(sizeof(OmniBatchStatus) == 4, "status is int32");
_Static_assert(sizeof(((OmniSpeakerRealtimeSettings *)0)
                          ->family.nemotron.chunk_milliseconds) == 8,
               "chunk milliseconds must be double");
_Static_assert(sizeof(((OmniBatchSegment *)0)->start_seconds) == 8,
               "times must stay double");
_Static_assert(OMNI_SPEAKER_SAMPLE_RATE == 16000 &&
                   OMNI_SPEAKER_MAX_CHUNK_SAMPLES == 32000 &&
                   OMNI_SPEAKER_MAX_SESSION_SAMPLES == 480000 &&
                   OMNI_SPEAKER_MAX_QUEUED_EVENTS == 64,
               "bounded audio contract changed");
int main(int argument_count, char **arguments) {
  if (argument_count != 2) {
    return 1;
  } else {
  }
  void *library = dlopen(arguments[1], RTLD_NOW | RTLD_LOCAL);
  if (library == NULL) {
    fprintf(stderr, "%s\n", dlerror());
    return 2;
  } else {
  }
  const char *exports[] = {"omni_speaker_settings_default",
                           "omni_speaker_create",
                           "omni_speaker_cancel",
                           "omni_speaker_destroy_checked",
                           "omni_speaker_realtime_create",
                           "omni_speaker_realtime_push",
                           "omni_speaker_realtime_commit",
                           "omni_speaker_realtime_finish",
                           "omni_speaker_realtime_poll",
                           "omni_speaker_realtime_cancel",
                           "omni_speaker_realtime_drain",
                           "omni_speaker_realtime_destroy_checked",
                           "omni_speaker_realtime_event_free"};
  for (size_t i = 0; i < sizeof(exports) / sizeof(exports[0]); ++i) {
    if (dlsym(library, exports[i]) == NULL) {
      fprintf(stderr, "missing %s\n", exports[i]);
      return 3;
    } else {
    }
  }
  OmniSpeakerRealtimeSettings settings;
  memset(&settings, 0xff, sizeof(settings));
  if (omni_speaker_settings_default(OMNI_SPEAKER_NEMOTRON, &settings) !=
          OMNI_BATCH_OK ||
      settings.model_kind != OMNI_SPEAKER_NEMOTRON ||
      settings.family.nemotron.language != NULL ||
      settings.family.nemotron.has_chunk != 0 ||
      settings.family.nemotron.chunk_milliseconds != 0) {
    return 4;
  } else {
  }
  OmniSpeakerHandle *model = NULL;
  OmniSpeakerRealtime *stream = NULL;
  if (omni_speaker_create(OMNI_SPEAKER_NEMOTRON, ".", &model) !=
          OMNI_BATCH_OK ||
      omni_speaker_realtime_create(model, 8, &settings, &stream) !=
          OMNI_BATCH_OK ||
      omni_speaker_realtime_finish(stream) != OMNI_BATCH_OK) {
    return 5;
  } else {
  }
  OmniSpeakerRealtimeEvent event = {0};
  while (omni_speaker_realtime_poll(stream, &event) == 1) {
    omni_speaker_realtime_event_free(&event);
  }
  if (omni_speaker_realtime_destroy_checked(stream) != OMNI_BATCH_OK ||
      omni_speaker_destroy_checked(model) != OMNI_BATCH_OK) {
    return 6;
  } else {
  }
  dlclose(library);
  return 0;
}
