"""Check regression selection and packaging with fake tools, not macOS execution."""
import ast
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import textwrap
from typing import Literal
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools/run_local_regression_matrix.sh"


class LocalRegressionMatrixTests(unittest.TestCase):
    def run_matrix(self, group, fail_selector=""):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            log = temp / "commands.jsonl"
            executable = temp / "xcodebuild"
            executable.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['VOXT_COMMAND_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "sys.exit(1 if os.environ.get('VOXT_FAIL_SELECTOR') in sys.argv[1:] else 0)\n"
            )
            executable.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": str(temp) + os.pathsep + os.environ.get("PATH", ""),
                "CI": "false",
                "GITHUB_ACTIONS": "false",
                "VOXT_RUN_MODEL_TESTS": "0",
                "VOXT_SPM_CACHE_PATH": str(temp / "cache"),
                "VOXT_SPM_CLONE_PATH": str(temp / "packages"),
                "VOXT_COMMAND_LOG": str(log),
                "VOXT_FAIL_SELECTOR": fail_selector,
            }
            result = subprocess.run(
                ["bash", str(SCRIPT), group], cwd=temp, env=environment,
                text=True, capture_output=True, check=False,
            )
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands

    def test_static_selectors_reference_existing_suites(self):
        suites = {}
        for path in (ROOT / "VoxtTests").rglob("*.swift"):
            text = path.read_text()
            classes = list(re.finditer(r"^(?:final )?class (\w+)", text, re.M))
            for index, match in enumerate(classes):
                end = classes[index + 1].start() if index + 1 < len(classes) else len(text)
                suites[match[1]] = set(re.findall(r"func (test\w+)\(", text[match.end():end]))
        selectors = re.findall(r"-only-testing:VoxtTests/(\w+)(?:/(\w+))?", SCRIPT.read_text())
        self.assertTrue(selectors)
        for suite, method in selectors:
            self.assertIn(suite, suites)
            if method:
                self.assertIn(method, suites[suite], f"{suite}/{method}")

    def test_refactor_selects_split_suites_with_portable_unsigned_strict_commands(self):
        result, commands = self.run_matrix("refactor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(commands), 2)
        selectors = {arg for command in commands for arg in command if arg.startswith("-only-testing:")}
        for family in ("RemoteLLMRuntimeClient", "RemoteModelConfiguration", "HotkeyManager", "MLXModelManager", "MeetingDetailViewModel"):
            for path in (ROOT / "VoxtTests").glob(f"{family}*Tests.swift"):
                self.assertIn(f"-only-testing:VoxtTests/{path.stem}", selectors)
        for suite in ("DoubaoPacketCodecTests", "RemoteASRResponseStateTests", "RemoteASRCompletionTests", "MeetingRemoteSessionLifecycleTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("TrackedTaskStoreTests", "LLMRequestLifecycleTests", "MeetingLiveSessionRegistryTests", "MLXCorrectionPassCoordinatorTests", "MeetingCaptureTimelineTests", "MLXNativeLiveRuntimeTests", "HotkeyEventTapRunLoopTests", "HotkeyManagerLifetimeTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("SharedModelLoadCoordinatorTests", "MeetingImportedFileAnalyzerTests", "MeetingFileTaskQueueTests", "MeetingFinalizationContextTests", "MeetingFinalizationCheckpointStoreTests", "RecordingSessionLifecycleTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("AutomaticDictionaryLearningMonitorTests", "DictionaryStoreAsyncTests", "TranscriptionHistoryStoreAsyncTests", "TranscriptionHistoryEntryAudioTests", "MeetingTranscriptVirtualListTests", "MeetingDetailTranscriptListCacheTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("CustomLLMRequestRuntimeTests", "CustomLLMModelDownloadSupportTests", "CustomLLMModelSupportTests", "ModelDownloadSourceSupportTests", "MLXModelSupportTests", "ModelInstallationCacheTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("TextInjectionTransactionTests", "PasteboardTextWriterTests", "RemoteProviderConnectivityTesterTests", "RemoteProviderConfigurationPolicyTests", "DictionarySuggestionStoreTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("DictionarySuggestionReloadTests", "RemoteProviderSheetOperationsTests", "ConnectivityWebSocketSessionTests", "RemoteASRPreviewControllerTests", "ModelDownloadProgressTests", "HotkeyPreferenceCorruptStorageTests", "MLXInferenceConfigurationTests", "MeetingLiveTranscriptPresentationTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for suite in ("ModelConfigurationIssueResolverTests", "VoxtLogRedactorTests"):
            self.assertIn(f"-only-testing:VoxtTests/{suite}", selectors)
        for command in commands:
            self.assertEqual(command[0], "test")
            self.assertIn(str(ROOT / "Voxt.xcodeproj"), command)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", command)

    def test_all_does_not_run_core_vad_suites_twice(self):
        result, commands = self.run_matrix("all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(commands), 3)
        selectors = [arg for command in commands for arg in command if arg.startswith("-only-testing:")]
        self.assertEqual(len(selectors), len(set(selectors)))

    def test_removed_groups_fail_instead_of_selecting_missing_tests(self):
        for group in ("whisper", "diagnostic", "unknown"):
            with self.subTest(group=group):
                result, commands = self.run_matrix(group)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(commands, [])

    def test_later_success_does_not_hide_core_failure(self):
        result, commands = self.run_matrix(
            "refactor", "-only-testing:VoxtTests/TranscriptionCapturePipelineTests"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(commands), 2)
        self.assertIn("Group failed: run_core", result.stdout)


class OmniXPCPackagingTests(unittest.TestCase):
    def project_object(self, identifier: str) -> str:
        project = (ROOT / "Voxt.xcodeproj/project.pbxproj").read_text()
        match = re.search(rf"^\t\t{identifier} /\*[^\n]*\*/ = \{{\n(.*?)\n\t\t\}};", project, re.S | re.M)
        self.assertIsNotNone(match, identifier)
        return match[1]

    def test_service_is_explicit_and_default_build_graph_is_unchanged(self) -> None:
        host = self.project_object("31F19CCC2F4D76D200E96913")
        self.assertRegex(host, r"dependencies = \(\s*\);")
        service = self.project_object("A0BC00000000000000000001")
        self.assertIn('productType = "com.apple.product-type.xpc-service"', service)
        sources = self.project_object("A0BC00000000000000000030")
        expected_sources = [
            "OmniInferenceService.swift", "main.swift", "QwenCoreModel.swift", "OmniFinalSessionEngine.swift",
            "OmniSessionLifecycle.swift", "QwenCoreRealtimeLease.swift", "OmniRealtimeSession.swift",
            "OmniRealtimeSessionEngine.swift", "SileroCoreModel.swift", "OmniSileroInferenceEngine.swift",
            "SileroCoreStreamLease.swift", "OmniSileroOfflineInference.swift", "OmniSileroStream.swift", "OmniSileroStreamingEngine.swift",
            "SortformerCoreModel.swift", "SortformerCoreStreamLease.swift", "OmniSortformerInferenceEngine.swift",
            "OmniSortformerStream.swift", "OmniSortformerStreamingEngine.swift", "OmniSortformerRPC.swift",
            "OmniSortformerModelCleanup.swift",
        ]
        self.assertEqual(re.findall(r"/\* (\S+) in Sources \*/", sources), expected_sources)
        self.assertEqual({path.name for path in (ROOT / "OmniInference").glob("*.swift")}, set(expected_sources))
        for identifier in ("31F19CD92F4D76D300E96913", "31F19CDA2F4D76D300E96913", "31F19CDB2F4D76D300E96913"):
            configuration = self.project_object(identifier)
            self.assertIn("CODE_SIGN_ENTITLEMENTS = Voxt/Voxt.entitlements;", configuration)
            self.assertNotIn("OmniXPC", configuration)
            self.assertNotIn("ARCHS =", configuration)
        for identifier in ("3B1A2B3C4D5E6F708090A0B15", "3B1A2B3C4D5E6F708090A0B16", "3B1A2B3C4D5E6F708090A0B18"):
            self.assertNotIn("OmniXPC", self.project_object(identifier))
        default_scheme = ET.parse(ROOT / "Voxt.xcodeproj/xcshareddata/xcschemes/Voxt.xcscheme")
        self.assertEqual(default_scheme.find("TestAction").get("buildConfiguration"), "TestDebug")
        self.assertNotIn("OmniInference", ET.tostring(default_scheme.getroot()).decode())

    def test_host_and_service_link_the_same_local_contracts_package(self) -> None:
        project = (ROOT / "Voxt.xcodeproj/project.pbxproj").read_text()
        package_identifier = "A0BD00000000000000000001"
        package = self.project_object(package_identifier)
        self.assertIn("isa = XCLocalSwiftPackageReference;", package)
        self.assertIn("relativePath = Packages/OmniXPCContracts;", package)
        self.assertIn(package_identifier, self.project_object("31F19CC52F4D76D200E96913"))
        for target, frameworks, product, build_file in [
            ("31F19CCC2F4D76D200E96913", "31F19CCA2F4D76D200E96913", "A0BD00000000000000000002", "A0BD00000000000000000004"),
            ("A0BC00000000000000000001", "A0BC00000000000000000031", "A0BD00000000000000000003", "A0BD00000000000000000005"),
        ]:
            self.assertIn(f"{product} /* OmniXPCContracts */", self.project_object(target))
            self.assertIn(f"package = {package_identifier}", self.project_object(product))
            self.assertIn("productName = OmniXPCContracts;", self.project_object(product))
            self.assertIn(f"{build_file} /* OmniXPCContracts in Frameworks */", self.project_object(frameworks))
            self.assertRegex(project, rf"{build_file} /\* OmniXPCContracts in Frameworks \*/ = .*productRef = {product}")
        for filename in ("OmniXPCProtocol.swift", "OmniXPCFinalSessionBuffer.swift"):
            self.assertNotIn(filename, project)
            self.assertFalse((ROOT / "Voxt/Transcription" / filename).exists())
            self.assertTrue((ROOT / "Packages/OmniXPCContracts/Sources/OmniXPCContracts" / filename).is_file())
        self.assertFalse((ROOT / "VoxtTests/OmniXPCProtocolTests.swift").exists())
        self.assertTrue((ROOT / "Packages/OmniXPCContracts/Tests/OmniXPCContractsTests/OmniXPCProtocolTests.swift").is_file())

    def test_artifact_validation_is_linked_without_download_inference(self) -> None:
        package_identifier = "A0BE00000000000000000001"
        product_identifier = "A0BE00000000000000000002"
        build_identifier = "A0BE00000000000000000003"
        self.assertIn("relativePath = Packages/OmniModelArtifacts;", self.project_object(package_identifier))
        self.assertIn(package_identifier, self.project_object("31F19CC52F4D76D200E96913"))
        self.assertIn(product_identifier, self.project_object("31F19CCC2F4D76D200E96913"))
        self.assertIn(build_identifier, self.project_object("31F19CCA2F4D76D200E96913"))
        self.assertIn(f"package = {package_identifier}", self.project_object(product_identifier))
        self.assertIn("productName = OmniModelArtifacts;", self.project_object(product_identifier))
        self.assertNotIn(product_identifier, self.project_object("A0BC00000000000000000001"))
        for source in ("Voxt/Meeting/Capture/SileroVADModelProvisioner.swift",
                       "Voxt/Meeting/SpeakerAnalysis/MeetingDiarizationModelManager.swift"):
            text = (ROOT / source).read_text()
            self.assertIn("import OmniModelArtifacts", text)
            self.assertIn("OmniModelArtifactValidation.validateSafetensorsDirectory(at:", text)
            self.assertNotRegex(text, r"import MLX(?:AudioVAD)?\b|\.fromModelDirectory\(|SileroVADModelSupport\.loadModel\(")
        loader = (ROOT / "Voxt/Meeting/Capture/SileroVADModelLoader.swift").read_text()
        self.assertIn("try withError", loader)
        self.assertIn("SileroVAD.fromModelDirectory", loader)
        workflow = (ROOT.parent / ".github/workflows/voxt-mac-ci.yaml").read_text()
        self.assertIn("swift test --package-path Voxt/Packages/OmniModelArtifacts", workflow)

    def test_ci_runs_contracts_standalone_without_removed_app_selector(self) -> None:
        workflow = (ROOT.parent / ".github/workflows/voxt-mac-ci.yaml").read_text()
        self.assertIn("swift test --package-path Voxt/Packages/OmniXPCContracts", workflow)
        self.assertNotIn("-only-testing:VoxtTests/OmniXPCProtocolTests", workflow)
        self.assertIn("vars.VOXT_ENABLE_MAC_CI == 'true'", workflow)
        self.assertIn("vars.VOXT_ENABLE_CI_PACKAGE == 'true'", workflow)

    def test_validation_scheme_builds_service_before_host_without_parallelism(self) -> None:
        scheme = ET.parse(ROOT / "Voxt.xcodeproj/xcshareddata/xcschemes/VoxtOmniXPCSmoke.xcscheme")
        self.assertEqual(scheme.find("BuildAction").get("parallelizeBuildables"), "NO")
        references = scheme.findall("BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")
        self.assertEqual([reference.get("BlueprintName") for reference in references], ["OmniInference", "Voxt"])
        for action in ("TestAction", "LaunchAction", "ProfileAction", "AnalyzeAction", "ArchiveAction"):
            self.assertEqual(scheme.find(action).get("buildConfiguration"), "OmniXPCDebug")
        phase = self.project_object("A0BC00000000000000000034")
        self.assertIn("OmniXPCDebug", phase)
        self.assertIn("VOXT_OMNI_EMBED_XPC:-NO", phase)

    def test_validation_metadata_and_entitlements_use_configured_identity(self) -> None:
        identity_settings = {
            "OmniAppGroupIdentifier": "VOXT_OMNI_APP_GROUP_ID",
            "OmniInferenceServiceIdentifier": "VOXT_OMNI_XPC_SERVICE_ID",
            "OmniHostBundleIdentifier": "VOXT_OMNI_HOST_BUNDLE_IDENTIFIER",
            "OmniTeamIdentifier": "VOXT_OMNI_TEAM_IDENTIFIER",
        }
        for filename in ("Voxt/Voxt/Info.plist", "OmniInference/Info.plist"):
            metadata = plistlib.loads((ROOT / filename).read_bytes())
            for field, setting in identity_settings.items():
                self.assertEqual(metadata[field], f"$({setting})")
        group_field = "com.apple.security.application-groups"
        default = plistlib.loads((ROOT / "Voxt/Voxt.entitlements").read_bytes())
        validation = plistlib.loads((ROOT / "Config/OmniXPCApp.entitlements").read_bytes())
        self.assertNotIn(group_field, default)
        self.assertEqual(validation.pop(group_field), ["$(VOXT_OMNI_APP_GROUP_ID)"])
        self.assertEqual(validation, default)
        service = plistlib.loads((ROOT / "OmniInference/OmniInference.entitlements").read_bytes())
        self.assertEqual(service[group_field], ["$(VOXT_OMNI_APP_GROUP_ID)"])
        self.assertNotIn("com.apple.security.network.server", service)
        shared = (ROOT / "Config/OmniXPC.shared.xcconfig").read_text()
        self.assertIn('#include "Signing.shared.xcconfig"', shared)
        self.assertIn("VOXT_OMNI_XPC_VALIDATION", shared)
        self.assertIn("DEVELOPMENT_TEAM = $(VOXT_OMNI_TEAM_IDENTIFIER)", shared)
        for setting in identity_settings.values():
            self.assertRegex(shared, rf"(?m)^{setting} =$")
        native = (ROOT / "Config/OmniXPCService.xcconfig").read_text()
        self.assertIn('"$(PROJECT_DIR)/../sglang_omni_mlx/native/include"', native)
        self.assertIn('"$(VOXT_OMNI_NATIVE_RUNTIME_DIR)/bin"', native)
        self.assertIn("OTHER_LDFLAGS = $(inherited) -lOmniCore", native)
        self.assertIn("@executable_path/../Frameworks", native)
        self.assertNotIn("-lOmniCore", (ROOT / "Config/OmniXPCApp.xcconfig").read_text())

    def run_embedding(
        self, *, sign: bool = True,
        fault: Literal["", "dependency", "runpath", "install-name", "verify"] = "",
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], set[str]]:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            executables = temporary / "tools"
            executables.mkdir()
            command_log = temporary / "commands.jsonl"
            dispatcher = executables / "dispatcher"
            dispatcher.write_text(textwrap.dedent('''\
                #!/usr/bin/env python3
                import json
                import os
                from pathlib import Path
                import shutil
                import sys

                command = Path(sys.argv[0]).name
                arguments = sys.argv[1:]
                failure = os.environ["VOXT_TEST_FAILURE"]
                with open(os.environ["VOXT_COMMAND_LOG"], "a") as stream:
                    stream.write(json.dumps([command, *arguments]) + "\\n")
                binary = Path(arguments[-1])
                if command == "lipo":
                    print("arm64")
                elif command == "otool":
                    print(f"{binary}:")
                    if arguments[0] == "-D":
                        print(f"/external/{binary.name}" if failure == "install-name" else f"@rpath/{binary.name}")
                    elif arguments[0] == "-L":
                        dependency = "/external/libmlx.dylib" if failure == "dependency" else "@rpath/libOmniCore.dylib"
                        print(f"    {dependency} (compatibility version 1.0.0)")
                    else:
                        runpath = "/external/runtime" if failure == "runpath" else "@executable_path/../Frameworks"
                        print(f"    cmd LC_RPATH\\n    cmdsize 48\\n    path {runpath} (offset 12)")
                elif command == "codesign":
                    sys.exit(1 if failure == "verify" and "--verify" in arguments else 0)
                elif command == "ditto":
                    shutil.copytree(arguments[0], arguments[1])
                else:
                    sys.exit(2)
            '''))
            dispatcher.chmod(0o755)
            for executable in ("lipo", "otool", "codesign", "ditto"):
                (executables / executable).symlink_to(dispatcher)
            runtime = temporary / "native runtime/bin"
            runtime.mkdir(parents=True)
            for filename in ("libOmniCore.dylib", "libmlx.dylib", "libjaccl.dylib", "mlx.metallib", "qwen3_asr_server"):
                (runtime / filename).write_text("test payload")
            products = temporary / "products"
            service = products / "OmniInference.xpc"
            (service / "Contents/MacOS").mkdir(parents=True)
            (service / "Contents/MacOS/OmniInference").write_text("test executable")
            (service / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.host.service",
                "OmniInferenceServiceIdentifier": "test.host.service",
                "OmniHostBundleIdentifier": "test.host",
                "OmniAppGroupIdentifier": "group.test.host",
                "OmniTeamIdentifier": "TESTTEAM01",
            }))
            environment = {
                **os.environ, "PATH": f"{executables}{os.pathsep}{os.environ['PATH']}",
                "VOXT_COMMAND_LOG": str(command_log), "VOXT_TEST_FAILURE": fault,
                "CONFIGURATION": "OmniXPCDebug", "ARCHS": "arm64",
                "VOXT_OMNI_EMBED_XPC": "YES",
                "VOXT_OMNI_NATIVE_RUNTIME_DIR": str(runtime.parent),
                "VOXT_OMNI_APP_GROUP_ID": "group.test.host",
                "VOXT_OMNI_XPC_SERVICE_ID": "test.host.service",
                "VOXT_OMNI_HOST_BUNDLE_IDENTIFIER": "test.host",
                "VOXT_OMNI_TEAM_IDENTIFIER": "TESTTEAM01",
                "CODE_SIGNING_ALLOWED": "YES" if sign else "NO",
                "EXPANDED_CODE_SIGN_IDENTITY": "test certificate",
                "TARGET_BUILD_DIR": str(products), "BUILT_PRODUCTS_DIR": str(products),
                "FRAMEWORKS_FOLDER_PATH": "OmniInference.xpc/Contents/Frameworks",
                "CONTENTS_FOLDER_PATH": "Voxt Omni XPC.app/Contents",
            }
            script = ROOT / "tools/embed_omni_xpc.sh"
            result = subprocess.run(["bash", str(script), "--service"], env=environment, text=True, capture_output=True, check=False)
            if result.returncode == 0:
                result = subprocess.run(["bash", str(script), "--app"], env=environment, text=True, capture_output=True, check=False)
            else:
                pass
            embedded = products / "Voxt Omni XPC.app/Contents/XPCServices/OmniInference.xpc/Contents/Frameworks"
            files = {path.name for path in embedded.iterdir()} if embedded.exists() else set()
            commands = [json.loads(line) for line in command_log.read_text().splitlines()]
            return result, commands, files

    def test_embedding_copies_only_core_runtime_and_never_signs_metallib(self) -> None:
        result, commands, files = self.run_embedding()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {"libOmniCore.dylib", "libmlx.dylib", "libjaccl.dylib", "mlx.metallib"})
        signatures = [command for command in commands if command[0] == "codesign"]
        signed = [Path(command[-1]).name for command in signatures if "--sign" in command]
        self.assertEqual(signed, ["libOmniCore.dylib", "libmlx.dylib", "libjaccl.dylib"])
        self.assertTrue(all(".metallib" not in command[-1] for command in signatures))
        self.assertEqual(Path(signatures[-1][-1]).name, "OmniInference.xpc")
        self.assertIn("--verify", signatures[-1])
        self.assertEqual(commands[-1][0], "ditto")

    def test_bad_install_names_dependencies_rpaths_and_signatures_stop_embedding(self) -> None:
        for fault in ("dependency", "runpath", "install-name", "verify"):
            with self.subTest(fault=fault):
                result, commands, files = self.run_embedding(fault=fault)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(files, set())
                self.assertFalse(any(command[0] == "ditto" for command in commands))

    def test_unsigned_embedding_is_explicitly_structural(self) -> None:
        result, commands, files = self.run_embedding(sign=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(files)
        self.assertIn("not signed XPC validation", result.stderr)
        self.assertFalse(any(command[0] == "codesign" for command in commands))

    def test_default_and_intel_embedding_need_no_runtime_or_identity(self) -> None:
        for configuration in ("Debug", "TestDebug", "Release", "OmniXPCDebug"):
            result = subprocess.run(
                ["bash", str(ROOT / "tools/embed_omni_xpc.sh"), "--app"],
                env={"PATH": os.environ["PATH"], "CONFIGURATION": configuration, "ARCHS": "x86_64"},
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_packaging_shell_and_embedded_python_parse(self) -> None:
        for filename in ("embed_omni_xpc.sh", "build_omni_xpc_smoke.sh", "run_omni_xpc_smoke.sh", "package_local_app.sh"):
            script = ROOT / "tools" / filename
            result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            for source in re.findall(r"<<'PY'\n(.*?)^PY$", script.read_text(), re.M | re.S):
                ast.parse(source, filename=filename)

    def test_signed_packaging_cannot_ignore_verification_failure(self) -> None:
        script = (ROOT / "tools/package_local_app.sh").read_text()
        self.assertIn('codesign --verify --deep --strict --verbose=2 "$APP_PATH" || die', script)
        self.assertNotIn("artifact was still packaged", script)
        self.assertIn("Release packaging must not contain", script)
        self.assertIn("--preserve-metadata=entitlements", script)
        leaf_signing = script.index("while IFS= read -r framework_code")
        bundle_signing = script.index('find "$APP_PATH/Contents/Frameworks" -depth')
        host_signing = script.index('--entitlements "$SIGNING_ENTITLEMENTS"')
        self.assertLess(leaf_signing, bundle_signing)
        self.assertLess(bundle_signing, host_signing)
        smoke = (ROOT / "tools/build_omni_xpc_smoke.sh").read_text()
        self.assertIn("NOT signed proof", smoke)
        self.assertIn("Apple Silicon macOS is required", smoke)
        self.assertIn('codesign --verify --deep --strict --verbose=2 "$APP_PATH"', smoke)
        self.assertIn("anchor apple generic and certificate leaf[subject.OU]", smoke)
        self.assertNotIn("build_runtime.sh\"", smoke)


if __name__ == "__main__":
    unittest.main()
