#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/build/OmniXPCSmokeDerivedData"
SIGN_APP=YES
OVERRIDES=(ARCHS=arm64)

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --native-runtime)
      [[ -n "${2:-}" ]] || fail "--native-runtime requires a directory"
      export VOXT_OMNI_NATIVE_RUNTIME_DIR="$2"
      shift 2
      ;;
    --derived-data)
      [[ -n "${2:-}" ]] || fail "--derived-data requires a directory"
      DERIVED_DATA="$2"
      shift 2
      ;;
    --app-sign-identity)
      [[ -n "${2:-}" ]] || fail "--app-sign-identity requires an identity"
      OVERRIDES+=("CODE_SIGN_IDENTITY=$2")
      shift 2
      ;;
    --no-sign)
      SIGN_APP=NO
      OVERRIDES+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: tools/build_omni_xpc_smoke.sh [options]

Build the opt-in VoxtOmniXPCSmoke scheme on Apple Silicon, macOS 26.2 or newer.
The native runtime must already be installed by native/scripts/build_runtime.sh.
No model data is needed. This builds and verifies signatures; it does not run smoke tests.
The final stdout line is the app path for run_omni_xpc_smoke.sh.

Options:
  --native-runtime PATH    Prebuilt runtime containing bin/libOmniCore.dylib,
                           libmlx.dylib, libjaccl.dylib and mlx.metallib.
  --derived-data PATH      Defaults to build/OmniXPCSmokeDerivedData.
  --app-sign-identity ID   Apple Development or Developer ID Application identity.
  --no-sign               Explicit unsigned structural build, NOT signed proof.

Required settings (Signing.local.xcconfig or environment):
  VOXT_OMNI_APP_GROUP_ID
  VOXT_OMNI_XPC_SERVICE_ID
  VOXT_OMNI_HOST_BUNDLE_IDENTIFIER
  VOXT_OMNI_TEAM_IDENTIFIER
  VOXT_OMNI_NATIVE_RUNTIME_DIR

Use the existing VOXT_CODE_SIGN_STYLE/VOXT_CODE_SIGN_IDENTITY local conventions.
Configure a real team and authorized App Group for BOTH bundle identifiers;
certificate/profile availability and App Group authorization are not assumed.
EOF
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "Apple Silicon macOS is required"
for executable in xcodebuild xcrun codesign security python3; do
  command -v "$executable" >/dev/null || fail "$executable is required"
done
for version in "$(sw_vers -productVersion)" "$(xcrun --sdk macosx --show-sdk-version)"; do
  IFS=. read -r major minor patch <<< "$version"
  [[ "$major" -gt 26 || ( "$major" -eq 26 && "${minor:-0}" -ge 2 ) ]] || fail "macOS and SDK 26.2 or newer are required (found $version)"
done

for setting in VOXT_OMNI_APP_GROUP_ID VOXT_OMNI_XPC_SERVICE_ID VOXT_OMNI_HOST_BUNDLE_IDENTIFIER VOXT_OMNI_TEAM_IDENTIFIER VOXT_OMNI_NATIVE_RUNTIME_DIR; do
  if [[ -n "${!setting:-}" ]]; then
    OVERRIDES+=("$setting=${!setting}")
  else
    :
  fi
done
mkdir -p "$DERIVED_DATA"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BUILD_ARGUMENTS=(
  -project "$ROOT/Voxt.xcodeproj"
  -scheme VoxtOmniXPCSmoke
  -configuration OmniXPCDebug
  -destination platform=macOS,arch=arm64
  -derivedDataPath "$DERIVED_DATA"
  -jobs 1
  "${OVERRIDES[@]}"
)
xcodebuild "${BUILD_ARGUMENTS[@]}" -showBuildSettings -json > "$WORK/settings.json"
python3 - "$WORK/settings.json" "$SIGN_APP" > "$WORK/resolved.sh" <<'PY'
import json
from pathlib import Path
import re
import shlex
import sys

settings = next(entry["buildSettings"] for entry in json.loads(Path(sys.argv[1]).read_text()) if entry["target"] == "Voxt")
required = (
    "VOXT_OMNI_APP_GROUP_ID", "VOXT_OMNI_XPC_SERVICE_ID",
    "VOXT_OMNI_HOST_BUNDLE_IDENTIFIER", "VOXT_OMNI_TEAM_IDENTIFIER",
)
for setting in required:
    value = settings.get(setting, "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]+", value):
        sys.exit(f"error: configure {setting} in Signing.local.xcconfig or the environment")
    else:
        print(f"export {setting}={shlex.quote(value)}")
team = settings["VOXT_OMNI_TEAM_IDENTIFIER"]
if not re.fullmatch(r"[A-Z0-9]{10}", team) or settings.get("DEVELOPMENT_TEAM") != team:
    sys.exit("error: DEVELOPMENT_TEAM must match the configured ten-character Omni team")
else:
    pass
if settings["VOXT_OMNI_XPC_SERVICE_ID"] == settings["VOXT_OMNI_HOST_BUNDLE_IDENTIFIER"]:
    sys.exit("error: host and service need distinct bundle identifiers")
else:
    pass
runtime = Path(settings.get("VOXT_OMNI_NATIVE_RUNTIME_DIR", ""))
if not runtime.is_absolute():
    sys.exit("error: VOXT_OMNI_NATIVE_RUNTIME_DIR must be an absolute prebuilt runtime directory")
else:
    pass
for filename in ("libOmniCore.dylib", "libmlx.dylib", "libjaccl.dylib", "mlx.metallib"):
    if not (runtime / "bin" / filename).is_file():
        sys.exit(f"error: missing prebuilt runtime file: {runtime / 'bin' / filename}")
    else:
        pass
if sys.argv[2] == "YES" and (
    settings.get("CODE_SIGNING_ALLOWED") == "NO"
    or settings.get("CODE_SIGN_IDENTITY", "") in ("", "-")
):
    sys.exit("error: signing disabled; use --no-sign only for an unsigned structural build")
else:
    pass
print(f"APP_PATH={shlex.quote(str(Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']))}")
PY
source "$WORK/resolved.sh"

if [[ "$SIGN_APP" == NO ]]; then
  echo "warning: unsigned structural build, NOT signed proof or a runnable App Group validation" >&2
else
  security find-identity -v -p codesigning >&2
fi
xcodebuild "${BUILD_ARGUMENTS[@]}" clean build >&2
[[ -d "$APP_PATH/Contents/XPCServices/OmniInference.xpc" ]] || fail "built app has no OmniInference service"

if [[ "$SIGN_APP" == YES ]]; then
  SERVICE="$APP_PATH/Contents/XPCServices/OmniInference.xpc"
  SIGNING_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$VOXT_OMNI_TEAM_IDENTIFIER\""
  for filename in libOmniCore.dylib libmlx.dylib libjaccl.dylib; do
    codesign --verify --strict --verbose=2 --test-requirement "$SIGNING_REQUIREMENT" "$SERVICE/Contents/Frameworks/$filename"
  done
  codesign --verify --deep --strict --verbose=2 "$SERVICE"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  python3 - "$APP_PATH" "$SERVICE" <<'PY'
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

expected = {
    "OmniAppGroupIdentifier": os.environ["VOXT_OMNI_APP_GROUP_ID"],
    "OmniInferenceServiceIdentifier": os.environ["VOXT_OMNI_XPC_SERVICE_ID"],
    "OmniHostBundleIdentifier": os.environ["VOXT_OMNI_HOST_BUNDLE_IDENTIFIER"],
    "OmniTeamIdentifier": os.environ["VOXT_OMNI_TEAM_IDENTIFIER"],
}
for bundle, identifier in zip(sys.argv[1:], (expected["OmniHostBundleIdentifier"], expected["OmniInferenceServiceIdentifier"])):
    metadata = plistlib.loads((Path(bundle) / "Contents/Info.plist").read_bytes())
    for field, value in {**expected, "CFBundleIdentifier": identifier}.items():
        if metadata.get(field) != value:
            sys.exit(f"error: {bundle}: incorrect {field}")
        else:
            pass
    requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{expected["OmniTeamIdentifier"]}"'
    subprocess.run(["codesign", "--verify", "--strict", "--test-requirement", requirement, bundle], check=True)
    signature = subprocess.run(["codesign", "--display", "--verbose=4", bundle], check=True, capture_output=True, text=True).stderr
    if not re.search(r"^Authority=(Apple Development:|Developer ID Application:)", signature, re.MULTILINE):
        sys.exit(f"error: {bundle}: not signed by Apple Development or Developer ID Application")
    elif f"TeamIdentifier={expected['OmniTeamIdentifier']}" not in signature.splitlines():
        sys.exit(f"error: {bundle}: signing team mismatch")
    else:
        pass
    entitlements = plistlib.loads(subprocess.run(["codesign", "--display", "--entitlements", ":-", bundle], check=True, capture_output=True).stdout)
    if entitlements.get("com.apple.security.application-groups") != [expected["OmniAppGroupIdentifier"]]:
        sys.exit(f"error: {bundle}: signed App Group mismatch")
    elif entitlements.get("com.apple.security.app-sandbox") is not True:
        sys.exit(f"error: {bundle}: sandbox entitlement missing")
    else:
        pass
PY
  echo "Signed bundle structure verified; run run_omni_xpc_smoke.sh separately for runtime proof." >&2
else
  echo "Unsigned structural build completed; no signing or App Group proof claimed." >&2
fi
printf '%s\n' "$APP_PATH"
