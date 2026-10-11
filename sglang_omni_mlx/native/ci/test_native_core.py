# SPDX-License-Identifier: Apache-2.0
"""Compile the public ABI and real worker with backend/MLX stubs, not real models."""

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
    assert(version() == 2);
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
    for filename in ("native_core.cpp", "worker.cpp", "worker.h"):
        shutil.copyfile(NATIVE_DIRECTORY / "src" / filename, build / filename)
    shutil.copyfile(
        NATIVE_DIRECTORY / "ci/native_core_stubs/transcriber.h",
        build / "transcriber.h",
    )
    common_flags = ["-Wall", "-Wextra", "-Werror", "-pthread"]
    sanitizers = os.environ.get("OMNI_ABI_SANITIZERS", "")
    if sanitizers:
        common_flags += [f"-fsanitize={sanitizers}", "-fno-omit-frame-pointer"]
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
            str(build / "worker.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/backend.cpp"),
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
            str(NATIVE_DIRECTORY / "ci/test_native_core.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/request_cases.cpp"),
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
    if case == "allocation_failures" and sys.platform != "linux":
        pytest.skip("malloc fault injection uses the Linux linker's --wrap")
    else:
        subprocess.run([str(abi_build / "abi_cases"), case], check=True, timeout=15)


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
    }
