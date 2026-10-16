#!/usr/bin/env bash
# The update test (docs/release.md, "Testing updates"): two versions of
# Auralink, 0.1.0-test and 0.1.1-test, signed ad hoc, with a test key
# that signs their updates, published on a feed served over HTTPS on the
# loopback interface (scripts/update-server); the installed 0.1.0-test is
# then updated by the real updater, driven without a window
# (--update-check, -tags updatecheck: update_check.go):
#
#   A. the delta: found, downloaded alone, installed; the bundle on disk is
#      0.1.1-test file for file (code signature included), its helper the
#      new one, and the supervisor of the old app starts no helper;
#   B. the archive, when the feed has no delta;
#   C. the archive after a delta that fails (an installed file changed);
#   D. 0.1.1-test is up to date.
#
# Its own bundle ID (dev.hehehai.auralink.updtest) and directory, on a Mac
# that may be busy with other work: no window, no app activated, no key,
# no clipboard, no helper started, no keychain; niced, two jobs, and it
# stops when less than AURALINK_MIN_FREE percent of memory (40) is free.
# The test key, the builds and the feed are removed at the end
# (KEEP=1 keeps them in build/update-e2e).
#
#   MAC_DIR=code/Auralink-upd scripts/mac.sh scripts/mac-update-e2e.sh
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run it on a Mac: MAC_DIR=code/Auralink-upd scripts/mac.sh scripts/mac-update-e2e.sh" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$ROOT" == "$HOME/code/Auralink" ]]; then
  echo "not in the app's own checkout: use MAC_DIR=code/Auralink-upd" >&2
  exit 1
fi
export GOMAXPROCS=2 GOFLAGS=-p=2 SWIFT_BUILD_JOBS=2
unset AURALINK_HELPER
ID=dev.hehehai.auralink.updtest
V0=0.1.0-test V1=0.1.1-test
WORK="$ROOT/build/update-e2e"
FAILS=0

step() {
  local free
  free="$(memory_pressure -Q | sed -n 's/.*percentage: \([0-9]*\)%.*/\1/p')"
  echo "== $1 (free memory ${free}%)"
  if (( ${free:-0} < ${AURALINK_MIN_FREE:-40} )); then
    echo "less than ${AURALINK_MIN_FREE:-40}% of memory is free: stopping" >&2
    exit 3
  fi
}
check() { # check "what" command...: one line, ok or FAIL
  local what="$1"
  shift
  if "$@"; then
    echo "  ok   $what"
  else
    echo "  FAIL $what"
    FAILS=$((FAILS + 1))
  fi
}

server_pid=""
cleanup() {
  local rc=$?
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  for f in mygo.json helper/Support/Info.plist CHANGELOG.md; do
    [[ -f "$WORK/orig/$f" ]] && cp "$WORK/orig/$f" "$f"
  done
  rm -rf resources/darwin-arm64
  if [[ "${KEEP:-0}" != 1 ]]; then
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"/{feed,keys,orig/helper/Support}
cp mygo.json CHANGELOG.md "$WORK/orig/"
cp helper/Support/Info.plist "$WORK/orig/helper/Support/"

step "Go modules and the tools (before SSL_CERT_FILE, which trusts the test certificate only)"
nice -n 10 go mod download
nice -n 10 go build -o "$WORK/update-server" ./scripts/update-server
nice -n 10 go build -tags updatecheck -o /dev/null .

step "a test key and the feed"
go tool mygo keygen -o "$WORK/keys" >/dev/null
chmod 600 "$WORK/keys/mygo-update.key"
"$WORK/update-server" -dir "$WORK/feed" -cert "$WORK/cert.pem" -url "$WORK/url.txt" >"$WORK/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 50); do [[ -s "$WORK/url.txt" ]] && break; sleep 0.1; done
URL="$(cat "$WORK/url.txt")"
jq -n --arg id "$ID" --arg key "$(cat "$WORK/keys/mygo-update.pub")" --arg url "$URL" \
  '{identifier: $id, updates: {publicKey: $key, url: $url}}' >"$WORK/overlay.json"
echo "  feed $URL"

# The release notes of both versions, as docs/release.md has them: English,
# then Chinese.
{
  sed -n '1,4p' "$WORK/orig/CHANGELOG.md"
  printf '## [%s] - 2026-10-16\n\n### Fixed\n\n- The update test.\n\n### 修复\n\n- 更新测试。\n\n' "$V1"
  printf '## [%s] - 2026-10-16\n\n### Added\n\n- The first test version.\n\n### 新增\n\n- 第一个测试版本。\n\n' "$V0"
  sed -n '5,$p' "$WORK/orig/CHANGELOG.md"
} >CHANGELOG.md

# build VERSION: the helper and the app of VERSION into $WORK/out-VERSION.
build() {
  local v="$1"
  cp "$WORK/orig/mygo.json" mygo.json
  scripts/release-config.sh --overlay "$WORK/overlay.json" >/dev/null
  jq --arg v "$v" '.version = $v' mygo.json >"$WORK/mygo.json" && cat "$WORK/mygo.json" >mygo.json
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" helper/Support/Info.plist
  nice -n 10 scripts/build-helper.sh >/dev/null
  # The CLI fetches the published version for its delta: the test
  # certificate, and no module downloads past this point.
  SSL_CERT_FILE="$WORK/cert.pem" GOPROXY=off GOFLAGS="$GOFLAGS -tags=updatecheck" \
    MYGO_UPDATER_PRIVATE_KEY="$(cat "$WORK/keys/mygo-update.key")" \
    nice -n 10 go tool mygo build -platform darwin/arm64 -skip-dmg -o "$WORK/out-$v" >"$WORK/build-$v.log" 2>&1 ||
    { tail -30 "$WORK/build-$v.log" >&2; exit 1; }
  grep -iE "delta|update" "$WORK/build-$v.log" | sed 's/^/  build: /' || true
}

# publish VERSION: its files on the feed, the manifest last.
publish() {
  local out="$WORK/out-$1/darwin-arm64"
  cp "$out"/*.tar.gz "$WORK/feed/"
  cp "$out"/*.delta "$WORK/feed/" 2>/dev/null || true
  cp "$out/update-darwin-arm64.json" "$WORK/feed/"
}

# install: 0.1.0-test from its archive, as a user has it.
install_v0() {
  rm -rf "$WORK/inst"
  mkdir -p "$WORK/inst"
  tar -xzf "$WORK/out-$V0/darwin-arm64/"*.tar.gz -C "$WORK/inst"
}

# run REPORT: the installed app's update check.
run_check() {
  SSL_CERT_FILE="$WORK/cert.pem" nice -n 10 "$WORK/inst/Auralink.app/Contents/MacOS/Auralink" --update-check "$1"
}

step "build $V0"
build "$V0"
publish "$V0"
step "build $V1 (with its delta from $V0)"
build "$V1"
NEW="$WORK/out-$V1/darwin-arm64/Auralink.app"
OLD="$WORK/out-$V0/darwin-arm64/Auralink.app"
check "$V1 has a delta from $V0" bash -c "compgen -G '$WORK/out-$V1/darwin-arm64/*-to-$V1-*.delta' >/dev/null"
check "the helpers of the two versions differ" \
  bash -c "! cmp -s '$OLD/Contents/Resources/helper/auralink-helper' '$NEW/Contents/Resources/helper/auralink-helper'"
check "the build passes release-verify.sh (ad hoc)" scripts/release-verify.sh "$WORK/out-$V1/darwin-arm64" ad-hoc --no-dmg
publish "$V1"
MANIFEST="$WORK/feed/update-darwin-arm64.json"
cp "$MANIFEST" "$WORK/manifest-with-delta.json"
delta_size="$(jq -r --arg v "$V0" '.deltas[] | select(.from == $v) | .size' "$MANIFEST")"
archive_size="$(jq -r .size "$MANIFEST")"
echo "  delta $delta_size bytes, archive $archive_size bytes"

# verify REPORT TOTALS: the installed app is V1, exactly the published
# bundle; TOTALS the downloads the report must show.
verify() {
  local r="$1" totals="$2" app="$WORK/inst/Auralink.app"
  check "it found $V1" test "$(jq -r .found "$r")" = "$V1"
  check "it was enabled and ran $V0" test "$(jq -r '"\(.enabled) \(.running)"' "$r")" = "true $V0"
  check "the notes are $V1's, English and Chinese" bash -c "jq -r .notes '$r' | grep -q 'The update test' && jq -r .notes '$r' | grep -q '更新测试'"
  check "installed without an error" test -z "$(jq -r .installErr "$r")"
  check "downloads $totals" test "$(jq -c .totals "$r")" = "$totals"
  check "the bundle on disk says $V1" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$V1"
  check "the bundle is the published one, file for file" diff -r "$app" "$NEW"
  check "its signature verifies (deep, strict)" codesign --verify --deep --strict "$app"
  check "the same code directory hash" test "$(codesign -dv "$app" 2>&1 | grep CDHash=)" = "$(codesign -dv "$NEW" 2>&1 | grep CDHash=)"
  check "the helper is the new one" cmp -s "$app/Contents/Resources/helper/auralink-helper" "$NEW/Contents/Resources/helper/auralink-helper"
  check "the helper's signature verifies" codesign --verify --strict "$app/Contents/Resources/helper/auralink-helper"
  check "the old app sees the update" test "$(jq -r '"\(.diskVersion) \(.stale)"' "$r")" = "$V1 true"
  check "its supervisor starts no helper (updated)" test "$(jq -r '"\(.helperState) \(.helperReason) \(.helperPID)"' "$r")" = "failed updated 0"
  check "nothing left next to the app" test -z "$(find "$WORK/inst" -maxdepth 1 -name '.Auralink.app.*' -print)"
}

step "A: the delta"
install_v0
: >"$WORK/server.log"
run_check "$WORK/report-delta.json"
verify "$WORK/report-delta.json" "[$delta_size]"
check "the feed served the delta, not the archive" \
  bash -c "grep -q '\.delta' '$WORK/server.log' && ! grep -q '\.tar\.gz' '$WORK/server.log'"

step "B: the archive (a feed without the delta)"
jq 'del(.deltas)' "$WORK/manifest-with-delta.json" >"$MANIFEST"
install_v0
run_check "$WORK/report-archive.json"
verify "$WORK/report-archive.json" "[$archive_size]"

step "C: the archive after a delta that fails (the installed app was changed)"
cp "$WORK/manifest-with-delta.json" "$MANIFEST"
install_v0
printf 'x' >>"$WORK/inst/Auralink.app/Contents/Resources/icon.png"
run_check "$WORK/report-fallback.json"
verify "$WORK/report-fallback.json" "[$delta_size,$archive_size]"

step "D: $V1 is up to date"
run_check "$WORK/report-current.json"
check "nothing found" test "$(jq -r '"\(.running) [\(.found)] [\(.checkErr)] \(.stale)"' "$WORK/report-current.json")" = "$V1 [] [] false"

if pgrep -f "$WORK/inst/Auralink.app/Contents/Resources/helper/auralink-helper" >/dev/null; then
  echo "  FAIL a helper is running" && FAILS=$((FAILS + 1))
fi
if (( FAILS > 0 )); then
  echo "== $FAILS checks failed" >&2
  exit 1
fi
echo "== all checks passed; the test key, the builds and the feed are removed"
