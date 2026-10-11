# SPDX-License-Identifier: Apache-2.0
"""Test the public ABI with real realtime/worker sources and CPU model stand-ins."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

NATIVE_DIRECTORY = Path(__file__).resolve().parents[1]
CASES = (
    "invalid_directories",
    "invalid_inputs",
    "ownership_options",
    "exceptions",
    "allocation_failures",
    "cancellation",
    "cancel_before_submission",
    "destroy_active",
    "concurrent_requests",
    "request_cancel_before_submission",
    "request_invalid",
    "request_cancel_active",
    "request_destroy_active",
    "request_model_cancel_active",
    "request_model_destroy_active",
    "request_cancel_queued",
    "request_destroy_queued",
    "request_model_cancel_queued",
    "request_concurrent_reuse",
    "request_failures",
    "realtime_invalid",
    "realtime_sequence",
    "realtime_options_prefix",
    "realtime_total_samples",
    "realtime_ownership",
    "realtime_unicode",
    "realtime_failures",
    "realtime_poll_allocation",
    "realtime_refresh_allocation",
    "realtime_cancel_before_submission",
    "realtime_cancel_active",
    "realtime_cancel_queued",
    "realtime_destroy_active",
    "realtime_destroy_queued",
    "realtime_model_cancel",
    "realtime_model_destroy",
    "realtime_finish_cancel_race",
    "realtime_backpressure",
    "realtime_terminal_reserve",
    "realtime_text_limits",
    "realtime_transcript_limits",
)
C_CLIENT = """
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

int main(void) {
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
    assert(version() == 3);
    char *error = NULL;
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
"""


@pytest.fixture(scope="module")
def abi_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    compiler = shutil.which(os.environ.get("CXX", "c++"))
    c_compiler = shutil.which(os.environ.get("CC", "cc"))
    if compiler is None or c_compiler is None:
        pytest.skip("C and C++ compilers are required for the stub-backed ABI suite")
    else:
        pass
    build = tmp_path_factory.mktemp("native-abi-backend-mlx-stubs")
    # Note (Codex): byte-identical copies let quoted includes select only the
    # test backend header; production worker and ABI code are not rewritten.
    for filename in (
        "native_core.cpp",
        "native_realtime.cpp",
        "native_core_internal.h",
        "native_realtime_state.cpp",
        "native_realtime_state.h",
        "realtime_engine.cpp",
        "realtime_engine.h",
        "worker.cpp",
        "worker.h",
    ):
        source = NATIVE_DIRECTORY / "src" / filename
        shutil.copyfile(source, build / filename)
        assert (build / filename).read_bytes() == source.read_bytes()
    for filename in ("transcriber.h", "audio.h"):
        shutil.copyfile(
            NATIVE_DIRECTORY / "ci/native_core_stubs" / filename, build / filename
        )
    common_flags = ["-Wall", "-Wextra", "-Werror", "-pthread"]
    sanitizers = os.environ.get("OMNI_ABI_SANITIZERS", "")
    if sanitizers:
        common_flags += [f"-fsanitize={sanitizers}", "-fno-omit-frame-pointer"]
    else:
        pass
    executable_flags = []
    if sanitizers and sys.platform == "linux":
        # Note (OpenAI): non-PIE avoids GCC ASan shadow/ASLR startup collisions.
        executable_flags = ["-fno-pie", "-no-pie"]
    else:
        pass
    include_flags = ["-I", str(NATIVE_DIRECTORY / "include"), "-I", str(build)]
    library_name = "libOmniCore.dylib" if sys.platform == "darwin" else "libOmniCore.so"
    library_flags = ["-dynamiclib"] if sys.platform == "darwin" else ["-shared"]
    wrap_flags = ["-DOMNI_ABI_WRAP_MALLOC"] if sys.platform == "linux" else []
    wrap_link_flags = ["-Wl,--wrap=malloc"] if sys.platform == "linux" else []
    subprocess.run(
        [
            compiler,
            "-std=c++20",
            *common_flags,
            *include_flags,
            *library_flags,
            "-fPIC",
            "-fvisibility=hidden",
            *wrap_flags,
            *wrap_link_flags,
            str(build / "native_core.cpp"),
            str(build / "native_realtime.cpp"),
            str(build / "native_realtime_state.cpp"),
            str(build / "realtime_engine.cpp"),
            str(build / "worker.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/backend.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/unicode.cpp"),
            "-o",
            str(build / library_name),
        ],
        check=True,
        timeout=60,
    )
    subprocess.run(
        [
            compiler,
            "-std=c++20",
            *common_flags,
            *include_flags,
            *wrap_flags,
            *executable_flags,
            str(NATIVE_DIRECTORY / "ci/test_native_core.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/request_cases.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/realtime_cases.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/realtime_cases_lifecycle.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/realtime_cases_queue.cpp"),
            "-L",
            str(build),
            "-lOmniCore",
            f"-Wl,-rpath,{build}",
            "-o",
            str(build / "abi_cases"),
        ],
        check=True,
        timeout=60,
    )
    (build / "client.c").write_text(C_CLIENT)
    subprocess.run(
        [
            c_compiler,
            "-std=c11",
            *common_flags,
            *include_flags,
            "-c",
            str(build / "client.c"),
            "-o",
            str(build / "client.o"),
        ],
        check=True,
        timeout=60,
    )
    subprocess.run(
        [
            compiler if sanitizers else c_compiler,
            *common_flags,
            *executable_flags,
            str(build / "client.o"),
            "-L",
            str(build),
            "-lOmniCore",
            f"-Wl,-rpath,{build}",
            "-o",
            str(build / "c_client"),
        ],
        check=True,
        timeout=60,
    )
    return build


@pytest.mark.parametrize("case", CASES)
def test_public_abi_with_backend_mlx_stubs(abi_build: Path, case: str) -> None:
    if (
        case
        in {
            "allocation_failures",
            "realtime_poll_allocation",
            "realtime_refresh_allocation",
        }
        and sys.platform != "linux"
    ):
        pytest.skip("allocation fault injection uses the Linux linker's --wrap")
    else:
        completed = subprocess.run(
            [str(abi_build / "abi_cases"), case],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert completed.returncode == 0, completed.stdout + completed.stderr
        assert "PRIVATE" not in completed.stderr
        assert "private context" not in completed.stderr
        assert "private/model" not in completed.stderr


def test_pure_c_header_and_linkage(abi_build: Path) -> None:
    subprocess.run([str(abi_build / "c_client")], check=True, timeout=15)


def test_exported_c_symbols(abi_build: Path) -> None:
    if sys.platform == "darwin":
        command = ["nm", "-gU", str(abi_build / "libOmniCore.dylib")]
    else:
        command = ["nm", "-D", "--defined-only", str(abi_build / "libOmniCore.so")]
    symbols = subprocess.run(
        command, check=True, capture_output=True, text=True, timeout=15
    ).stdout
    exported = {line.split()[-1].removeprefix("_") for line in symbols.splitlines()}
    assert {symbol for symbol in exported if symbol.startswith("omni_")} == {
        "omni_core_abi_version",
        "omni_qwen_create",
        "omni_qwen_transcribe",
        "omni_qwen_cancel",
        "omni_qwen_destroy",
        "omni_qwen_result_free",
        "omni_string_free",
        "omni_qwen_request_create",
        "omni_qwen_request_cancel",
        "omni_qwen_request_destroy",
        "omni_qwen_transcribe_request",
        "omni_qwen_realtime_create",
        "omni_qwen_realtime_push",
        "omni_qwen_realtime_finish",
        "omni_qwen_realtime_poll",
        "omni_qwen_realtime_cancel",
        "omni_qwen_realtime_drain",
        "omni_qwen_realtime_destroy",
        "omni_qwen_realtime_event_free",
    }
