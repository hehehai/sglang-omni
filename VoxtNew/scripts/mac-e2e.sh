#!/usr/bin/env bash
# The headless Mac tests (docs/manual-test.md, "自动真机测试（无界面）"), on
# a Mac that may be busy with other work: no window, no change of the app
# in front, no key posted, no event tap, no clipboard, no microphone (the
# helper records a file). Niced, two jobs, one step at a time; it stops
# when less than AURALINK_MIN_FREE percent of memory (40) is free.
#
#   MAC_DIR=code/Auralink-mt scripts/mac.sh scripts/mac-e2e.sh             # all
#   MAC_DIR=code/Auralink-mt scripts/mac.sh scripts/mac-e2e.sh --offline   # no real services
#
# The real-service tests (one StepFun call, three DeepSeek calls) take
# STEPFUN_API_KEY and DEEPSEEK_API_KEY from the environment or
# ~/.config/auralink-dev/keys.env; without them they skip.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run it on a Mac: MAC_DIR=code/Auralink-mt scripts/mac.sh scripts/mac-e2e.sh" >&2
  exit 1
fi
offline=0
[[ "${1:-}" == "--offline" ]] && offline=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export GOMAXPROCS=2 GOFLAGS=-p=2 SWIFT_BUILD_JOBS=2

step() {
  local free
  free="$(memory_pressure -Q | sed -n 's/.*percentage: \([0-9]*\)%.*/\1/p')"
  echo "== $1 (free memory ${free}%)"
  if (( ${free:-0} < ${AURALINK_MIN_FREE:-40} )); then
    echo "less than ${AURALINK_MIN_FREE:-40}% of memory is free: stopping" >&2
    exit 3
  fi
}

step "the helper (release build)"
nice -n 10 scripts/build-helper.sh --out build/mac-e2e/helper
export AURALINK_HELPER="$ROOT/build/mac-e2e/helper/auralink-helper" AURALINK_MAC_E2E=1

step "swift test"
(cd helper && nice -n 10 swift test -j 2 2>&1 | grep -E "error:|failed|Executed .* tests" | tail -5)

step "the helper, read-only and the file input"
nice -n 10 go test -count=1 -run 'TestMacHelperReadOnly|TestMacHelperIcons|TestMacHelperCaptureFile' -v . | grep -vE '^\s*$'

step "text fit (Core Text)"
AURALINK_TEXTFIT_PROBE=1 AURALINK_TEXTFIT_AUDIT=strict nice -n 10 go test -count=1 -run 'TestTextFitsItsOwnWidth|TestTranslationsFit' -v . |
  grep -E '^(---|ok|FAIL|PASS)|break at'

if (( offline == 0 )); then
  step "real services: StepFun and DeepSeek"
  nice -n 10 go test -count=1 -run 'TestMacE2ESessionReal|TestMacE2EWriteReal' -v . | grep -vE '^\s*$'
fi

if pgrep -f "$AURALINK_HELPER" >/dev/null; then
  echo "a helper is still running: $(pgrep -f "$AURALINK_HELPER" | tr '\n' ' ')" >&2
  exit 1
fi
echo "== done; no helper left running"
