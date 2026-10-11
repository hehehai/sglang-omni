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
    "silero_offline_directories",
    "silero_offline_inputs",
    "silero_offline_settings",
    "silero_offline_settings_mapping",
    "silero_offline_padding_ownership",
    "silero_offline_single_use",
    "silero_stream_invalid",
    "silero_stream_sequence_padding",
    "silero_stream_isolation",
    "silero_stream_continual",
    "silero_stream_limit",
    "silero_stream_ownership",
    "silero_lifecycle_request_cancel",
    "silero_lifecycle_request_destroy",
    "silero_lifecycle_offline_model_cancel",
    "silero_lifecycle_offline_model_destroy",
    "silero_lifecycle_stream_cancel",
    "silero_lifecycle_finish_cancel",
    "silero_lifecycle_stream_model_cancel",
    "silero_lifecycle_stream_model_destroy",
    "silero_lifecycle_queued_cancel",
    "silero_lifecycle_queued_offline_cancel",
    "silero_lifecycle_cancel_before",
    "silero_failure_exceptions",
    "silero_failure_probabilities",
    "silero_failure_allocation",
    "silero_failure_serialized_admission",
)


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
        "native_error.h",
        "native_silero.cpp",
        "native_silero_stream.cpp",
        "native_silero_worker.cpp",
        "native_silero_worker.h",
        "silero_timestamps.h",
        "silero_vad.h",
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
    include_flags = [
        "-I",
        str(NATIVE_DIRECTORY / "include"),
        "-I",
        str(build),
        "-I",
        str(NATIVE_DIRECTORY / "ci/native_core_stubs"),
    ]
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
            str(build / "native_silero.cpp"),
            str(build / "native_silero_stream.cpp"),
            str(build / "native_silero_worker.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/silero_backend.cpp"),
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
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/silero_offline_cases.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/silero_stream_cases.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/silero_lifecycle_cases.cpp"),
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/silero_failure_cases.cpp"),
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
    subprocess.run(
        [
            c_compiler,
            "-std=c11",
            *common_flags,
            *include_flags,
            "-c",
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/client.c"),
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
    subprocess.run(
        [
            compiler,
            "-std=c++20",
            *common_flags,
            *include_flags,
            *executable_flags,
            str(NATIVE_DIRECTORY / "ci/native_core_stubs/silero_timestamp_cases.cpp"),
            "-o",
            str(build / "timestamp_cases"),
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
            "silero_failure_allocation",
            "silero_failure_serialized_admission",
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


@pytest.mark.parametrize(
    "case",
    ("empty_threshold", "duration_clipping", "silence_hysteresis", "padding_merge"),
)
def test_real_pure_timestamp_algorithm(abi_build: Path, case: str) -> None:
    subprocess.run([str(abi_build / "timestamp_cases"), case], check=True, timeout=15)


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
        "omni_silero_create",
        "omni_silero_cancel",
        "omni_silero_destroy",
        "omni_silero_request_create",
        "omni_silero_request_cancel",
        "omni_silero_request_destroy",
        "omni_silero_speech_timestamps",
        "omni_silero_result_free",
        "omni_silero_stream_create",
        "omni_silero_stream_push",
        "omni_silero_stream_finish",
        "omni_silero_stream_cancel",
        "omni_silero_stream_drain",
        "omni_silero_stream_destroy",
        "omni_silero_stream_result_free",
    }
