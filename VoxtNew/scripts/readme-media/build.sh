#!/usr/bin/env bash
# Builds the demo app (-tags demo, demo.go) for the README's media, on the
# Mac, in a mirror of its own: another bundle ID (dev.hehehai.auralink.demo)
# so it shares nothing with an installed Auralink. Also builds
# alcap (the capture tool).
#
#   MAC_DIR=code/Auralink-demo scripts/mac.sh scripts/readme-media/build.sh
set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "run it on a Mac (scripts/mac.sh)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[[ "$ROOT" != "$HOME/code/Auralink" ]] || { echo "not in the main mirror: MAC_DIR=code/Auralink-demo" >&2; exit 1; }
export GOMAXPROCS=2 GOFLAGS="-p=2 -tags=demo" SWIFT_BUILD_JOBS=2
# With the release's updates (GitHub Releases), so that Settings → About
# shows them as a release does; it finds nothing newer than itself.
scripts/release-config.sh >/dev/null
tmp="$(mktemp)"
jq '.identifier = "dev.hehehai.auralink.demo"' mygo.json >"$tmp" && mv "$tmp" mygo.json
nice -n 10 scripts/build-helper.sh >/dev/null
nice -n 10 go tool mygo build 2>&1 | tail -3
id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/darwin-arm64/Auralink.app/Contents/Info.plist)"
[[ "$id" == dev.hehehai.auralink.demo ]] || { echo "unexpected bundle ID $id" >&2; exit 1; }
nice -n 10 swiftc -O scripts/readme-media/alcap.swift -o build/alcap
echo "built $id and build/alcap"
