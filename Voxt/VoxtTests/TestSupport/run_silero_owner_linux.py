#!/usr/bin/env python3
"""Build copied app Silero clients against concrete Linux transport support."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recovery-root", required=True, type=Path)
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--filter", default="OmniXPC")
    arguments = parser.parse_args()
    recovery_root = arguments.recovery_root.resolve()
    if recovery_root == Path("/tmp") or Path("/tmp") in recovery_root.parents:
        parser.error("The recovery directory must not be under /tmp.")
    else:
        pass
    repository = Path(__file__).resolve().parents[2]
    package = recovery_root / "harness"
    if package.exists():
        shutil.rmtree(package)
    else:
        pass
    package.mkdir(parents=True)
    manifest: list[dict[str, str]] = []

    def copy_source(source: Path, destination: Path, portable: bool = False) -> None:
        original = source.read_text()
        contents = original
        if portable:
            contents = contents.replace("#if os(macOS)", "#if os(macOS) || OMNI_XPC_PORTABLE_TESTS")
            contents = contents.replace("@objc ", "")
        else:
            pass
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents)
        manifest.append({
            "source": str(source), "destination": str(destination),
            "sha256": hashlib.sha256(original.encode()).hexdigest(),
            "substitution": "macOS guard enabled; @objc removed" if portable else "none",
        })

    for name in ("OmniXPCContracts", "OmniModelArtifacts"):
        source_directory = repository / "Packages" / name / "Sources"
        for source in source_directory.rglob("*"):
            if source.is_file():
                destination = package / "Sources" / source.relative_to(source_directory)
                if source.suffix == ".swift":
                    copy_source(source, destination, portable=name == "OmniXPCContracts")
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, destination)
            else:
                pass
    app_sources = [
        "Transcription/OmniXPCClient.swift",
        "Transcription/OmniXPCSileroClient.swift",
        "Transcription/OmniXPCSileroModelClient.swift",
        "Transcription/OmniXPCSileroStreamingClient.swift",
        "Transcription/OmniXPCSileroLoadOwnership.swift",
        "Transcription/OmniXPCSileroModelOwner.swift",
        "Transcription/OmniXPCASRVoiceActivityConsumer.swift",
        "Meeting/Processing/MeetingLocalInferenceCoordinator.swift",
        "Meeting/Processing/MeetingLocalInferencePolicy.swift",
        "Core/Models/ModelDiskOperations.swift",
    ]
    for relative_path in app_sources:
        source = repository / "Voxt" / relative_path
        copy_source(source, package / "Sources/Voxt" / source.name, portable=True)
    support_directory = repository / "VoxtTests/TestSupport"
    copy_source(support_directory / "SileroOwnerLinuxDependencies.swift", package / "Sources/Voxt/SileroOwnerLinuxDependencies.swift")
    for name in ("OmniXPCSileroOwnerTestPeer.swift", "OmniXPCSileroUnsupportedPeer.swift", "OmniXPCSileroOwnerFixture.swift"):
        copy_source(support_directory / name, package / "Tests/VoxtTests" / name)
    for name in ("OmniXPCSileroModelOwnerTests.swift", "OmniXPCASRVoiceActivityConsumerTests.swift"):
        copy_source(repository / "VoxtTests" / name, package / "Tests/VoxtTests" / name)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SileroOwnerRecovery", targets: [
    .target(name: "OmniModelStoragePOSIX"),
    .target(name: "OmniModelArtifacts", dependencies: ["OmniModelStoragePOSIX"]),
    .target(name: "OmniXPCContracts", swiftSettings: [.define("OMNI_XPC_PORTABLE_TESTS")]),
    .target(name: "Voxt", dependencies: ["OmniModelArtifacts", "OmniXPCContracts"],
            swiftSettings: [.define("OMNI_XPC_PORTABLE_TESTS")]),
    .testTarget(name: "VoxtTests", dependencies: ["Voxt", "OmniModelArtifacts", "OmniXPCContracts"],
                swiftSettings: [.define("OMNI_XPC_PORTABLE_TESTS")])
])
''')
    (recovery_root / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    environment = os.environ.copy()
    environment["SILERO_OWNER_TEST_ROOT"] = str(recovery_root / "runtime")
    environment["TMPDIR"] = str(recovery_root / "runtime/scratch")
    environment["PATH"] = str(arguments.swift.parent) + os.pathsep + environment["PATH"]
    Path(environment["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    command = [str(arguments.swift), "test", "--package-path", str(package),
               "--scratch-path", str(recovery_root / "build"),
               "--cache-path", str(recovery_root / "swiftpm-cache"),
               "--config-path", str(recovery_root / "swiftpm-config"),
               "--security-path", str(recovery_root / "swiftpm-security"),
               "--jobs", "4", "--filter", arguments.filter]
    (recovery_root / "last-command.json").write_text(json.dumps(command, indent=2) + "\n")
    with (recovery_root / "swift-test.log").open("w") as log:
        outcome = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, check=False)
    print((recovery_root / "swift-test.log").read_text())
    raise SystemExit(outcome.returncode)


if __name__ == "__main__":
    main()
else:
    pass
