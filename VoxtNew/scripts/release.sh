#!/usr/bin/env bash
# The release build of VoxtNew, on an Apple silicon Mac (docs/release.md):
# the helper, the Omni runtime (speech) and voxtnew-llm (language models)
# are built and staged into resources/darwin-arm64/, then go tool mygo
# build makes build/darwin-arm64/VoxtNew.app and its disk image with all
# of them inside, and scripts/release-verify.sh checks the result.
#
#   scripts/release.sh                                  # ad hoc: a release-style test build
#   VOXTNEW_SIGN_IDENTITY="Developer ID Application: wei guan (779M533DL5)" \
#     scripts/release.sh [--notarize PROFILE] [--publish]
#
# Options:
#   --runtimes DIR       take the runtimes prebuilt from DIR/omni and DIR/llm
#                        (scripts/build-omni.sh --out DIR/omni, scripts/build-llm.sh
#                        --out DIR/llm; mac-air: ~/voxtnew-runtime) instead of
#                        building them (about 10 minutes and 3 GB of build trees)
#   --notarize PROFILE   notarize with notarytool's keychain profile PROFILE
#                        (xcrun notarytool store-credentials PROFILE …), then
#                        staple the app and the disk image; needs the identity
#   --keychain FILE      the keychain holding PROFILE (default: the login keychain)
#   --publish            publish on actnow.dev with scripts/actnow-publish.sh
#                        (ACTNOW_INGEST_TOKEN); needs a notarized Developer ID
#                        build with update files (MYGO_UPDATER_PRIVATE_KEY).
#                        Without it, a build with update files gets the
#                        script's --dry-run
#   --keep-runtimes      leave the staged runtimes in resources/darwin-arm64
#
# With VOXTNEW_SIGN_IDENTITY (a Developer ID Application identity, its name
# or SHA-1: scripts/release-identity.sh TEAMID) the helper, the LLM and then
# every Mach-O file and framework inside the app are signed with it, with
# the hardened runtime and a secure timestamp (mygo build: signNestedCode),
# and the build takes the update feed of release/mygo.release.json
# (scripts/release-config.sh; MYGO_UPDATER_PRIVATE_KEY signs the update
# files). Without it everything is signed ad hoc and the app has no update
# feed, as every development build.
#
# Over ssh, codesign cannot use a key of the locked login keychain
# (errSecInternalComponent): run it in Terminal on the Mac, or unlock the
# keychain first (security unlock-keychain). mygo.json is put back as it
# was at the end, whatever happens.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != arm64 ]]; then
  echo "the release builds on an Apple silicon Mac: scripts/mac.sh scripts/release.sh" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNTIMES="" PROFILE="" KEYCHAIN="" PUBLISH=0 KEEP=0
while (($#)); do
  case "$1" in
    --runtimes) RUNTIMES="$(cd "${2:?--runtimes needs a directory}" && pwd)"; shift 2 ;;
    --notarize) PROFILE="${2:?--notarize needs a notarytool keychain profile}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:?--keychain needs a keychain file}"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    --keep-runtimes) KEEP=1; shift ;;
    -h | --help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "release.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
IDENTITY="${VOXTNEW_SIGN_IDENTITY:-}"
if [[ -n "$PROFILE" && -z "$IDENTITY" ]]; then
  echo "notarization needs a Developer ID: set VOXTNEW_SIGN_IDENTITY" >&2
  exit 2
fi
if ((PUBLISH)) && [[ -z "$PROFILE" || -z "${MYGO_UPDATER_PRIVATE_KEY:-}" || -z "${ACTNOW_INGEST_TOKEN:-}" ]]; then
  echo "--publish needs --notarize, MYGO_UPDATER_PRIVATE_KEY and ACTNOW_INGEST_TOKEN" >&2
  exit 2
fi
command -v jq >/dev/null || { echo "release.sh needs jq" >&2; exit 1; }

# One version everywhere: the app, the helper, the LLM, the notes.
version="$(jq -r .version mygo.json)"
for plist in helper/Support/Info.plist llm/Support/Info.plist; do
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  if [[ "$v" != "$version" ]]; then
    echo "$plist says $v, mygo.json $version: make them agree (docs/release.md §2.1)" >&2
    exit 1
  fi
done
notes="$(awk -v v="$version" '/^## /{f = index($0, "[" v "]") || $2 == v; next} f' CHANGELOG.md)"
if [[ -z "${notes//[[:space:]]/}" ]]; then
  if ((PUBLISH)); then
    echo "CHANGELOG.md has no section for $version" >&2
    exit 1
  else
    echo "note: CHANGELOG.md has no section for $version yet (the update window shows it)"
  fi
else
  :
fi
channel=stable
if [[ "$version" == *-* ]]; then
  channel=beta
else
  :
fi
echo "== VoxtNew $version ($channel), signed ${IDENTITY:-ad hoc}${PROFILE:+, notarized with $PROFILE}"

RES="$ROOT/resources/darwin-arm64"
saved="$(mktemp -d)"
cp mygo.json "$saved/mygo.json"
restore() {
  cp "$saved/mygo.json" "$ROOT/mygo.json"
  rm -rf "$saved"
  if ((KEEP == 0)); then
    rm -rf "$RES/omni" "$RES/llm"
  else
    :
  fi
}
trap restore EXIT

echo "== helper"
VOXTNEW_SIGN_IDENTITY="${IDENTITY:--}" scripts/build-helper.sh
if [[ -n "$RUNTIMES" ]]; then
  echo "== runtimes from $RUNTIMES"
  for part in omni llm; do
    [[ -d "$RUNTIMES/$part" ]] || { echo "no $RUNTIMES/$part" >&2; exit 1; }
    rm -rf "${RES:?}/$part"
    mkdir -p "$RES"
    # APFS clones: no copy on disk.
    cp -Rc "$RUNTIMES/$part" "$RES/$part"
  done
else
  echo "== Omni runtime"
  scripts/build-omni.sh --clean
  echo "== voxtnew-llm"
  VOXTNEW_SIGN_IDENTITY="${IDENTITY:--}" scripts/build-llm.sh
fi
[[ -x "$RES/omni/bin/qwen3_asr_server" ]] || { echo "no Omni runtime in $RES/omni" >&2; exit 1; }
[[ -x "$RES/llm/voxtnew-llm" ]] || { echo "no voxtnew-llm in $RES/llm" >&2; exit 1; }

echo "== configuration"
if [[ -n "$IDENTITY" ]]; then
  scripts/release-config.sh --sign "$IDENTITY" ${PROFILE:+--notary-profile "$PROFILE"} ${KEYCHAIN:+--notary-keychain "$KEYCHAIN"}
  if [[ -z "${MYGO_UPDATER_PRIVATE_KEY:-}" ]]; then
    echo "note: no MYGO_UPDATER_PRIVATE_KEY: no update files (a release needs them)"
  else
    :
  fi
else
  echo "ad hoc: mygo.json as it is (no update feed, no notarization)"
fi

echo "== mygo build"
args=(-platform darwin/arm64)
[[ -n "$IDENTITY" ]] && args+=(-sign "$IDENTITY")
go tool mygo build "${args[@]}"

echo "== verify"
mode=ad-hoc
if [[ -n "$PROFILE" ]]; then
  mode=developer-id
elif [[ -n "$IDENTITY" ]]; then
  mode=signed
else
  :
fi
scripts/release-verify.sh build/darwin-arm64 "$mode"

if compgen -G "build/darwin-arm64/update-*.json" >/dev/null; then
  echo "== actnow.dev ($channel)"
  publish=(--app voxtnew --channel "$channel" --dir build/darwin-arm64 --changelog CHANGELOG.md --min-macos 15.0 --version "$version")
  if ((PUBLISH)); then
    bash scripts/actnow-publish.sh "${publish[@]}"
  else
    bash scripts/actnow-publish.sh "${publish[@]}" --dry-run
  fi
else
  echo "no update files: nothing to publish"
fi
du -sh build/darwin-arm64/VoxtNew.app build/darwin-arm64/*.dmg 2>/dev/null | sed 's/^/built /'
