#!/usr/bin/env bash
# The beta channel's test (docs/release.md §6): five versions of VoxtNew,
# signed ad hoc with a test key, published one after another as GitHub
# would hold them, betas as prereleases, on a fake GitHub
# (scripts/update-server -github: an HTTPS proxy that answers for
# github.com and api.github.com itself and refuses every other host, so
# nothing reaches the real one):
#
#   0.1.0-beta.1, 0.1.0-beta.2   betas before any release
#   0.1.0                        the first release
#   0.2.0-beta.1                 a beta of the next version
#   0.1.1                        a fix released after that beta
#
# Each version is built as the release workflow builds it (updates of
# release/mygo.release.json: github and prereleases), so its deltas come
# from what is published at that point. After each publication installed
# versions check for updates with Beta updates on, off or as by default
# (--update-check, -tags updatecheck: update_check.go), and install what
# they find with the real updater: a beta takes the next beta and the
# release, a release ignores betas unless asked, nothing goes back, a
# delta when there is one and the archive when it fails, and with the
# GitHub API refused (its limit) betas fall back to the latest release.
#
# Its own bundle ID (dev.hehehai.voxtnew.betatest), repository name
# (voxtnew-test/VoxtNew) and directory, on a Mac that may be busy with
# other work: no window, no app activated, no key, no clipboard, no helper
# started, no keychain; niced, two jobs, and it stops when less than
# VOXTNEW_MIN_FREE percent of memory (40) is free. The test key, the
# builds and the fake GitHub are removed at the end (KEEP=1 keeps them in
# build/beta-e2e).
#
#   MAC_DIR=code/VoxtNew-upd scripts/mac.sh scripts/mac-beta-e2e.sh
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run it on a Mac: MAC_DIR=code/VoxtNew-upd scripts/mac.sh scripts/mac-beta-e2e.sh" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$ROOT" == "$HOME/code/VoxtNew" ]]; then
  echo "not in the app's own checkout: use MAC_DIR=code/VoxtNew-upd" >&2
  exit 1
fi
export GOMAXPROCS=2 GOFLAGS=-p=2 SWIFT_BUILD_JOBS=2
unset VOXTNEW_HELPER GH_TOKEN GITHUB_TOKEN
ID=dev.hehehai.voxtnew.betatest
REPO=voxtnew-test/VoxtNew
B1=0.1.0-beta.1 B2=0.1.0-beta.2 R1=0.1.0 B3=0.2.0-beta.1 R2=0.1.1
WORK="$ROOT/build/beta-e2e"
GH="$WORK/github"
FAILS=0 RUNS=0

step() {
  local free
  free="$(memory_pressure -Q | sed -n 's/.*percentage: \([0-9]*\)%.*/\1/p')"
  echo "== $1 (free memory ${free}%)"
  if ((${free:-0} < ${VOXTNEW_MIN_FREE:-40})); then
    echo "less than ${VOXTNEW_MIN_FREE:-40}% of memory is free: stopping" >&2
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
mkdir -p "$WORK"/{keys,orig/helper/Support} "$GH"
cp mygo.json CHANGELOG.md "$WORK/orig/"
cp helper/Support/Info.plist "$WORK/orig/helper/Support/"

step "Go modules and the tools (before the proxy and SSL_CERT_FILE)"
nice -n 10 go mod download
nice -n 10 go build -o "$WORK/update-server" ./scripts/update-server
nice -n 10 go build -tags updatecheck -o /dev/null .

step "a test key and the fake GitHub"
go tool mygo keygen -o "$WORK/keys" >/dev/null
chmod 600 "$WORK/keys/mygo-update.key"
# A draft, which nothing may take.
echo '[{"tag_name": "v0.3.0-beta.1", "draft": true, "prerelease": true}]' >"$GH/releases.json"
"$WORK/update-server" -github "$REPO" -dir "$GH" -cert "$WORK/cert.pem" -url "$WORK/proxy.txt" >"$WORK/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 50); do [[ -s "$WORK/proxy.txt" ]] && break; sleep 0.1; done
PROXY="$(cat "$WORK/proxy.txt")"
# The release's updates (github, prereleases) with the test key and repository.
jq --arg id "$ID" --arg key "$(cat "$WORK/keys/mygo-update.pub")" --arg repo "$REPO" \
  '.identifier = $id | .updates.publicKey = $key | .updates.github = $repo' release/mygo.release.json >"$WORK/overlay.json"
jq -e '.updates.prereleases == true' "$WORK/overlay.json" >/dev/null
echo "  proxy $PROXY for github.com/$REPO"

# The notes of every version, English then Chinese.
{
  sed -n '1,4p' "$WORK/orig/CHANGELOG.md"
  for v in "$R2" "$B3" "$R1" "$B2" "$B1"; do
    printf '## [%s] - 2026-10-16\n\n### Changed\n\n- Test version %s.\n\n### 变更\n\n- 测试版本 %s。\n\n' "$v" "$v" "$v"
  done
} >CHANGELOG.md

# github ENV... COMMAND: COMMAND with GitHub being the fake one.
github() { HTTPS_PROXY="$PROXY" SSL_CERT_FILE="$WORK/cert.pem" "$@"; }

# build VERSION: the helper and the app of VERSION into $WORK/out-VERSION,
# its deltas from what is published.
build() {
  local v="$1"
  cp "$WORK/orig/mygo.json" mygo.json
  scripts/release-config.sh --overlay "$WORK/overlay.json" >/dev/null
  jq --arg v "$v" '.version = $v' mygo.json >"$WORK/mygo.json" && cat "$WORK/mygo.json" >mygo.json
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $v" helper/Support/Info.plist
  nice -n 10 scripts/build-helper.sh >/dev/null
  GOPROXY=off GOFLAGS="$GOFLAGS -tags=updatecheck" MYGO_UPDATER_PRIVATE_KEY="$(cat "$WORK/keys/mygo-update.key")" \
    github nice -n 10 go tool mygo build -platform darwin/arm64 -skip-dmg -o "$WORK/out-$v" >"$WORK/build-$v.log" 2>&1 ||
    { tail -30 "$WORK/build-$v.log" >&2; exit 1; }
  grep -iE "delta" "$WORK/build-$v.log" | sed 's/^/  build: /' || true
}

# deltas VERSION: the versions VERSION's manifest has deltas from.
deltas() { jq -r '[.deltas[]?.from] | join(" ")' "$WORK/out-$1/darwin-arm64/update-darwin-arm64.json"; }

# publish VERSION: its files under its tag, then the release listed (a
# prerelease for a beta), newest first.
publish() {
  local v="$1" out="$WORK/out-$1/darwin-arm64" pre=false
  [[ "$v" == *-* ]] && pre=true
  mkdir -p "$GH/v$v"
  cp "$out"/*.tar.gz "$out/update-darwin-arm64.json" "$GH/v$v/"
  cp "$out"/*.delta "$GH/v$v/" 2>/dev/null || true
  jq --arg t "v$v" --argjson pre "$pre" '[{tag_name: $t, draft: false, prerelease: $pre}] + .' "$GH/releases.json" >"$WORK/releases.json"
  cat "$WORK/releases.json" >"$GH/releases.json"
  echo "  published v$v (prerelease: $pre)"
}

# expect NAME FROM BETA WANT HOW: installs FROM from its archive, checks
# for updates with Beta updates BETA (on, off, default), which must find
# WANT ("" for none) and install it by HOW: delta (its delta from FROM
# only), fallback (the delta, then the archive: the installed app was
# changed) or archive; NOTE is what a check that finds nothing says
# (notPublished, an error's words, or "" for nothing).
expect() {
  local name="$1" from="$2" beta="$3" want="$4" how="${5:-}" note="${6:-}"
  local r="$WORK/report-$name.json" app="$WORK/inst/VoxtNew.app" args=()
  RUNS=$((RUNS + 1))
  echo "-- $name: $from, beta $beta → ${want:-nothing}${how:+ ($how)}"
  rm -rf "$WORK/inst" && mkdir -p "$WORK/inst"
  tar -xzf "$WORK/out-$from/darwin-arm64/"*.tar.gz -C "$WORK/inst"
  [[ "$how" == fallback ]] && printf 'x' >>"$app/Contents/Resources/icon.png"
  [[ "$beta" != default ]] && args=(--update-beta "$beta")
  local before
  before="$(wc -l <"$WORK/server.log")"
  github nice -n 10 "$app/Contents/MacOS/VoxtNew" --update-check "$r" ${args[@]+"${args[@]}"}
  local served
  served="$(tail -n +"$((before + 1))" "$WORK/server.log")"
  local on=false
  [[ "$beta" == on || "$beta" == default && "$from" == *-* ]] && on=true
  check "running $from, betas $on" test "$(jq -r '"\(.running) \(.beta)"' "$r")" = "$from $on"
  check "found ${want:-nothing}" test "$(jq -r .found "$r")" = "$want"
  if [[ -z "$want" ]]; then
    case "$note" in
      "") check "up to date, no error" test -z "$(jq -r .checkErr "$r")" ;;
      notPublished) check "no release on the channel (ErrNotPublished)" test "$(jq -r .notPublished "$r")" = true ;;
      *) check "the error says: $note" bash -c "jq -r .checkErr '$r' | grep -qF '$note'" ;;
    esac
    check "the bundle is still $from" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$from"
    return
  fi
  local manifest="$WORK/out-$want/darwin-arm64/update-darwin-arm64.json" totals
  local dsize asize
  dsize="$(jq -r --arg v "$from" '.deltas[]? | select(.from == $v) | .size' "$manifest")"
  asize="$(jq -r .size "$manifest")"
  case "$how" in
    delta) totals="[$dsize]" ;;
    fallback) totals="[$dsize,$asize]" ;;
    archive) totals="[$asize]" ;;
  esac
  check "installed without an error" test -z "$(jq -r '.checkErr + .installErr' "$r")"
  check "downloaded $how $totals" test "$(jq -c .totals "$r")" = "$totals"
  check "the notes are $want's, English and Chinese" bash -c "jq -r .notes '$r' | grep -qF 'Test version $want.' && jq -r .notes '$r' | grep -qF '测试版本 ${want}。'"
  check "the bundle is $want's, file for file" diff -r "$app" "$WORK/out-$want/darwin-arm64/VoxtNew.app"
  check "its signature verifies (deep, strict)" codesign --verify --deep --strict "$app"
  check "CFBundleVersion is $want's numbers" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "${want%%-*}"
  check "the old app starts no helper (updated)" test "$(jq -r '"\(.diskVersion) \(.helperState) \(.helperReason) \(.helperPID)"' "$r")" = "$want failed updated 0"
  if [[ "$how" == delta ]]; then
    check "GitHub served the delta, not the archive" bash -c "grep -q '\.delta' <<<\"\$1\" && ! grep -q '\.tar\.gz' <<<\"\$1\"" _ "$served"
  fi
  check "nothing left next to the app" test -z "$(find "$WORK/inst" -maxdepth 1 -name '.VoxtNew.app.*' -print)"
}

step "build $B1, the first beta: nothing published yet"
build "$B1"
check "$B1 has no delta" test -z "$(deltas "$B1")"
publish "$B1"
step "build $B2 (only betas published: its delta from $B1)"
build "$B2"
check "$B2 has a delta from $B1" test "$(deltas "$B2")" = "$B1"
publish "$B2"
check "the build passes release-verify.sh (ad hoc)" scripts/release-verify.sh "$WORK/out-$B2/darwin-arm64" ad-hoc --no-dmg

step "betas only"
expect a "$B1" default "$B2" delta
expect b "$B1" off "" "" notPublished

step "build $R1, the first release (deltas from the betas)"
build "$R1"
check "$R1 has deltas from $B2 and $B1" test "$(deltas "$R1")" = "$B2 $B1"
publish "$R1"
expect c "$B2" default "$R1" delta
expect d "$B2" off "$R1" delta
expect e "$B1" on "$R1" delta
expect n "$B2" on "$R1" fallback

step "build $B3, a beta of the next version (deltas from both channels)"
build "$B3"
check "$B3 has deltas from $R1, $B2 and $B1" test "$(deltas "$B3")" = "$R1 $B2 $B1"
publish "$B3"
expect f "$R1" default ""
expect g "$R1" on "$B3" delta
expect h "$B2" default "$B3" delta
expect i "$B2" off "$R1" delta

step "build $R2, a fix released after $B3"
build "$R2"
check "$R2 has deltas from $R1, $B2 and $B1" test "$(deltas "$R2")" = "$R1 $B2 $B1"
publish "$R2"
expect j "$B3" off ""
expect k "$B3" default ""
expect l "$R1" default "$R2" delta
expect m "$R1" on "$B3" delta

step "the GitHub API refuses (its limit): betas fall back to the latest release"
touch "$GH/rate-limited"
expect o "$R1" on "$R2" delta
expect p "$B3" on "" "" "GitHub takes no more requests"
rm -f "$GH/rate-limited"

step "the fake GitHub"
api="$(grep -c ' api.github.com/' "$WORK/server.log" || true)"
files="$(grep -c ' github.com/' "$WORK/server.log" || true)"
echo "  $api API requests, $files file requests, $RUNS update checks"
check "no other host was asked" test "$(grep -c REFUSED "$WORK/server.log" || true)" = 0
check "no draft was taken" bash -c "! grep -q 'v0.3.0-beta.1/' '$WORK/server.log'"
if pgrep -f "$WORK/inst/VoxtNew.app/Contents/Resources/helper/voxtnew-helper" >/dev/null; then
  echo "  FAIL a helper is running" && FAILS=$((FAILS + 1))
fi
if ((FAILS > 0)); then
  echo "== $FAILS checks failed" >&2
  exit 1
fi
echo "== all checks passed; the test key, the builds and the fake GitHub are removed"
