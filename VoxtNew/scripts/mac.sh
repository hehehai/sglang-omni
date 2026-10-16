#!/usr/bin/env bash
# Mirrors this project to a Mac and runs a command there, for developing on
# Linux. The Mac needs Xcode (for the Swift helper) and Go (GOTOOLCHAIN=auto
# fetches the Go the module asks for).
#
#   scripts/mac.sh go tool mygo build
#   scripts/mac.sh go test ./internal/secrets
#   scripts/mac.sh --pull build/darwin-arm64   # copy a path back
#
# MAC_HOST (default mac-air) and MAC_DIR (default code/VoxtNew) pick the
# target; MAC_GOPROXY its Go module proxy (proxy.golang.org times out there).
set -euo pipefail

HOST="${MAC_HOST:-mac-air}"
GOPROXY_MAC="${MAC_GOPROXY:-https://goproxy.cn,direct}"
DIR="${MAC_DIR:-code/VoxtNew}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--pull" ]]; then
  shift
  for p in "$@"; do
    mkdir -p "$ROOT/$(dirname "$p")"
    rsync -a --delete "$HOST:$DIR/$p/" "$ROOT/$p/"
  done
  exit 0
fi

ssh "$HOST" "mkdir -p '$DIR'"
rsync -a --delete \
  --exclude .git --exclude /build --exclude /.mygo \
  --exclude /helper/.build --exclude /resources/darwin-arm64 \
  --exclude /VoxtNew \
  "$ROOT/" "$HOST:$DIR/"

[[ $# -eq 0 ]] && exit 0
# shellcheck disable=SC2029
ssh "$HOST" "cd '$DIR' && export PATH=/opt/homebrew/bin:\$PATH GOTOOLCHAIN=auto GOPROXY='$GOPROXY_MAC' && $*"
