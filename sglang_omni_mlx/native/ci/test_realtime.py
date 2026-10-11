# SPDX-License-Identifier: Apache-2.0
"""Replay real realtime/worker code with scripted CPU model/audio stand-ins."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Literal

import pytest

NATIVE_DIRECTORY = Path(__file__).resolve().parents[1]
STUB_DIRECTORY = NATIVE_DIRECTORY / "ci/realtime_stubs"
HEADER_PROBE_TIMEOUT_SECONDS = 30
BUILD_TIMEOUT_SECONDS = 180
CASE_TIMEOUT_SECONDS = 15
HTTP_CASES = (
    "protocol_errors",
    "empty_finish",
    "silent_finish",
    "manual_turns",
    "cadence",
    "automatic_cuts",
    "exact_boundary",
    "language_snapshots",
    "prefix_rollback",
    "prefix_after_failure",
    "decode_failure",
    "blocked_commit",
    "blocked_close",
    "late_success",
)
ENGINE_CASES = (
    "float_samples",
    "empty_silent",
    "cadence_prefix",
    "cuts_languages",
    "failure",
    "blocked_commit",
    "blocked_close",
    "late_success",
    "destroy_active",
    "close_during_commit",
    "close_during_finish",
    "finish_once",
    "sink_close",
    "settings_join",
)


def compile_realtime(build: Path, baseline: Path | None = None) -> Path:
    compiler = shutil.which(os.environ.get("CXX", "c++"))
    if compiler is None:
        pytest.skip("C++ compiler required for CPU realtime stand-in tests")
    else:
        pass
    include_directory = os.environ.get("NLOHMANN_JSON_INCLUDE_DIR")
    include_flags = ["-I", include_directory] if include_directory else []
    probe = subprocess.run(
        [compiler, "-std=c++20", *include_flags, "-x", "c++", "-E", "-"],
        input="#include <nlohmann/json.hpp>\n",
        text=True,
        capture_output=True,
        timeout=HEADER_PROBE_TIMEOUT_SECONDS,
    )
    if probe.returncode != 0:
        pytest.skip(
            "nlohmann/json.hpp unavailable: install nlohmann-json or set "
            "NLOHMANN_JSON_INCLUDE_DIR to its include root (tested with 3.11.3); "
            "tests never download dependencies. " + probe.stderr[-1000:]
        )
    else:
        pass
    sources = ["worker.cpp", "realtime.cpp"]
    headers = ["worker.h", "realtime.h"]
    if baseline is None:
        sources.append("realtime_engine.cpp")
        headers.append("realtime_engine.h")
    else:
        pass
    # Note (OpenAI): byte-identical copies avoid quoted includes selecting MLX.
    for filename in sources + headers:
        source = (
            baseline / f"baseline-{filename}"
            if baseline is not None and filename.startswith("realtime.")
            else NATIVE_DIRECTORY / "src" / filename
        )
        shutil.copyfile(source, build / filename)
    for filename in ("transcriber.h", "audio.h"):
        shutil.copyfile(STUB_DIRECTORY / filename, build / filename)
    flags = ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread"]
    sanitizers = os.environ.get("OMNI_ABI_SANITIZERS", "")
    if sanitizers:
        flags += [f"-fsanitize={sanitizers}", "-fno-omit-frame-pointer"]
        if sys.platform == "linux":
            # Note (OpenAI): non-PIE avoids GCC ASan shadow/ASLR startup collisions.
            flags += ["-fno-pie", "-no-pie"]
        else:
            pass
    else:
        pass
    test_sources = ["backend.cpp", "support.cpp", "http_cases.cpp"]
    if baseline is None:
        test_sources.append("engine_cases.cpp")
    else:
        flags.append("-DOMNI_REALTIME_BASELINE")
    executable = build / "realtime_cases"
    subprocess.run(
        [
            compiler,
            *flags,
            *include_flags,
            "-I",
            str(build),
            *(str(build / filename) for filename in sources),
            *(str(STUB_DIRECTORY / filename) for filename in test_sources),
            str(NATIVE_DIRECTORY / "ci/test_realtime.cpp"),
            "-o",
            str(executable),
        ],
        check=True,
        timeout=BUILD_TIMEOUT_SECONDS,
    )
    return executable


@pytest.fixture(scope="module")
def realtime_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return compile_realtime(tmp_path_factory.mktemp("realtime-cpu-stand-ins"))


@pytest.fixture(scope="module")
def baseline_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    directory = os.environ.get("OMNI_REALTIME_BASELINE_DIR")
    if directory is None:
        pytest.skip(
            "Live BEFORE replay needs OMNI_REALTIME_BASELINE_DIR containing "
            "baseline-realtime.cpp/h; AFTER still checks recorded baseline outputs"
        )
    else:
        return compile_realtime(
            tmp_path_factory.mktemp("realtime-baseline-cpu-stand-ins"), Path(directory)
        )


def run_case(executable: Path, mode: Literal["http", "engine"], case: str) -> str:
    completed = subprocess.run(
        [str(executable), mode, case],
        capture_output=True,
        text=True,
        timeout=CASE_TIMEOUT_SECONDS,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "PRIVATE" not in completed.stderr, completed.stderr
    return completed.stdout


@pytest.mark.parametrize("case", HTTP_CASES)
def test_http_against_recorded_baseline(realtime_build: Path, case: str) -> None:
    expected = json.loads((STUB_DIRECTORY / "baseline_outputs.json").read_text())
    actual = json.loads(run_case(realtime_build, "http", case))
    assert actual == expected[case]
    assert [event["event_index"] for event in actual["events"]] == list(
        range(1, len(actual["events"]) + 1)
    )


@pytest.mark.parametrize("case", HTTP_CASES)
def test_live_before_after_replay(
    baseline_build: Path, realtime_build: Path, case: str
) -> None:
    before = json.loads(run_case(baseline_build, "http", case))
    after = json.loads(run_case(realtime_build, "http", case))
    expected = json.loads((STUB_DIRECTORY / "baseline_outputs.json").read_text())
    assert before == expected[case]
    assert after == before


@pytest.mark.parametrize("case", ENGINE_CASES)
def test_transport_free_float_engine(realtime_build: Path, case: str) -> None:
    assert json.loads(run_case(realtime_build, "engine", case))["passed"] == case
