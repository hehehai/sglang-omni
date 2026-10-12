// SPDX-License-Identifier: Apache-2.0
#include "omni_native_core.h"
#include <assert.h>
#include <stddef.h>
#include <string.h>

_Static_assert(offsetof(OmniQwenResult, text) == 0, "text layout");
_Static_assert(offsetof(OmniQwenResult, language) == sizeof(char *), "language layout");
_Static_assert(offsetof(OmniQwenResult, generated_token_count) == 2 * sizeof(char *), "count layout");
_Static_assert(offsetof(OmniQwenResult, hit_length_limit) == 2 * sizeof(char *) + sizeof(int), "limit layout");
_Static_assert(sizeof(OmniQwenResult) == 2 * sizeof(char *) + 2 * sizeof(int), "result size");
_Static_assert(sizeof(OmniQwenRealtimeSettings) == 4 * sizeof(int32_t), "settings size");
_Static_assert(offsetof(OmniQwenRealtimeSettings, decode_interval_samples) == 0, "interval layout");
_Static_assert(offsetof(OmniQwenRealtimeSettings, first_decode_samples) == 4, "first layout");
_Static_assert(offsetof(OmniQwenRealtimeSettings, maximum_segment_samples) == 8, "segment budget layout");
_Static_assert(offsetof(OmniQwenRealtimeSettings, maximum_token_count) == 12, "token budget layout");
_Static_assert(sizeof(OmniQwenRealtimeEventKind) == sizeof(int32_t), "fixed event kind width");
_Static_assert(offsetof(OmniQwenRealtimeEvent, session_id) == 0, "identity layout");
_Static_assert(offsetof(OmniQwenRealtimeEvent, event_sequence) == 8, "sequence layout");
_Static_assert(offsetof(OmniQwenRealtimeEvent, kind) == 16, "kind layout");
_Static_assert(offsetof(OmniQwenRealtimeEvent, segment_id) == 20, "segment layout");
_Static_assert(offsetof(OmniQwenRealtimeEvent, is_final) == 24, "final layout");
#define ALIGN_UP(bytes, alignment) (((bytes) + (alignment) - 1) / (alignment) * (alignment))
_Static_assert(offsetof(OmniQwenRealtimeEvent, text) == ALIGN_UP(28, _Alignof(char *)), "text layout");
_Static_assert(offsetof(OmniQwenRealtimeEvent, error_message) == offsetof(OmniQwenRealtimeEvent, text) + sizeof(char *), "error layout");
_Static_assert(sizeof(((OmniQwenRealtimeEvent *)0)->session_id) == sizeof(uint64_t), "identity width");
_Static_assert(sizeof(((OmniQwenRealtimeEvent *)0)->event_sequence) == sizeof(uint64_t), "sequence width");
_Static_assert(OMNI_QWEN_REALTIME_UPDATED == 1 && OMNI_QWEN_REALTIME_SEGMENT == 2 &&
               OMNI_QWEN_REALTIME_COMPLETED == 3 && OMNI_QWEN_REALTIME_CANCELLED == 4 &&
               OMNI_QWEN_REALTIME_FAILED == 5, "event values");
_Static_assert(OMNI_QWEN_REALTIME_MAX_CHUNK_SAMPLES == 32000 &&
               OMNI_QWEN_REALTIME_MAX_SESSION_SAMPLES == 480000 &&
               OMNI_QWEN_REALTIME_MAX_QUEUED_EVENTS == 64 &&
               OMNI_QWEN_REALTIME_MAX_EVENT_STRING_BYTES == 65536 &&
               OMNI_QWEN_REALTIME_MAX_FINAL_SEGMENTS == 512 &&
               OMNI_QWEN_REALTIME_MAX_TRANSCRIPT_BYTES == 65536 &&
               OMNI_QWEN_REALTIME_MAX_QUEUED_STRING_BYTES == 4194304 &&
               OMNI_QWEN_REALTIME_MAX_LANGUAGE_BYTES == 128 &&
               OMNI_QWEN_REALTIME_MAX_CONTEXT_BYTES == 8192 &&
               OMNI_QWEN_REALTIME_MAX_TOKEN_COUNT == 4096, "public limits");

#include "silero_c_client.h"
#include "sortformer_c_client.h"

int main(void) {
    check_silero_c_abi();
    check_sortformer_c_abi();
    unsigned int (*version)(void) = omni_core_abi_version;
    OmniQwenHandle *(*create)(const char *, char **) = omni_qwen_create;
    int (*transcribe)(OmniQwenHandle *, const float *, size_t, const char *,
                      const char *, int, OmniQwenResult *, char **) = omni_qwen_transcribe;
    void (*cancel)(OmniQwenHandle *) = omni_qwen_cancel;
    void (*destroy)(OmniQwenHandle *) = omni_qwen_destroy;
    void (*result_free)(OmniQwenResult *) = omni_qwen_result_free;
    void (*string_free)(char *) = omni_string_free;
    OmniQwenRequest *(*request_create)(void) = omni_qwen_request_create;
    void (*request_cancel)(OmniQwenRequest *) = omni_qwen_request_cancel;
    void (*request_destroy)(OmniQwenRequest *) = omni_qwen_request_destroy;
    int (*transcribe_request)(OmniQwenHandle *, OmniQwenRequest *, const float *,
                              size_t, const char *, const char *, int,
                              OmniQwenResult *, char **) = omni_qwen_transcribe_request;
    assert(version() == 6);
    int (*sortformer_destroy_checked)(OmniSortformerHandle *, char **) = omni_sortformer_destroy_checked;
    int (*sortformer_stream_destroy_checked)(OmniSortformerStream *, char **) = omni_sortformer_stream_destroy_checked;
    char *error = NULL;
    assert(sortformer_destroy_checked(NULL, &error) == 1 && error == NULL);
    assert(sortformer_stream_destroy_checked(NULL, &error) == 1 && error == NULL);
    assert(create(NULL, &error) == NULL);
    assert(strcmp(error, "Invalid model directory.") == 0);
    string_free(error);
    OmniQwenResult result = {0};
    assert(transcribe(NULL, NULL, 0, NULL, NULL, 1, &result, &error) == 0);
    assert(result.text == NULL && result.language == NULL);
    string_free(error);
    result_free(&result);
    cancel(NULL);
    destroy(NULL);
    OmniQwenRequest *request = request_create();
    assert(request != NULL);
    request_cancel(request);
    assert(transcribe_request(NULL, request, NULL, 0, NULL, NULL, 1, &result, &error) == 0);
    assert(strcmp(error, "Invalid transcription input.") == 0);
    string_free(error);
    assert(transcribe_request(NULL, request, NULL, 0, NULL, NULL, 1, &result, &error) == 0);
    assert(strcmp(error, "Request already used.") == 0);
    string_free(error);
    request_destroy(request);
    request_cancel(NULL);
    request_destroy(NULL);
    OmniQwenRealtime *(*realtime_create)(OmniQwenHandle *, uint64_t,
        const OmniQwenRealtimeSettings *, const char *, const char *, char **) = omni_qwen_realtime_create;
    int (*push)(OmniQwenRealtime *, uint64_t, const float *, size_t, uint64_t *, char **) = omni_qwen_realtime_push;
    int (*finish)(OmniQwenRealtime *, char **) = omni_qwen_realtime_finish;
    int (*poll)(OmniQwenRealtime *, OmniQwenRealtimeEvent *, char **) = omni_qwen_realtime_poll;
    void (*realtime_cancel)(OmniQwenRealtime *) = omni_qwen_realtime_cancel;
    int (*drain)(OmniQwenRealtime *, char **) = omni_qwen_realtime_drain;
    void (*realtime_destroy)(OmniQwenRealtime *) = omni_qwen_realtime_destroy;
    void (*event_free)(OmniQwenRealtimeEvent *) = omni_qwen_realtime_event_free;
    assert(realtime_create(NULL, 1, NULL, NULL, NULL, NULL) == NULL);
    uint64_t accepted_sequence = UINT64_MAX;
    assert(push(NULL, 1, NULL, 0, &accepted_sequence, NULL) == 0);
    assert(accepted_sequence == 0);
    OmniQwenRealtimeEvent event = {0};
    assert(poll(NULL, &event, NULL) == -1);
    assert(event.session_id == 0 && event.text == NULL && event.error_message == NULL);
    assert(finish(NULL, NULL) == 0 && drain(NULL, NULL) == 0);
    realtime_cancel(NULL);
    realtime_destroy(NULL);
    event_free(&event);
    event_free(&event);
    event_free(NULL);
    return 0;
}
