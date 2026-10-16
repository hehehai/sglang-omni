#!/usr/bin/env bash
# Checks a build of Auralink (docs/release.md): its signatures, the
# entitlements of the app and of the helper and, for a Developer ID build,
# the hardened runtime, the timestamps, Gatekeeper's verdict, the stapled
# notarization tickets and the update files. The release workflow runs it
# after `go tool mygo build`.
#
#   scripts/release-verify.sh build/darwin-arm64 developer-id
#   scripts/release-verify.sh build/darwin-arm64 ad-hoc
#   scripts/release-verify.sh DIR ad-hoc --no-dmg   # a build with -skip-dmg
#
# EXPECT_TEAM, when set, is the Team ID a Developer ID build must be signed
# by (the release workflow's APPLE_TEAM_ID).
set -euo pipefail

dir="${1:?the build directory, e.g. build/darwin-arm64}"
mode="${2:?developer-id or ad-hoc}"
want_dmg=1
[[ "${3:-}" == --no-dmg ]] && want_dmg=0
app="$dir/Auralink.app"
helper="$app/Contents/Resources/helper/auralink-helper"
fails=0

check() { # check "what" command...
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    "$@" 2>&1 | sed 's/^/     /' | tail -20 || true
    fails=$((fails + 1))
  fi
}
# details CODE: what codesign says about CODE's signature.
details() { codesign -dv --verbose=4 "$1" 2>&1; }
# (Read whole before grep -q, which would cut codesign off: pipefail.)
has() { # has CODE PATTERN: codesign's details of CODE match PATTERN
  local d
  d="$(details "$1")"
  grep -qE "$2" <<<"$d"
}
entitled() { # entitled CODE KEY: CODE is signed with the entitlement KEY
  local e
  e="$(codesign -d --entitlements - --xml "$1" 2>/dev/null)"
  grep -q "<key>$2</key><true/>" <<<"$e"
}

[[ -d "$app" ]] || { echo "no $app" >&2; exit 1; }
[[ -f "$helper" ]] || { echo "no $helper" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
echo "Auralink $version ($mode) in $dir"

check "the app's signature (deep, strict)" codesign --verify --deep --strict --verbose=2 "$app"
check "the helper's signature (strict)" codesign --verify --strict --verbose=2 "$helper"
check "the helper is dev.hehehai.auralink.helper" has "$helper" '^Identifier=dev\.hehehai\.auralink\.helper$'
check "the app may use the microphone (audio-input)" entitled "$app" com.apple.security.device.audio-input
check "the helper may use the microphone (audio-input)" entitled "$helper" com.apple.security.device.audio-input
check "the helper is arm64" test "$(lipo -archs "$helper")" = arm64
dmg="$(compgen -G "$dir/*.dmg" | head -1 || true)"
((want_dmg)) && check "a disk image" test -n "$dmg"

if [[ "$mode" == developer-id ]]; then
  for code in "$app" "$helper"; do
    name="$(basename "$code")"
    check "$name: Developer ID Application" has "$code" '^Authority=Developer ID Application: '
    check "$name: hardened runtime" has "$code" '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)'
    check "$name: secure timestamp" has "$code" '^Timestamp='
  done
  team_app="$(details "$app" | sed -n 's/^TeamIdentifier=//p')"
  team_helper="$(details "$helper" | sed -n 's/^TeamIdentifier=//p')"
  check "one team ($team_app) signs both" test -n "$team_app" -a "$team_app" = "$team_helper"
  [[ -n "${EXPECT_TEAM:-}" ]] && check "the team is APPLE_TEAM_ID's" test "$team_app" = "$EXPECT_TEAM"
  verdict="$(spctl -a -vv -t exec "$app" 2>&1 || true)"
  check "Gatekeeper accepts the app (notarized)" grep -q 'source=Notarized Developer ID' <<<"$verdict"
  check "the app's ticket is stapled" xcrun stapler validate "$app"
  [[ -n "$dmg" ]] && check "the disk image's ticket is stapled" xcrun stapler validate "$dmg"
  [[ -n "$dmg" ]] && check "Gatekeeper accepts the disk image" spctl -a -vv -t open --context context:primary-signature "$dmg"
  manifest="$dir/update-darwin-arm64.json"
  check "the update archive" bash -c "compgen -G '$dir/*-$version-darwin-arm64.tar.gz'"
  check "the update manifest says $version" bash -c "jq -e --arg v '$version' '.version == \$v and (.signature | length > 0)' '$manifest'"
else
  check "signed ad hoc" has "$app" '^Signature=adhoc$'
fi
# CFBundleVersion is the version's numbers (MyGo patch 0007), as Apple wants.
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
numbers() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; }
check "CFBundleVersion $build_version is numbers" numbers "$build_version"

if ((fails > 0)); then
  echo "$fails checks failed" >&2
  exit 1
fi
echo "all checks passed"
