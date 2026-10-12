"""Validate the runnable smoke probe guard against the shared ABI epoch."""

import ast
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class OmniXPCSmokeContractTests(unittest.TestCase):
    def setUp(self) -> None:
        script = (ROOT / "tools/run_omni_xpc_smoke.sh").read_text()
        embedded = script.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        self.statements: list[ast.stmt] = ast.parse(embedded).body
        contract = (ROOT / "Packages/OmniXPCContracts/Sources/OmniXPCContracts/OmniXPCProtocol.swift").read_text()
        self.abi_version: int = int(re.search(r"abiVersion = (\d+)", contract)[1])
        self.script: str = script

    def test_probe_guard_accepts_only_current_matched_epoch(self) -> None:
        assignment = next(statement for statement in self.statements if isinstance(statement, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == "expected_abi_version" for target in statement.targets))
        self.assertIsInstance(assignment.value, ast.Constant)
        self.assertEqual(assignment.value.value, self.abi_version)
        guard = next(statement for statement in self.statements if isinstance(statement, ast.If)
                     and "prepared.get('abi_version')" in ast.unparse(statement.test))
        compiled = compile(ast.Module(body=[assignment, guard], type_ignores=[]), "smoke-probe-guard", "exec")
        exec(compiled, {"prepared": {"status": "prepared", "abi_version": self.abi_version}})
        for version in [None, False, 0, 5, 6, 7, 8, self.abi_version + 1, str(self.abi_version)]:
            if version == self.abi_version:
                continue
            else:
                with self.subTest(version=version), self.assertRaises(RuntimeError):
                    exec(compiled, {"prepared": {"status": "prepared", "abi_version": version}})

    def test_probe_failure_rejects_matching_epoch(self) -> None:
        guard = next(statement for statement in self.statements if isinstance(statement, ast.If)
                     and "prepared.get('abi_version')" in ast.unparse(statement.test))
        compiled = compile(ast.Module(body=[guard], type_ignores=[]), "smoke-probe-guard", "exec")
        with self.assertRaises(RuntimeError):
            exec(compiled, {"prepared": {"status": "failed", "abi_version": self.abi_version},
                            "expected_abi_version": self.abi_version})

    def test_models_stage_through_app_cooperating_publication(self) -> None:
        self.assertIn("staged = run('stage', run_id)", self.script)
        self.assertNotIn("shutil.copytree", self.script)
        self.assertIn("VOXT_OMNI_XPC_SMOKE_MODEL_SOURCE", self.script)
        source = (ROOT / "Voxt/App/OmniXPCSmokeModelPreparation.swift").read_text()
        self.assertIn("ModelDiskOperations.prepareModelCopy", source)
        self.assertIn("OmniXPCRequestValidation.modelDirectory", source)
