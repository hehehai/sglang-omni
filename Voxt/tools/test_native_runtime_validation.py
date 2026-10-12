"""Test filesystem preflight with placeholders, not Mach-O compatibility or signing."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

VALIDATION_SCRIPT: Path = (
    Path(__file__).with_name("validate_native_runtime.sh").resolve()
)
SERVER_FILENAMES: tuple[str, ...] = (
    "qwen3_asr_server",
    "whisper_server",
    "cohere_transcribe_server",
    "moss_transcribe_diarize_server",
    "nemotron_asr_server",
    "parakeet_server",
    "sensevoice_server",
)
RESOURCE_FILENAMES: tuple[str, ...] = (
    "libmlx.dylib",
    "libjaccl.dylib",
    "mlx.metallib",
)


class NativeRuntimeValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory: tempfile.TemporaryDirectory[str] = (
            tempfile.TemporaryDirectory()
        )
        self.addCleanup(self.temporary_directory.cleanup)

    def create_runtime_fixture(self) -> Path:
        runtime_directory = Path(
            tempfile.mkdtemp(
                prefix="native runtime ", dir=self.temporary_directory.name
            )
        )
        bin_directory = runtime_directory / "bin"
        bin_directory.mkdir()
        for filename in SERVER_FILENAMES:
            server_path = bin_directory / filename
            server_path.write_text(
                "test-only executable placeholder, not native code\n"
            )
            server_path.chmod(0o755)
        for filename in RESOURCE_FILENAMES:
            resource_path = bin_directory / filename
            resource_path.write_text("test-only resource placeholder\n")
            resource_path.chmod(0o644)
        return runtime_directory

    def run_validator(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(VALIDATION_SCRIPT), *arguments],
            cwd=self.temporary_directory.name,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_invalid_runtime(
        self, runtime_directory: Path, invalid_path: Path
    ) -> None:
        result = self.run_validator(str(runtime_directory))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(str(invalid_path), result.stderr)

    def test_complete_runtime_without_core_abi_library_passes(self) -> None:
        runtime_directory = self.create_runtime_fixture()
        result = self.run_validator(str(runtime_directory))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_relative_runtime_directory_passes(self) -> None:
        runtime_directory = self.create_runtime_fixture()
        relative_directory = runtime_directory.relative_to(
            self.temporary_directory.name
        )
        result = self.run_validator(str(relative_directory))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_missing_server_is_rejected(self) -> None:
        for filename in SERVER_FILENAMES:
            with self.subTest(filename=filename):
                runtime_directory = self.create_runtime_fixture()
                server_path = runtime_directory / "bin" / filename
                server_path.unlink()
                self.assert_invalid_runtime(runtime_directory, server_path)

    def test_every_non_executable_server_is_rejected(self) -> None:
        for filename in SERVER_FILENAMES:
            with self.subTest(filename=filename):
                runtime_directory = self.create_runtime_fixture()
                server_path = runtime_directory / "bin" / filename
                server_path.chmod(0o644)
                self.assert_invalid_runtime(runtime_directory, server_path)

    def test_server_directories_are_rejected(self) -> None:
        for filename in SERVER_FILENAMES:
            with self.subTest(filename=filename):
                runtime_directory = self.create_runtime_fixture()
                server_path = runtime_directory / "bin" / filename
                server_path.unlink()
                server_path.mkdir()
                self.assert_invalid_runtime(runtime_directory, server_path)

    def test_every_missing_resource_is_rejected(self) -> None:
        for filename in RESOURCE_FILENAMES:
            with self.subTest(filename=filename):
                runtime_directory = self.create_runtime_fixture()
                resource_path = runtime_directory / "bin" / filename
                resource_path.unlink()
                self.assert_invalid_runtime(runtime_directory, resource_path)

    def test_resource_directories_are_rejected(self) -> None:
        for filename in RESOURCE_FILENAMES:
            with self.subTest(filename=filename):
                runtime_directory = self.create_runtime_fixture()
                resource_path = runtime_directory / "bin" / filename
                resource_path.unlink()
                resource_path.mkdir()
                self.assert_invalid_runtime(runtime_directory, resource_path)

    def test_every_unreadable_resource_is_rejected(self) -> None:
        for filename in RESOURCE_FILENAMES:
            with self.subTest(filename=filename):
                runtime_directory = self.create_runtime_fixture()
                resource_path = runtime_directory / "bin" / filename
                resource_path.chmod(0o000)
                if os.access(resource_path, os.R_OK):
                    self.skipTest("Current user can read mode-000 files")
                else:
                    self.assert_invalid_runtime(runtime_directory, resource_path)

    def test_unsearchable_bin_directory_is_rejected(self) -> None:
        runtime_directory = self.create_runtime_fixture()
        bin_directory = runtime_directory / "bin"
        bin_directory.chmod(0o600)
        try:
            if os.access(bin_directory, os.X_OK):
                self.skipTest(
                    "Current user can search directories without execute access"
                )
            else:
                self.assert_invalid_runtime(runtime_directory, bin_directory)
        finally:
            bin_directory.chmod(0o755)

    def test_missing_bin_directory_is_rejected(self) -> None:
        runtime_directory = Path(self.temporary_directory.name)
        self.assert_invalid_runtime(runtime_directory, runtime_directory / "bin")

    def test_bin_regular_file_is_rejected(self) -> None:
        runtime_directory = Path(self.temporary_directory.name)
        bin_path = runtime_directory / "bin"
        bin_path.write_text("not a directory\n")
        self.assert_invalid_runtime(runtime_directory, bin_path)

    def test_missing_runtime_directory_is_rejected(self) -> None:
        runtime_directory = Path(self.temporary_directory.name) / "missing runtime"
        self.assert_invalid_runtime(runtime_directory, runtime_directory / "bin")

    def test_invalid_arguments_are_rejected(self) -> None:
        runtime_directory = self.create_runtime_fixture()
        for arguments in ((), ("",), (str(runtime_directory), "extra")):
            with self.subTest(arguments=arguments):
                result = self.run_validator(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
else:
    pass
