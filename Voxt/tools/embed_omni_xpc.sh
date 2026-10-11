#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

MODE="${1:-}"
case "$MODE" in
  --service) ;;
  --app)
    if [[ "${CONFIGURATION:-}" != OmniXPCDebug || "${VOXT_OMNI_EMBED_XPC:-NO}" != YES ]]; then
      exit 0
    else
      :
    fi
    ;;
  *) fail "usage: embed_omni_xpc.sh --service|--app (Xcode build phase only)" ;;
esac

[[ "${CONFIGURATION:-}" == OmniXPCDebug ]] || fail "OmniInference requires OmniXPCDebug"
[[ "${ARCHS:-}" == arm64 ]] || fail "OmniInference requires ARCHS=arm64"
for setting in VOXT_OMNI_APP_GROUP_ID VOXT_OMNI_XPC_SERVICE_ID VOXT_OMNI_HOST_BUNDLE_IDENTIFIER VOXT_OMNI_TEAM_IDENTIFIER; do
  [[ -n "${!setting:-}" && "${!setting}" != *'$('* ]] || fail "$setting must be configured in Signing.local.xcconfig or explicit build settings"
done

SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "$SIGNING_ALLOWED" != NO ]]; then
  [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != - ]] || fail "a real signing identity is required; CODE_SIGNING_ALLOWED=NO is structural-only"
else
  echo "warning: unsigned structural build, not signed XPC validation" >&2
fi

validate_macho() {
  local binary="$1"
  local install_name dependencies load_commands dependency runpath
  [[ "$(lipo -archs "$binary")" == arm64 ]] || fail "not an arm64-only Mach-O: $binary"
  if [[ "$binary" == *.dylib ]]; then
    install_name="$(otool -D "$binary" | awk 'NR == 2 {print $1}')"
    [[ "$install_name" == "@rpath/$(basename "$binary")" ]] || fail "non-relocatable install name in $binary: $install_name"
  else
    :
  fi
  dependencies="$(otool -L "$binary")"
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/libOmniCore.dylib|@rpath/libmlx.dylib|@rpath/libjaccl.dylib|@loader_path/libOmniCore.dylib|@loader_path/libmlx.dylib|@loader_path/libjaccl.dylib) ;;
      @rpath/libswift*.dylib) ;;
      *) fail "unbundled or non-relocatable dependency in $binary: $dependency" ;;
    esac
  done < <(printf '%s\n' "$dependencies" | awk 'NR > 1 {print $1}')
  load_commands="$(otool -l "$binary")"
  while IFS= read -r runpath; do
    case "$runpath" in
      @loader_path|@executable_path/../Frameworks|/usr/lib/swift) ;;
      *) fail "external runtime search path in $binary: $runpath" ;;
    esac
  done < <(printf '%s\n' "$load_commands" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
  if [[ "$binary" != *.dylib ]]; then
    grep -q '@rpath/libOmniCore.dylib ' <<< "$dependencies" || fail "service does not link OmniCore"
    grep -q 'path @executable_path/../Frameworks ' <<< "$load_commands" || fail "service is missing its bundled Frameworks rpath"
  else
    :
  fi
}

if [[ "$MODE" == --service ]]; then
  RUNTIME="${VOXT_OMNI_NATIVE_RUNTIME_DIR:?VOXT_OMNI_NATIVE_RUNTIME_DIR must name the prebuilt runtime directory}"
  for filename in libOmniCore.dylib libmlx.dylib libjaccl.dylib mlx.metallib; do
    [[ -f "$RUNTIME/bin/$filename" ]] || fail "missing prebuilt runtime file: $RUNTIME/bin/$filename"
  done
  for filename in libOmniCore.dylib libmlx.dylib libjaccl.dylib; do
    validate_macho "$RUNTIME/bin/$filename"
  done
  FRAMEWORKS="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
  rm -rf "$FRAMEWORKS"
  mkdir -p "$FRAMEWORKS"
  for filename in libOmniCore.dylib libmlx.dylib libjaccl.dylib mlx.metallib; do
    cp -L "$RUNTIME/bin/$filename" "$FRAMEWORKS/$filename"
  done
  if [[ "$SIGNING_ALLOWED" != NO ]]; then
    for filename in libOmniCore.dylib libmlx.dylib libjaccl.dylib; do
      codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$FRAMEWORKS/$filename"
      codesign --verify --strict --verbose=2 "$FRAMEWORKS/$filename"
    done
  else
    :
  fi
else
  SERVICE="${BUILT_PRODUCTS_DIR:?}/OmniInference.xpc"
  [[ -d "$SERVICE" ]] || fail "build OmniInference first with the VoxtOmniXPCSmoke scheme"
  validate_macho "$SERVICE/Contents/MacOS/OmniInference"
  for filename in libOmniCore.dylib libmlx.dylib libjaccl.dylib mlx.metallib; do
    [[ -f "$SERVICE/Contents/Frameworks/$filename" ]] || fail "missing service runtime: $filename"
  done
  python3 - "$SERVICE" <<'PY'
import os
from pathlib import Path
import plistlib
import sys

service = Path(sys.argv[1])
settings = {
    "CFBundleIdentifier": "VOXT_OMNI_XPC_SERVICE_ID",
    "OmniAppGroupIdentifier": "VOXT_OMNI_APP_GROUP_ID",
    "OmniInferenceServiceIdentifier": "VOXT_OMNI_XPC_SERVICE_ID",
    "OmniHostBundleIdentifier": "VOXT_OMNI_HOST_BUNDLE_IDENTIFIER",
    "OmniTeamIdentifier": "VOXT_OMNI_TEAM_IDENTIFIER",
}
metadata = plistlib.loads((service / "Contents/Info.plist").read_bytes())
for field, setting in settings.items():
    if metadata.get(field) != os.environ[setting]:
        sys.exit(f"error: stale service {field}; rebuild the complete smoke scheme")
    else:
        pass
expected = {"libOmniCore.dylib", "libmlx.dylib", "libjaccl.dylib", "mlx.metallib"}
if {path.name for path in (service / "Contents/Frameworks").iterdir()} != expected:
    sys.exit("error: unexpected service Frameworks contents")
else:
    pass
if {path.name for path in (service / "Contents/MacOS").iterdir()} != {"OmniInference"}:
    sys.exit("error: unexpected service executable (HTTP servers must not be embedded)")
else:
    pass
PY
  if [[ "$SIGNING_ALLOWED" != NO ]]; then
    REQUIREMENT="anchor apple generic and identifier \"$VOXT_OMNI_XPC_SERVICE_ID\" and certificate leaf[subject.OU] = \"$VOXT_OMNI_TEAM_IDENTIFIER\""
    codesign --verify --deep --strict --verbose=2 --test-requirement "$REQUIREMENT" "$SERVICE"
  else
    :
  fi
  DESTINATION="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/XPCServices"
  mkdir -p "$DESTINATION"
  rm -rf "$DESTINATION/OmniInference.xpc"
  ditto "$SERVICE" "$DESTINATION/OmniInference.xpc"
fi
