# SPDX-License-Identifier: Apache-2.0
"""Compile actual batch Core sources with explicit Transcriber/model/MLX stand-ins."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

NATIVE_DIRECTORY = Path(__file__).resolve().parents[1]
FAMILIES = ("whisper", "cohere", "moss", "nemotron", "parakeet", "sensevoice")
SOURCES = (
    "native_batch.cpp",
    "native_batch_worker.cpp",
    "native_batch_validation.cpp",
    "native_batch_result.cpp",
)
CASES = (
    "defaults",
    "custom",
    "inputs",
    "settings",
    "outputs",
    "bounds",
    "lifetime_cancel_before",
    "lifetime_drain_before",
    "lifetime_contention",
    "lifetime_cancel_active",
    "lifetime_drain_active",
    "lifetime_model_cancel",
    "load_failures",
    "allocation_create",
    "allocation_request",
    "allocation_audio",
    "allocation_snapshot",
)
EXPORTS = {
    "omni_batch_options_default",
    "omni_batch_create",
    "omni_batch_cancel",
    "omni_batch_destroy_checked",
    "omni_batch_request_create",
    "omni_batch_request_cancel",
    "omni_batch_request_drain",
    "omni_batch_request_destroy_checked",
    "omni_batch_transcribe",
    "omni_batch_result_free",
}


@pytest.fixture(scope="session")
def batch_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    compiler = shutil.which(os.environ.get("CXX", "c++"))
    c_compiler = shutil.which(os.environ.get("CC", "cc"))
    if compiler is None or c_compiler is None:
        pytest.skip("C/C++ compilers required")
    else:
        pass
    build = tmp_path_factory.mktemp("native-batch-explicit-backend-stubs")
    for filename in (*SOURCES, "native_batch_worker.h", "transcriber.h") + tuple(
        f"{family}_transcriber.h" for family in FAMILIES
    ):
        source = NATIVE_DIRECTORY / "src" / filename
        shutil.copyfile(source, build / filename)
        assert (build / filename).read_bytes() == source.read_bytes()
    for family in (*FAMILIES, ""):
        filename = f"{family}_model.h" if family else "model.h"
        (build / filename).write_text('#include "model_standins.h"\n')
    # Note (OpenAI): exercise the actual prompt validator without linking MLX kernels.
    moss_source = (NATIVE_DIRECTORY / "src/moss_transcriber.cpp").read_text()
    start = moss_source.index("void ValidatePrompt(")
    end = moss_source.index("\n}\n", start) + 3
    constant = re.search(r"constexpr const char \*kAudioPad = .*;", moss_source)
    assert constant is not None
    (build / "prompt_validator.cpp").write_text(
        '#include "moss_transcriber.h"\nnamespace moss {\n'
        + constant.group()
        + "\n"
        + moss_source[start:end]
        + "\n}\n"
    )
    include_flags = [
        "-I",
        str(NATIVE_DIRECTORY / "include"),
        "-I",
        str(build),
        "-I",
        str(NATIVE_DIRECTORY / "ci/batch_stubs"),
    ]
    json_directory = os.environ.get("NLOHMANN_JSON_INCLUDE_DIR")
    if json_directory:
        include_flags += ["-I", json_directory]
    else:
        pass
    probe = subprocess.run(
        [compiler, "-std=c++20", *include_flags, "-x", "c++", "-E", "-"],
        input="#include <nlohmann/json.hpp>\n",
        text=True,
        capture_output=True,
        timeout=30,
    )
    if probe.returncode != 0:
        pytest.skip(
            "Provision nlohmann/json.hpp via NLOHMANN_JSON_INCLUDE_DIR; no downloads"
        )
    else:
        pass
    flags = ["-Wall", "-Wextra", "-Werror", "-pthread", "-ffp-contract=off"]
    sanitizers = os.environ.get("OMNI_BATCH_SANITIZERS", "")
    if sanitizers:
        flags += [f"-fsanitize={sanitizers}", "-fno-omit-frame-pointer"]
    else:
        pass
    executable_flags = (
        ["-fno-pie", "-no-pie"] if sanitizers and sys.platform == "linux" else []
    )
    source_files = [str(build / filename) for filename in SOURCES] + [
        str(build / "prompt_validator.cpp"),
        str(NATIVE_DIRECTORY / "ci/batch_stubs/backend.cpp"),
    ]
    fault_flags = (
        ["-DOMNI_BATCH_FAULT_WRAP", "-Wl,--wrap=malloc", "-Wl,--wrap=calloc"]
        if sys.platform == "linux"
        else []
    )
    subprocess.run(
        [
            compiler,
            "-std=c++20",
            *flags,
            *include_flags,
            *executable_flags,
            *fault_flags,
            *source_files,
            str(NATIVE_DIRECTORY / "ci/test_native_batch.cpp"),
            str(NATIVE_DIRECTORY / "ci/batch_stubs/lifetime.cpp"),
            str(NATIVE_DIRECTORY / "ci/batch_stubs/bounds.cpp"),
            str(NATIVE_DIRECTORY / "ci/batch_stubs/faults.cpp"),
            "-o",
            str(build / "batch_cases"),
        ],
        check=True,
        timeout=180,
    )
    library_name = "libBatch.dylib" if sys.platform == "darwin" else "libBatch.so"
    library_flags = ["-dynamiclib"] if sys.platform == "darwin" else ["-shared"]
    subprocess.run(
        [
            compiler,
            "-std=c++20",
            *flags,
            *include_flags,
            *library_flags,
            "-fPIC",
            "-fvisibility=hidden",
            *source_files,
            "-o",
            str(build / library_name),
        ],
        check=True,
        timeout=180,
    )
    (build / "client.c").write_text(
        '#include "omni_native_batch.h"\n#include "omni_native_core.h"\n'
        "int main(void) { OmniBatchOptions options; OmniBatchResult result = {0};\n"
        "if (omni_batch_options_default(OMNI_BATCH_COHERE, &options) != OMNI_BATCH_OK) return 1;\n"
        "if (options.family.cohere.chunk_duration_seconds != 1200) return 2;\n"
        "omni_batch_result_free(&result); return omni_batch_destroy_checked(0); }\n"
    )
    subprocess.run(
        [
            c_compiler,
            "-std=c11",
            *flags,
            *include_flags,
            "-c",
            str(build / "client.c"),
            "-o",
            str(build / "client.o"),
        ],
        check=True,
        timeout=30,
    )
    subprocess.run(
        [
            compiler,
            *flags,
            *executable_flags,
            str(build / "client.o"),
            "-L",
            str(build),
            "-lBatch",
            f"-Wl,-rpath,{build}",
            "-o",
            str(build / "c_client"),
        ],
        check=True,
        timeout=30,
    )
    return build


@pytest.mark.parametrize("model_kind", range(1, 7), ids=FAMILIES)
@pytest.mark.parametrize("case", CASES)
def test_real_batch_routes_with_explicit_standins(
    batch_build: Path, tmp_path: Path, model_kind: int, case: str
) -> None:
    if case == "allocation_snapshot" and sys.platform != "linux":
        pytest.skip("snapshot malloc/calloc injection uses Linux linker wrapping")
    else:
        completed = subprocess.run(
            [str(batch_build / "batch_cases"), str(model_kind), case],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert completed.returncode == 0, completed.stdout + completed.stderr
        assert "PRIVATE" not in completed.stderr


def test_batch_c_header_and_linkage(batch_build: Path) -> None:
    subprocess.run([str(batch_build / "c_client")], check=True, timeout=15)


def test_batch_exported_symbols(batch_build: Path) -> None:
    command = (
        ["nm", "-gU", str(batch_build / "libBatch.dylib")]
        if sys.platform == "darwin"
        else ["nm", "-D", "--defined-only", str(batch_build / "libBatch.so")]
    )
    completed = subprocess.run(
        command, check=True, capture_output=True, text=True, timeout=15
    )
    symbols = {
        line.split()[-1].removeprefix("_") for line in completed.stdout.splitlines()
    }
    assert {symbol for symbol in symbols if symbol.startswith("omni_")} == EXPORTS
