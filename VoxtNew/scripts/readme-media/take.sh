#!/usr/bin/env bash
# One recorded take of the demo app (demo.sh) at work in TextEdit, over
# the backdrop, captured with alcap: only TextEdit's and the demo's
# windows are in the picture.
#
#   take.sh en|zh transcribe|translate|rewrite <take>   # $RUN/takes/<take>.mov
#   take.sh en|zh hero <take>      # a still, $RUN/takes/<lang>-hero.png: the main
#                                  # window behind TextEdit, the translation card
#
# It waits until the Mac's user has been idle for IDLE seconds (90) and no
# other capture runs, puts TextEdit in front with a document of $RUN/docs,
# and gives the app in front back at the end; the clipboard must come out
# as it went in (Auralink restores it after pasting).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="${RUN:-$HOME/auralink-demo-run}"
A="$ROOT/build/alcap"
D="$ROOT/scripts/readme-media/demo.sh"
lang="$1" kind="$2" take="$3"
out="$RUN/takes/$take.mov"
mkdir -p "$RUN/takes"
pid="$($D pid "$lang")"; [[ -n "$pid" ]] || { echo "the $lang demo is not running" >&2; exit 1; }
ctl() { "$D" ctl "$lang" "$1" >/dev/null; }
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
wait_idle() {
  local need="${IDLE:-90}" waited=0
  while :; do
    if (( $(idle) >= need )) && ! pgrep -qf 'asctl|tools/art|screencapture -v|ffmpeg.*avfoundation'; then return; fi
    (( waited % 60 == 0 )) && echo "waiting: user idle $(idle)s (need ${need}s)"
    sleep 5; waited=$((waited + 5))
    (( waited < ${WAIT_MAX:-3600} )) || { echo "gave up waiting" >&2; exit 3; }
  done
}
# state <regexp> [seconds]: wait until the demo's state line matches.
state() {
  local t=$(( ${2:-40} * 10 ))
  for _ in $(seq "$t"); do "$D" ctl "$lang" state | grep -Eq "$1" && return 0; sleep 0.1; done
  echo "timeout waiting for $1: $("$D" ctl "$lang" state)" >&2; return 1
}
dur() { afinfo "$RUN/speech/$1.wav" | awk '/estimated duration/ {print $3}'; }

case "$lang/$kind" in
  en/transcribe) doc="Design review" sel="-1 0" ;;
  zh/transcribe) doc="设计评审" sel="-1 0" ;;
  en/translate|en/hero) doc="Release plan" sel="14 -1" ;;
  zh/translate|zh/hero) doc="发布计划" sel="6 -1" ;;
  en/rewrite) doc="Reply to Dana" sel="10 -1" ;;
  zh/rewrite) doc="回复王芃" sel="6 -1" ;;
  *) echo "unknown take $lang/$kind" >&2; exit 2 ;;
esac

wait_idle
front="$(lsappinfo info -only bundleid "$(lsappinfo front)" | sed 's/.*="\(.*\)"/\1/')"
clip="$(pbpaste | shasum)"
"$A" backdrop "$RUN/wall.png" >/dev/null & bd=$!
rec=""
cleanup() {
  [[ -n "$rec" ]] && kill -INT "$rec" 2>/dev/null && wait "$rec" 2>/dev/null
  osascript -e "tell application \"TextEdit\" to close (every document whose name starts with \"$doc\") saving no" >/dev/null 2>&1 || true
  "$D" ctl "$lang" close-card >/dev/null 2>&1 || true
  kill "$bd" 2>/dev/null || true
  [[ -n "$front" && "$front" != dev.hehehai.auralink.demo ]] && open -b "$front" 2>/dev/null || true
  [[ "$(pbpaste | shasum)" == "$clip" ]] || echo "WARNING the clipboard changed" >&2
}
trap cleanup EXIT
# TextEdit in the take's language, without its ruler (arguments, not
# its settings): restarted when it runs in the other one, with no
# document open.
if pgrep -qx TextEdit && [[ "$(cat "$RUN/.textedit-lang" 2>/dev/null)" != "$lang" ]]; then
  n="$(osascript -e 'tell application "TextEdit" to count documents')"
  [[ "$n" == 0 ]] || { echo "TextEdit has $n documents open: not restarting it" >&2; exit 5; }
  osascript -e 'quit app "TextEdit"'
  for _ in $(seq 40); do pgrep -qx TextEdit || break; sleep 0.1; done
fi
if pgrep -qx TextEdit; then
  open -a TextEdit "$RUN/docs/$doc.rtf"
else
  langs="(en)"; [[ "$lang" == zh ]] && langs="(zh-Hans)"
  open -a TextEdit "$RUN/docs/$doc.rtf" --args -AppleLanguages "$langs" -ShowRuler NO
  echo "$lang" >"$RUN/.textedit-lang"
fi
sleep 1.5
te="$(pgrep -x TextEdit)"
if [[ "$kind" == hero ]]; then "$A" place "$te" 690 300 760 380; else "$A" place "$te" 475 470 760 380; fi
if [[ "$kind" == hero ]]; then
  ctl "window show"; ctl "nav /home"
  "$A" place "$pid" 150 170 800 520
else
  ctl "window hide"
fi
ctl "close-card"
osascript -e 'tell application "TextEdit" to activate'
sleep 0.8
"$A" select "$te" $sel
frontnow() { lsappinfo info -only bundleid "$(lsappinfo front)" | sed 's/.*="\(.*\)"/\1/'; }
[[ "$(frontnow)" == com.apple.TextEdit ]] || { echo "TextEdit is not in front: $(frontnow)" >&2; exit 4; }
"$D" ctl "$lang" state | grep -q 'front=com.apple.TextEdit' || { echo "the demo does not see TextEdit in front" >&2; exit 4; }
if [[ "$kind" == hero ]]; then
  ctl "take $take"
  ctl "fire translate"
  state 'state=(done|failed).*card=true'
  sleep 1.5
  "$A" shot --rect 110 130 1420 920 --include "com.apple.TextEdit,dev.hehehai.auralink.demo,$pid" --out "$RUN/takes/$lang-hero.png"
  ctl "window hide"
  exit 0
fi
"$A" record --rect 435 440 840 600 --include "com.apple.TextEdit,dev.hehehai.auralink.demo,$pid" --out "$out" & rec=$!
sleep 1.5
ctl "take $take"
case "$kind" in
transcribe)
  "$D" speech "$lang-transcribe"
  ctl "fire transcribe"
  sleep "$(echo "$(dur "$lang-transcribe") + 0.5" | bc)"
  ctl "fire transcribe"
  state 'state=(done|failed|cancelled)'
  sleep 2 ;;
translate)
  ctl "fire translate"
  state 'state=(done|failed).*card=true'
  sleep 2.2
  ctl "lang-menu"; sleep 1.6
  ctl "lang ja"
  state 'state=(reading|composing)' 5 || true
  state 'state=(done|failed)'
  sleep 3 ;;
rewrite)
  "$D" speech "$lang-rewrite-1"
  ctl "fire rewrite"; sleep "$(echo "$(dur "$lang-rewrite-1") + 0.6" | bc)"; ctl "fire rewrite"
  state 'state=(done|failed).*open=true'
  sleep 3
  "$D" speech "$lang-rewrite-2"
  ctl "fire rewrite"; sleep "$(echo "$(dur "$lang-rewrite-2") + 0.6" | bc)"; ctl "fire rewrite"
  sleep 0.5
  state 'state=(done|failed).*open=true'
  sleep 3
  ctl "insert"
  sleep 2.5 ;;
esac
"$D" ctl "$lang" state
