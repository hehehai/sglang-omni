# SPDX-License-Identifier: Apache-2.0
"""Exercise actual bounded native speaker APIs with scripted CPU model boundaries."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from sglang_omni_mlx.native.ci.native_speaker_stubs.cases import CASES, EXPORTS

NATIVE = Path(__file__).resolve().parents[1]
STUBS = NATIVE / "ci/native_speaker_stubs"
BASELINE = "402474eb04e21f299925b832506668a0a7d5e506"
ENGINES = ("worker.cpp", "moss_realtime_engine.cpp", "nemotron_realtime_engine.cpp")
WRAPPERS = (
    "native_speaker_commands.cpp",
    "native_speaker_events.cpp",
    "native_speaker_lifetime.cpp",
    "native_speaker_validation.cpp",
)


def execute(
    command: list[str], directory: Path, log_name: str, timeout_seconds: int = 180
) -> str:
    (directory / f"{log_name}.command.json").write_text(json.dumps(command) + "\n")
    completed = subprocess.run(
        command, cwd=directory, capture_output=True, text=True, timeout=timeout_seconds
    )
    (directory / f"{log_name}.log").write_text(completed.stdout + completed.stderr)
    assert (
        completed.returncode == 0
    ), f"{log_name}: {completed.stdout}{completed.stderr}"
    return completed.stdout


def snapshot_sources(build: Path, *, baseline: bool) -> list[Path]:
    names = (
        ENGINES
        + tuple(name.replace(".cpp", ".h") for name in ENGINES)
        + (
            "speaker_realtime_event.h",
            "transcriber.h",
            "moss_transcriber.h",
            "nemotron_transcriber.h",
            "transcriber.cpp",
            "moss_transcriber.cpp",
        )
        + (() if baseline else WRAPPERS + ("native_speaker_state.h",))
    )
    originals: dict[str, str] = {}
    source_text: dict[str, str] = {}
    for name in names:
        if baseline:
            original = subprocess.run(
                ["git", "show", f"{BASELINE}:sglang_omni_mlx/native/src/{name}"],
                cwd=NATIVE,
                capture_output=True,
                check=True,
                timeout=30,
            ).stdout
        else:
            original = (NATIVE / "src" / name).read_bytes()
        originals[name] = hashlib.sha256(original).hexdigest()
        source_text[name] = original.decode()
        (build / name).write_bytes(original)
    options = "#pragma once\n#include <optional>\n#include <string>\n"
    for family, declaration in (
        ("moss", "MossOptions"),
        ("nemotron", "NemotronOptions"),
    ):
        text = source_text[f"{family}_transcriber.h"]
        start = text.index(f"struct {declaration} {{")
        options += (
            f"namespace {family} {{\n"
            + text[start : text.index("\n};", start) + 3]
            + "\n}\n"
        )
    (build / "model_options.h").write_text(options)
    for name in ("audio.h", "moss_transcriber.h", "nemotron_transcriber.h", "script.h"):
        shutil.copyfile(STUBS / name, build / name)
    (build / "model.h").write_text(
        "#pragma once\nnamespace qwen3_asr { class Qwen3ASR {}; }\n"
    )
    (build / "tokenizer.h").write_text(
        "#pragma once\nnamespace qwen3_asr { class Tokenizer {}; }\n"
    )
    transcriber = source_text["transcriber.cpp"]
    utilities = (
        '#include "transcriber.h"\n#include "moss_transcriber.h"\n'
        "static_assert(NLOHMANN_JSON_VERSION_MAJOR == 3 && NLOHMANN_JSON_VERSION_MINOR == 11 && NLOHMANN_JSON_VERSION_PATCH == 3);\n"
        "namespace qwen3_asr {\n"
    )
    utilities += (
        transcriber[
            transcriber.index("bool IsUnicodeSpace(") : transcriber.index(
                "bool IsTokenLoop("
            )
        ]
        + "\n}\nnamespace moss {\n"
    )
    moss = source_text["moss_transcriber.cpp"]
    constant = re.search(r"constexpr const char \*kAudioPad = .*;", moss)
    assert constant is not None
    start = moss.index("void ValidatePrompt(")
    utilities += (
        constant.group() + "\n" + moss[start : moss.index("\n}\n", start) + 3] + "\n}\n"
    )
    (build / "actual_utilities.cpp").write_text(utilities)
    if not baseline:
        worker = source_text["worker.cpp"]
        load_entry = "  try {\n    load();"
        assert worker.count(load_entry) == 1
        (build / "worker.cpp").write_text(
            '#include "script.h"\n'
            + worker.replace(
                load_entry,
                '  native_test::observe_thread("worker.load");\n' + load_entry,
            )
        )
        for family, engine in (
            ("moss", "MossRealtimeEngine"),
            ("nemotron", "NemotronRealtimeEngine"),
        ):
            filename = f"{family}_realtime_engine.cpp"
            text = source_text[filename]
            constructor = "cancel_(std::move(cancel)) {}"
            assert text.count(constructor) == 1
            text = '#include "script.h"\n' + text.replace(
                constructor,
                'cancel_(std::move(cancel)) { native_test::observe_thread("engine.construct"); }',
            )
            destructor = f"{engine}::~{engine}() {{ Close(); }}"
            assert text.count(destructor) == 1
            text = text.replace(
                destructor,
                f'{engine}::~{engine}() {{ native_test::observe_thread("engine.destroy"); Close(); }}',
            )
            checkpoint = (
                "const std::shared_ptr<MossRealtimeEngine> self = weak_self.lock();"
                if family == "moss"
                else "std::exception_ptr error, bool final) {"
            )
            assert text.count(checkpoint) == 1
            replacement = (
                "native_test::CallbackObservation observation;\n" + checkpoint
                if family == "moss"
                else checkpoint + "\n  native_test::CallbackObservation observation;"
            )
            text = text.replace(checkpoint, replacement)
            finish_entry = f"void {engine}::Finish() {{"
            assert text.count(finish_entry) == 1
            text = text.replace(
                finish_entry, finish_entry + "\n  native_test::finish_checkpoint();"
            )
            sink_call = "sink_(event);" if family == "moss" else "event_sink_(event);"
            assert text.count(sink_call) == 1
            text = text.replace(
                sink_call,
                "native_test::sink_checkpoint(std::holds_alternative<qwen3_asr::SpeakerRealtimeSegment>(event));\n    "
                + sink_call,
            )
            (build / filename).write_text(text)
    else:
        pass
    (build / "original-sources.sha256.json").write_text(
        json.dumps(originals, indent=2) + "\n"
    )
    (build / "compiled-sources.sha256.json").write_text(
        json.dumps(
            {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in build.iterdir()
                if path.suffix in (".cpp", ".h")
            },
            indent=2,
        )
        + "\n"
    )
    return [build / name for name in ENGINES + (() if baseline else WRAPPERS)] + [
        build / "actual_utilities.cpp",
        STUBS / "script.cpp",
    ]


@pytest.fixture(scope="session")
def native_build(tmp_path_factory: pytest.TempPathFactory) -> Path:
    compiler = shutil.which(os.environ.get("CXX", "g++"))
    c_compiler = shutil.which(os.environ.get("CC", "gcc"))
    assert compiler and c_compiler, "Provision C/C++ compilers explicitly; no downloads"
    json_directory = os.environ.get("NLOHMANN_JSON_INCLUDE_DIR")
    assert (
        json_directory
    ), "Set NLOHMANN_JSON_INCLUDE_DIR to locally installed nlohmann 3.11.3"
    artifact_directory = os.environ.get("OMNI_NATIVE_SPEAKER_ARTIFACTS")
    build = (
        Path(artifact_directory)
        if artifact_directory
        else tmp_path_factory.mktemp("native-speaker")
    )
    build.mkdir(parents=True, exist_ok=True)
    test_hashes = {
        str(path.relative_to(NATIVE)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [
            *STUBS.iterdir(),
            NATIVE / "ci/test_native_speaker.py",
            NATIVE / "ci/test_native_speaker.cpp",
        ]
        if path.is_file()
    }
    (build / "test-sources.sha256.json").write_text(
        json.dumps(test_hashes, indent=2) + "\n"
    )
    before = build / "before"
    before.mkdir(exist_ok=True)
    sources = snapshot_sources(build, baseline=False)
    baseline_sources = snapshot_sources(before, baseline=True)
    for name in ("omni_native_speaker.h", "omni_native_batch.h", "omni_native_core.h"):
        shutil.copyfile(NATIVE / "include" / name, build / name)
    flags = [
        "-std=c++20",
        "-pthread",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-ffp-contract=off",
    ]
    sanitizers = os.environ.get("OMNI_NATIVE_SPEAKER_SANITIZERS", "")
    if sanitizers:
        flags += [f"-fsanitize={sanitizers}", "-fno-omit-frame-pointer"]
    else:
        pass
    executable_flags = ["-fno-pie", "-no-pie"] if sanitizers else []
    includes = ["-I", str(build), "-I", json_directory, "-I", str(STUBS)]
    test_sources = [
        STUBS / name
        for name in (
            "support.cpp",
            "protocol.cpp",
            "validation.cpp",
            "outputs.cpp",
            "lifetime.cpp",
            "faults.cpp",
        )
    ]
    execute(
        [
            compiler,
            *flags,
            *executable_flags,
            *includes,
            "-DOMNI_SPEAKER_FAULT_WRAP",
            "-Wl,--wrap=malloc",
            "-Wl,--wrap=calloc",
            *(str(path) for path in sources + test_sources),
            str(NATIVE / "ci/test_native_speaker.cpp"),
            "-o",
            str(build / "cases"),
        ],
        build,
        "build-cases",
    )
    execute(
        [
            compiler,
            *flags,
            *executable_flags,
            "-I",
            str(before),
            "-I",
            json_directory,
            "-I",
            str(STUBS),
            *(str(path) for path in baseline_sources),
            str(STUBS / "control.cpp"),
            "-o",
            str(build / "control"),
        ],
        build,
        "build-control",
    )
    execute(
        [
            compiler,
            *flags,
            *includes,
            "-shared",
            "-fPIC",
            "-fvisibility=hidden",
            *(str(path) for path in sources),
            "-o",
            str(build / "libSpeaker.so"),
        ],
        build,
        "build-shared",
    )
    c_flags = [flag for flag in flags if flag != "-std=c++20"]
    execute(
        [
            c_compiler,
            "-std=c11",
            *c_flags,
            "-I",
            str(build),
            "-c",
            str(STUBS / "client.c"),
            "-o",
            str(build / "client.o"),
        ],
        build,
        "build-c-client",
    )
    execute(
        [
            compiler,
            *flags,
            *executable_flags,
            str(build / "client.o"),
            "-L",
            str(build),
            "-lSpeaker",
            "-ldl",
            f"-Wl,-rpath,{build}",
            "-o",
            str(build / "c-client"),
        ],
        build,
        "link-c-client",
    )
    assert all(
        hashlib.sha256((NATIVE / name).read_bytes()).hexdigest() == digest
        for name, digest in test_hashes.items()
    ), "Test sources changed during fixture build"
    execute([compiler, "--version"], build, "compiler-version")
    (build / "public-headers.sha256.json").write_text(
        json.dumps(
            {
                name: hashlib.sha256((build / name).read_bytes()).hexdigest()
                for name in (
                    "omni_native_speaker.h",
                    "omni_native_batch.h",
                    "omni_native_core.h",
                )
            },
            indent=2,
        )
        + "\n"
    )
    return build


@pytest.mark.parametrize(("kind", "category", "case"), CASES)
def test_actual_native_contract(
    native_build: Path, kind: int, category: str, case: str
) -> None:
    output = execute(
        [str(native_build / "cases"), str(kind), category, case],
        native_build,
        f"{kind}-{category}-{case}",
        20,
    )
    assert json.loads(output)["passed"] == case
    assert "PRIVATE" not in (native_build / f"{kind}-{category}-{case}.log").read_text()


@pytest.mark.parametrize("kind", (1, 2))
@pytest.mark.parametrize(
    ("case", "allocation_index"),
    tuple((case, index) for case in ("create", "stream") for index in range(24))
    + tuple(("poll", index) for index in range(12))
    + (("push", 0), ("destroy", 0), ("cancel_terminal", 0)),
)
def test_controlled_allocation_failure(
    native_build: Path, kind: int, case: str, allocation_index: int
) -> None:
    output = execute(
        [str(native_build / "cases"), str(kind), "fault", case, str(allocation_index)],
        native_build,
        f"{kind}-fault-{case}-{allocation_index}",
        20,
    )
    assert json.loads(output)["passed"] == case


@pytest.mark.parametrize("kind", (1, 2))
@pytest.mark.parametrize("settings", ("default", "custom"))
def test_original_typed_engine_parity(
    native_build: Path, kind: int, settings: str
) -> None:
    before = execute(
        [str(native_build / "control"), str(kind), settings],
        native_build,
        f"{kind}-control-{settings}",
        20,
    )
    after = execute(
        [str(native_build / "cases"), str(kind), "trace", settings],
        native_build,
        f"{kind}-native-{settings}",
        20,
    )
    assert json.loads(after) == json.loads(before)


def test_standalone_c_header_and_thirteen_dlsym_exports(native_build: Path) -> None:
    execute(
        [str(native_build / "c-client"), str(native_build / "libSpeaker.so")],
        native_build,
        "c-client",
        20,
    )
    symbols = execute(
        ["nm", "-D", "--defined-only", str(native_build / "libSpeaker.so")],
        native_build,
        "exports",
        20,
    )
    assert {
        line.split()[-1]
        for line in symbols.splitlines()
        if line.split()[-1].startswith("omni_")
    } == EXPORTS


def test_main_epoch_source_not_fixture_shim() -> None:
    source = (NATIVE / "src/native_core.cpp").read_text()
    assert re.search(
        r"unsigned int omni_core_abi_version\(void\)\s*\{\s*return 8;\s*\}", source
    )
    assert (
        '#include "omni_native_speaker.h"'
        in (NATIVE / "include/omni_native_core.h").read_text()
    )
