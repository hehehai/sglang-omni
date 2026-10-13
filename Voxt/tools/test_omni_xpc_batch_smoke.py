"""Exercise the embedded smoke transaction with filesystem fixtures and no NSXPC."""

import ast
from contextlib import redirect_stderr, redirect_stdout
import io
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid
import wave


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "tools/run_omni_xpc_smoke.sh").read_text()
EMBEDDED = SCRIPT.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
BATCH_FIELDS = (
    "VOXT_OMNI_XPC_SMOKE_BATCH_KIND",
    "VOXT_OMNI_XPC_SMOKE_BATCH_MODEL_SOURCE",
    "VOXT_OMNI_XPC_SMOKE_BATCH_EXPECTED_SOURCE",
)
SPEAKER_FIELDS = (
    "VOXT_OMNI_XPC_SMOKE_SPEAKER_KIND",
    "VOXT_OMNI_XPC_SMOKE_SPEAKER_MODEL_SOURCE",
    "VOXT_OMNI_XPC_SMOKE_SPEAKER_EXPECTED_SOURCE",
)
RUN_ID = uuid.UUID("cb728617-c095-4c80-8a6f-eb73619755cd")


class OmniXPCBatchSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.container = self.root / "container"
        self.container.mkdir()
        self.sources = [self.root / name for name in ("qwen", "silero", "sortformer", "batch")]
        for source in self.sources:
            source.mkdir()
            (source / "config.json").write_text("{}")
        self.expected = self.root / "expected.txt"
        self.expected.write_text("explicit baseline fixture\n", encoding="utf-8")
        self.batch_expected = self.root / "batch.txt"
        self.batch_expected.write_text("explicit batch fixture é\n", encoding="utf-8")
        self.audio = self.root / "input.wav"
        with wave.open(str(self.audio), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\x01\x00" * 160)
        self.executable = str(self.root / "Signed.app/Contents/MacOS/Voxt")
        self.modes: list[str] = []
        self.environments: list[dict[str, str]] = []
        self.report_changes: dict[str, int | str | None] = {}
        self.stage_status = "prepared"
        self.process_failure_mode: str | None = None
        self.batch_artifact: bytes | None = None
        self.output = io.StringIO()
        self.errors = io.StringIO()
        self.ambient = {
            "PATH": "/test/bin", "DYLD_INSERT_LIBRARIES": "untrusted", "__XPC_DYLD_LIBRARY_PATH": "untrusted",
            "VOXT_OMNI_RUNTIME": "untrusted", "VOXT_ASR_BACKEND": "untrusted", "MLX_METAL_PATH": "untrusted",
            "VOXT_OMNI_XPC_SMOKE_MODE": "untrusted", "VOXT_OMNI_XPC_SMOKE_RUN_ID": "untrusted",
            "VOXT_OMNI_XPC_SMOKE_MODEL_SOURCE": "untrusted", "VOXT_OMNI_XPC_SMOKE_MAX_TOKENS": "untrusted",
            "VOXT_OMNI_XPC_SMOKE_LANGUAGE": "untrusted", "VOXT_OMNI_XPC_SMOKE_BATCH_DIRECTORY": "untrusted",
        }
        self.batch_environment = dict(zip(BATCH_FIELDS, ("1", str(self.sources[3]), str(self.batch_expected))))
        self.artifacts = self.container / "OmniXPCSmoke" / str(RUN_ID).upper()
        self.batch_destination = self.container / "Models/OmniXPCBatchSmoke" / str(RUN_ID).upper()
        self.unrelated = self.container / "Models/Unrelated/keep.txt"
        self.unrelated.parent.mkdir(parents=True)
        self.unrelated.write_text("must survive")

    def signed_app_subprocess(
        self, arguments: list[str], *, env: dict[str, str], stdout: int, stderr: int,
        text: bool, timeout: int, check: bool,
    ) -> subprocess.CompletedProcess[str]:
        self.assertEqual(arguments, [self.executable])
        self.assertEqual((stdout, stderr, text, timeout, check), (subprocess.PIPE, subprocess.PIPE, True, 600, False))
        mode = env["VOXT_OMNI_XPC_SMOKE_MODE"]
        self.modes.append(mode)
        self.environments.append(env)
        if mode == "prepare":
            report = {"status": "prepared", "abi_version": 10, "group_container": str(self.container)}
        elif mode == "stage":
            self.assertTrue(self.artifacts.is_dir())
            for source_field, collection in (
                ("VOXT_OMNI_XPC_SMOKE_MODEL_SOURCE", "OmniXPCSmoke"),
                ("VOXT_OMNI_XPC_SMOKE_SILERO_SOURCE", "OmniXPCSileroSmoke"),
                ("VOXT_OMNI_XPC_SMOKE_SORTFORMER_SOURCE", "OmniXPCSortformerSmoke"),
                (BATCH_FIELDS[1], "OmniXPCBatchSmoke"),
                (SPEAKER_FIELDS[1], "OmniXPCSpeakerSmoke"),
            ):
                if source_field in env:
                    self.assertTrue(Path(env[source_field]).is_dir())
                    destination = self.container / "Models" / collection / env["VOXT_OMNI_XPC_SMOKE_RUN_ID"]
                    destination.mkdir(parents=True)
                    (destination / "stub-publication.txt").write_text("No model copying or Native execution in this test.")
                else:
                    pass
            report = {"status": self.stage_status, "abi_version": 10}
        else:
            self.assertEqual(mode, "infer")
            self.assertEqual((self.artifacts / "expected.txt").read_text(), "explicit baseline fixture")
            self.assertEqual((self.artifacts / "audio.f32").stat().st_size, 160 * 4)
            report = {
                "status": "passed", "first_service_process_id": 1, "restarted_service_process_id": 2,
                "silero_request_count": 4, "silero_stream_count": 2,
                "sortformer_stream_count": 6, "sortformer_caller_count": 2,
            }
            if BATCH_FIELDS[0] in env:
                self.batch_artifact = (self.artifacts / "batch-expected.txt").read_bytes()
                report.update(batch_kind=int(env[BATCH_FIELDS[0]]), batch_request_count=4, batch_caller_count=2)
            else:
                self.assertFalse((self.artifacts / "batch-expected.txt").exists())
            if SPEAKER_FIELDS[0] in env:
                self.assertEqual((self.artifacts / "speaker-expected.txt").read_bytes(), self.batch_expected.read_bytes())
                report.update(speaker_kind=int(env[SPEAKER_FIELDS[0]]), speaker_session_count=2, speaker_caller_count=2)
            else:
                self.assertFalse((self.artifacts / "speaker-expected.txt").exists())
            report.update(self.report_changes)
        return subprocess.CompletedProcess(
            arguments, 1 if mode == self.process_failure_mode else 0,
            stdout="VOXT_OMNI_XPC_RESULT " + json.dumps(report) + "\n", stderr="",
        )

    def execute(self, environment: dict[str, str], argument_count: int = 4) -> None:
        arguments = ["-", self.executable, str(self.sources[0]), str(self.audio), str(self.expected),
                     str(self.sources[1]) if argument_count >= 5 else "",
                     str(self.sources[2]) if argument_count == 6 else ""]
        with patch.dict(os.environ, self.ambient | environment, clear=True), patch.object(sys, "argv", arguments), \
             patch("subprocess.run", side_effect=self.signed_app_subprocess), patch("uuid.uuid4", return_value=RUN_ID), \
             redirect_stdout(self.output), redirect_stderr(self.errors):
            exec(compile(EMBEDDED, "run_omni_xpc_smoke.sh:embedded", "exec"), {})

    def test_original_four_five_six_arguments_without_batch(self) -> None:
        for argument_count in (4, 5, 6):
            with self.subTest(argument_count=argument_count):
                self.modes.clear()
                self.environments.clear()
                self.execute({}, argument_count)
                self.assertEqual(self.modes, ["prepare", "stage", "infer"])
                self.assertFalse(self.artifacts.exists())
                for environment in self.environments:
                    self.assertFalse(set(BATCH_FIELDS) & environment.keys())
                    self.assertNotIn("untrusted", environment.values())
                report = json.loads(self.output.getvalue().splitlines()[-1])
                self.assertNotIn("batch_kind", report)
                self.assertNotIn("batch_request_count", report)
                self.assertNotIn("batch_caller_count", report)
                self.assertEqual(self.unrelated.read_text(), "must survive")

    def test_all_six_explicit_kinds_whitelisted_transaction_and_cleanup(self) -> None:
        for kind in range(1, 7):
            with self.subTest(kind=kind):
                self.modes.clear()
                self.environments.clear()
                self.batch_environment[BATCH_FIELDS[0]] = str(kind)
                self.execute(self.batch_environment, 6)
                self.assertEqual(self.modes, ["prepare", "stage", "infer"])
                self.assertEqual(self.batch_artifact, self.batch_expected.read_bytes())
                self.assertFalse(self.artifacts.exists())
                self.assertFalse(self.batch_destination.exists())
                self.assertEqual(self.unrelated.read_text(), "must survive")
                for environment in self.environments:
                    self.assertNotIn("untrusted", environment.values())
                    self.assertEqual({field: environment[field] for field in BATCH_FIELDS}, self.batch_environment)
                report = json.loads(self.output.getvalue().splitlines()[-1])
                self.assertEqual((report["batch_kind"], report["batch_request_count"], report["batch_caller_count"]), (kind, 4, 2))

    def test_partial_empty_and_malformed_configuration_fails_before_any_app(self) -> None:
        configurations = []
        for count in (1, 2):
            for fields in itertools.combinations(BATCH_FIELDS, count):
                configurations.append({field: self.batch_environment[field] for field in fields})
        for field in BATCH_FIELDS:
            configurations.append(self.batch_environment | {field: ""})
        for kind in ("0", "7", "-1", "01", "+1", " 1", "1 ", "1.0", "whisper", "١", "1\n"):
            configurations.append(self.batch_environment | {BATCH_FIELDS[0]: kind})
        configurations.extend([
            self.batch_environment | {BATCH_FIELDS[1]: str(self.expected)},
            self.batch_environment | {BATCH_FIELDS[1]: str(self.root / "missing")},
            self.batch_environment | {BATCH_FIELDS[2]: str(self.sources[0])},
            self.batch_environment | {BATCH_FIELDS[2]: str(self.root / "missing")},
        ])
        for environment in configurations:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                self.execute(environment)
        self.assertEqual(self.modes, [])
        self.assertFalse(self.artifacts.exists())

    def test_expected_utf8_nonempty_and_byte_limit(self) -> None:
        for contents in (b"", b" \n\t", b"\xff", b"a" * 65_537, "é".encode() * 32_769):
            self.batch_expected.write_bytes(contents)
            with self.subTest(byte_count=len(contents)), self.assertRaises(ValueError):
                self.execute(self.batch_environment)
        self.assertEqual(self.modes, [])
        self.batch_expected.write_bytes("é".encode() * 32_768)
        self.execute(self.batch_environment)
        self.assertEqual(len(self.batch_artifact), 65_536)

    def test_bad_report_keeps_all_staged_fixtures(self) -> None:
        self.report_changes = {"batch_request_count": 3}
        with self.assertRaisesRegex(RuntimeError, "batch owner"):
            self.execute(self.batch_environment, 6)
        self.assertEqual(self.modes, ["prepare", "stage", "infer"])
        self.assertTrue(self.batch_destination.is_dir())
        self.assertTrue(self.artifacts.is_dir())
        self.assertIn(str(self.batch_destination), self.errors.getvalue())
        self.assertTrue((self.container / "Models/OmniXPCSortformerSmoke" / str(RUN_ID).upper()).is_dir())

    def test_failed_stage_never_runs_inference_or_removes_fixtures(self) -> None:
        self.stage_status = "failed"
        with self.assertRaisesRegex(RuntimeError, "model preparation"):
            self.execute(self.batch_environment)
        self.assertEqual(self.modes, ["prepare", "stage"])
        self.assertTrue(self.batch_destination.is_dir())
        self.assertTrue((self.artifacts / "batch-expected.txt").is_file())

    def test_failed_process_retains_fixtures(self) -> None:
        self.process_failure_mode = "infer"
        with self.assertRaisesRegex(RuntimeError, "process failed"):
            self.execute(self.batch_environment)
        self.assertTrue(self.batch_destination.is_dir())
        self.assertTrue(self.artifacts.is_dir())

    def test_destination_escape_rejected_before_stage(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (self.container / "Models/OmniXPCBatchSmoke").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "outside the shared container"):
            self.execute(self.batch_environment)
        self.assertEqual(self.modes, ["prepare"])
        self.assertFalse(self.artifacts.exists())

    def test_actual_batch_report_guard(self) -> None:
        guard = next(statement for statement in ast.parse(EMBEDDED).body
                     if isinstance(statement, ast.Try)).body
        guard = next(statement for statement in guard if isinstance(statement, ast.If)
                     and "batch_kind is not None" in ast.unparse(statement.test))
        compiled = compile(ast.Module(body=[guard], type_ignores=[]), "batch-report-guard", "exec")
        for kind in range(1, 7):
            report = {"batch_kind": kind, "batch_request_count": 4, "batch_caller_count": 2}
            exec(compiled, {"batch_kind": kind, "report": report})
            for field, values in (
                ("batch_kind", (None, "1", True, 0, 7)),
                ("batch_request_count", (None, "4", 0, 2, 5)),
                ("batch_caller_count", (None, "2", 0, 1, 3)),
            ):
                for value in values:
                    with self.subTest(kind=kind, field=field, value=value), self.assertRaises(RuntimeError):
                        exec(compiled, {"batch_kind": kind, "report": report | {field: value}})
        exec(compiled, {"batch_kind": None, "report": {}})

    def test_speaker_kinds_and_combined_explicit_batch_transaction(self) -> None:
        for kind in ("1", "2"):
            with self.subTest(kind=kind):
                environment = dict(zip(SPEAKER_FIELDS, (kind, str(self.sources[3]), str(self.batch_expected))))
                self.execute(environment | self.batch_environment, 6)
                report = json.loads(self.output.getvalue().splitlines()[-1])
                self.assertEqual((report["speaker_kind"], report["speaker_session_count"], report["speaker_caller_count"]), (int(kind), 2, 2))
                self.assertFalse((self.container / "Models/OmniXPCSpeakerSmoke" / str(RUN_ID).upper()).exists())
                self.assertFalse(self.artifacts.exists())
                self.assertEqual(self.unrelated.read_text(), "must survive")

    def test_speaker_invalid_inputs_fail_before_any_app(self) -> None:
        environment = dict(zip(SPEAKER_FIELDS, ("1", str(self.sources[3]), str(self.batch_expected))))
        invalid = [{field: environment[field]} for field in SPEAKER_FIELDS]
        invalid += [environment | {SPEAKER_FIELDS[0]: kind} for kind in ("0", "3", "01", "+1", "١", "moss", "1 ")]
        invalid += [environment | {field: ""} for field in SPEAKER_FIELDS]
        for supplied in invalid:
            with self.subTest(supplied=supplied), self.assertRaises(ValueError):
                self.execute(supplied)
        for contents in (b"", b" \n", b"\xff", b"a" * 65_537):
            self.batch_expected.write_bytes(contents)
            with self.subTest(contents_length=len(contents)), self.assertRaises(ValueError):
                self.execute(environment)
        self.assertEqual(self.modes, [])

    def test_speaker_failed_report_keeps_nonce_model_and_expected_snapshot(self) -> None:
        environment = dict(zip(SPEAKER_FIELDS, ("2", str(self.sources[3]), str(self.batch_expected))))
        self.report_changes = {"speaker_session_count": 1}
        with self.assertRaisesRegex(RuntimeError, "speaker streaming"):
            self.execute(environment)
        self.assertTrue((self.container / "Models/OmniXPCSpeakerSmoke" / str(RUN_ID).upper()).is_dir())
        self.assertTrue((self.artifacts / "speaker-expected.txt").is_file())

    def test_speaker_destination_escape_rejects_before_stage(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (self.container / "Models/OmniXPCSpeakerSmoke").symlink_to(outside, target_is_directory=True)
        environment = dict(zip(SPEAKER_FIELDS, ("1", str(self.sources[3]), str(self.batch_expected))))
        with self.assertRaisesRegex(RuntimeError, "outside the shared container"):
            self.execute(environment)
        self.assertEqual(self.modes, ["prepare"])

    def test_actual_speaker_report_guard(self) -> None:
        statements = next(statement for statement in ast.parse(EMBEDDED).body if isinstance(statement, ast.Try)).body
        guard = next(statement for statement in statements if isinstance(statement, ast.If)
                     and "speaker_kind is not None" in ast.unparse(statement.test))
        compiled = compile(ast.Module(body=[guard], type_ignores=[]), "speaker-report-guard", "exec")
        for kind in (1, 2):
            report = {"speaker_kind": kind, "speaker_session_count": 2, "speaker_caller_count": 2}
            exec(compiled, {"speaker_kind": kind, "report": report})
            for field, values in (("speaker_kind", (None, "1", True, 0, 3)),
                                  ("speaker_session_count", (None, "2", 0, 1, 3)),
                                  ("speaker_caller_count", (None, "2", 0, 1, 3))):
                for value in values:
                    with self.subTest(kind=kind, field=field, value=value), self.assertRaises(RuntimeError):
                        exec(compiled, {"speaker_kind": kind, "report": report | {field: value}})
        exec(compiled, {"speaker_kind": None, "report": {}})

    def test_signed_gate_and_original_shell_arity_are_unchanged(self) -> None:
        self.assertIn('[[ $# -ge 4 && $# -le 6 ]]', SCRIPT)
        self.assertIn('codesign --verify --deep --strict "$app"', SCRIPT)
        self.assertIn('"$(uname -s)" == Darwin && "$(uname -m)" == arm64', SCRIPT)
        self.assertNotIn("shutil.copytree", EMBEDDED)
