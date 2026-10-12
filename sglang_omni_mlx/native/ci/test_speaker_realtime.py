# SPDX-License-Identifier: Apache-2.0
"""Replay two speaker realtime families with CPU-scripted model boundaries."""

from __future__ import annotations

import hashlib
import json
import lzma
import os
import shutil
import subprocess
from pathlib import Path
from typing import Literal

import pytest

Family = Literal["moss", "nemotron"]
Mode = Literal["http", "http_race", "engine", "engine_race"]

NATIVE_DIRECTORY = Path(__file__).resolve().parents[1]
STUB_DIRECTORY = NATIVE_DIRECTORY / "ci/speaker_realtime_stubs"
BASELINE_REVISION = "77a919c577753876bb7cb5331aa1ffa082553d66"
BUILD_TIMEOUT_SECONDS = 180
CASE_TIMEOUT_SECONDS = 20
COMMON_CASES = ("protocol", "empty_finish", "failure", "finish_failure")
MOSS_CASES = COMMON_CASES + (
    "prompt",
    "threshold",
    "preview_tail",
    "windows",
    "backlog_merge",
    "backlog_split",
    "prompt_during_decode",
    "empty_segments",
    "cadence",
)
NEMOTRON_CASES = COMMON_CASES + (
    "chunk_1",
    "chunk_120",
    "chunk_240",
    "chunk_440",
    "chunk_840",
    "chunk_5000",
    "chunk_rounding",
    "settings",
    "pending",
    "failure_no_advance",
    "duplicates",
    "session_limit",
)
HTTP_CASES: tuple[tuple[Family, str], ...] = tuple(
    ("moss", case) for case in MOSS_CASES
) + tuple(("nemotron", case) for case in NEMOTRON_CASES)


def compile_speaker(build: Path, *, baseline: bool) -> Path:
    compiler = shutil.which(os.environ.get("CXX", "clang++"))
    if compiler is None:
        raise RuntimeError(
            "CXX compiler unavailable; install it explicitly (no downloads)"
        )
    else:
        pass
    include_directory = os.environ.get("NLOHMANN_JSON_INCLUDE_DIR")
    include_flags = ["-I", include_directory] if include_directory else []
    sources = [
        "worker.cpp",
        "realtime.cpp",
        "realtime_engine.cpp",
        "moss_realtime.cpp",
        "nemotron_realtime.cpp",
    ]
    if not baseline:
        sources += [
            "moss_realtime_engine.cpp",
            "nemotron_realtime_engine.cpp",
            "speaker_realtime_event.cpp",
        ]
    else:
        pass
    headers = [filename.replace(".cpp", ".h") for filename in sources]
    hashes: dict[str, str] = {}
    original_hashes: dict[str, str] = {}
    for filename in sources + headers:
        if baseline:
            source = subprocess.run(
                [
                    "git",
                    "show",
                    f"{BASELINE_REVISION}:sglang_omni_mlx/native/src/{filename}",
                ],
                cwd=NATIVE_DIRECTORY,
                capture_output=True,
                check=True,
                timeout=30,
            ).stdout
        else:
            source = (NATIVE_DIRECTORY / "src" / filename).read_bytes()
        original_hashes[filename] = hashlib.sha256(source).hexdigest()
        if not baseline and filename == "speaker_realtime_event.cpp":
            # Note (OpenAI): observe sink entry without replacing serializer logic.
            source = source.replace(
                b"SpeakerRealtimeEventJson(", b"UnobservedSpeakerRealtimeEventJson("
            )
        else:
            pass
        (build / filename).write_bytes(source)
        hashes[filename] = hashlib.sha256(source).hexdigest()
    (build / "sources.sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (build / "original-sources.sha256.json").write_text(
        json.dumps(original_hashes, indent=2) + "\n"
    )
    for filename in (
        "audio.h",
        "transcriber.h",
        "moss_transcriber.h",
        "nemotron_transcriber.h",
        "script.h",
    ):
        shutil.copyfile(STUB_DIRECTORY / filename, build / filename)
    flags = ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread"]
    sanitizers = os.environ.get("OMNI_SPEAKER_SANITIZERS", "")
    if sanitizers:
        flags += [f"-fsanitize={sanitizers}", "-fno-omit-frame-pointer"]
    else:
        pass
    test_sources = [
        "script.cpp",
        "utilities.cpp",
        "support.cpp",
        "http_cases.cpp",
        "http_races.cpp",
    ]
    if baseline:
        flags.append("-DSPEAKER_BASELINE")
    else:
        test_sources += [
            "engine_support.cpp",
            "engine_cases.cpp",
            "engine_races.cpp",
            "serialization_observer.cpp",
        ]
    executable = build / "speaker_cases"
    command = [
        compiler,
        *flags,
        *include_flags,
        "-I",
        str(build),
        *(str(build / filename) for filename in sources),
        *(str(STUB_DIRECTORY / filename) for filename in test_sources),
        str(NATIVE_DIRECTORY / "ci/test_speaker_realtime.cpp"),
        "-o",
        str(executable),
    ]
    completed = subprocess.run(
        command, capture_output=True, text=True, timeout=BUILD_TIMEOUT_SECONDS
    )
    (build / "build.log").write_text(completed.stdout + completed.stderr)
    if completed.returncode != 0:
        raise RuntimeError(
            f"CPU fixture build failed; dependencies are not skipped/downloaded:\n{completed.stderr}"
        )
    else:
        return executable


@pytest.fixture(scope="module")
def before_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return compile_speaker(tmp_path_factory.mktemp("speaker-before"), baseline=True)


@pytest.fixture(scope="module")
def after_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return compile_speaker(tmp_path_factory.mktemp("speaker-after"), baseline=False)


def run_case(executable: Path, mode: Mode, family: Family, case: str) -> str:
    completed = subprocess.run(
        [str(executable), mode, family, case],
        capture_output=True,
        text=True,
        timeout=CASE_TIMEOUT_SECONDS,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "PRIVATE" not in completed.stderr, completed.stderr
    return completed.stdout


@pytest.mark.parametrize(("family", "case"), HTTP_CASES)
def test_live_http_parity(
    before_build: Path, after_build: Path, family: Family, case: str
) -> None:
    before = json.loads(run_case(before_build, "http", family, case))
    after = json.loads(run_case(after_build, "http", family, case))
    assert after == before


@pytest.mark.parametrize(("family", "case"), HTTP_CASES)
def test_recorded_http_baseline(after_build: Path, family: Family, case: str) -> None:
    with lzma.open(STUB_DIRECTORY / "baseline.json.xz", "rt") as baseline:
        expected = json.load(baseline)
    assert (
        json.loads(run_case(after_build, "http", family, case))
        == expected[f"{family}/{case}"]
    )


@pytest.mark.parametrize("family", ("moss", "nemotron"))
@pytest.mark.parametrize("case", ("close_waiter", "publication"))
def test_authentic_ordering_difference(
    before_build: Path, after_build: Path, family: Family, case: str
) -> None:
    before = json.loads(run_case(before_build, "http_race", family, case))
    after = json.loads(run_case(after_build, "http_race", family, case))
    assert before["events"] == after["events"]
    if case == "close_waiter":
        assert not before["woke_before_model_return"]
        assert after["woke_before_model_return"]
    else:
        assert before["finish_queued_before_preview_published"] == (
            family == "nemotron"
        )
        assert not after["finish_queued_before_preview_published"]


@pytest.mark.parametrize("family", ("moss", "nemotron"))
@pytest.mark.parametrize(
    "case",
    ("lazy_close", "sender_close", "error_sender_close", "error_sender_close_throws"),
)
def test_http_close_routing(after_build: Path, family: Family, case: str) -> None:
    assert (
        json.loads(run_case(after_build, "http_race", family, case))["passed"] == case
    )


def test_failed_completion_order(before_build: Path, after_build: Path) -> None:
    before = json.loads(
        run_case(before_build, "http_race", "nemotron", "failure_publication")
    )
    after = json.loads(
        run_case(after_build, "http_race", "nemotron", "failure_publication")
    )
    assert before["finish_before_failure_publication"]
    assert not after["finish_before_failure_publication"]
    assert before["calls"] == after["calls"]
    assert before["events"][0]["text"] == after["events"][1]["text"] == ""
    assert before["events"][0]["segments"] == after["events"][1]["segments"] == []
    assert before["events"][1]["error"] == after["events"][0]["error"]


@pytest.mark.parametrize("family", ("moss", "nemotron"))
@pytest.mark.parametrize(
    "case",
    (
        "mapping",
        "float_samples",
        "empty",
        "failure",
        "allocation_failure",
        "settings",
        "finish_once",
    ),
)
def test_typed_engine(after_build: Path, family: Family, case: str) -> None:
    assert json.loads(run_case(after_build, "engine", family, case))["passed"] == case


@pytest.mark.parametrize("case", ("construction_append", "construction_finish"))
def test_stream_construction_failure(after_build: Path, case: str) -> None:
    assert (
        json.loads(run_case(after_build, "engine", "nemotron", case))["passed"] == case
    )


@pytest.mark.parametrize("family", ("moss", "nemotron"))
@pytest.mark.parametrize(
    "case",
    (
        "close_commit",
        "close_finish",
        "close_preview_commit",
        "close_preview_finish",
        "sink_close",
        "active_sink_close",
        "destroy_active",
        "publication",
        "final_close",
        "worker_join",
    ),
)
def test_typed_lifetime(after_build: Path, family: Family, case: str) -> None:
    assert (
        json.loads(run_case(after_build, "engine_race", family, case))["passed"] == case
    )
