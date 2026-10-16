#!/usr/bin/env bash
# Runs the demo app (build.sh) for the README's media, on the Mac, and
# sends it commands (demo.go, demoCommand).
#
#   demo.sh start en|zh      # data in $RUN/<lang>, sample data on its first start
#   demo.sh ctl en 'fire transcribe'
#   demo.sh speech en-transcribe    # what the helper "hears" next
#   demo.sh stop en
#
# RUN (default ~/voxtnew-demo-run) holds keys.env (STEPFUN_API_KEY and
# DEEPSEEK_API_KEY, mode 600), speech/*.wav and a folder for each
# language. The app runs from this shell, not through Launch Services, so
# it shares this shell's Accessibility grant; its helper records
# $RUN/speech/current.wav (VOXTNEW_HELPER_CAPTURE_FILE) instead of the
# microphone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="${RUN:-$HOME/voxtnew-demo-run}"
APP="$ROOT/build/darwin-arm64/VoxtNew.app"
BIN="$APP/Contents/MacOS/VoxtNew"

pid_of() { pgrep -f "$BIN" | while read -r p; do
  ps eww -o command= -p "$p" | grep -q "VOXTNEW_DEMO_LANG=$1 " && echo "$p"; done || true; }

case "${1:-}" in
start)
  lang="$2"; dir="$RUN/$lang"
  [[ -z "$(pid_of "$lang")" ]] || { echo "running: $(pid_of "$lang")"; exit 0; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" == dev.hehehai.voxtnew.demo ]] || { echo "not a demo build" >&2; exit 1; }
  mkdir -p "$dir/home" "$dir/ctl"
  [[ -f "$RUN/speech/current.wav" ]] || cp "$RUN/speech/$lang-transcribe.wav" "$RUN/speech/current.wav"
  (cd "$dir" && env HOME="$dir/home" VOXTNEW_DEMO_DIR="$dir" VOXTNEW_DEMO_LANG="$lang" VOXTNEW_DEMO_KEYS="$RUN/keys.env" \
    VOXTNEW_DEMO_TARGETS=com.apple.TextEdit \
    VOXTNEW_HELPER_CAPTURE_FILE="$RUN/speech/current.wav" \
    nohup nice -n 5 "$BIN" >"$dir/run.log" 2>&1 </dev/null &)
  for _ in $(seq 40); do p="$(pid_of "$lang")"; [[ -n "$p" ]] && { echo "started $p"; exit 0; }; sleep 0.25; done
  echo "did not start" >&2; tail "$dir/run.log" >&2; exit 1 ;;
stop)
  p="$(pid_of "$2")"; [[ -n "$p" ]] || { echo "not running"; exit 0; }
  kill -TERM $p
  for _ in $(seq 80); do kill -0 $p 2>/dev/null || { echo stopped; exit 0; }; sleep 0.25; done
  kill -KILL $p 2>/dev/null; sleep 1
  pgrep -qf "$BIN" && pgrep -f "$APP/Contents/Resources/helper" >/dev/null && echo "a helper may be left" >&2
  echo "killed" ;;
pid) pid_of "$2" ;;
speech) cp "$RUN/speech/$2.wav" "$RUN/speech/current.wav" ;;
ctl)
  dir="$RUN/$2/ctl"; n="$(date +%s%N)"
  printf '%s\n' "$3" >"$dir/$n.cmd.tmp" && mv "$dir/$n.cmd.tmp" "$dir/$n.cmd"
  for _ in $(seq 100); do
    for ext in ok err; do [[ -f "$dir/$n.$ext" ]] && { cat "$dir/$n.$ext"; rm -f "$dir/$n.$ext"; [[ $ext == ok ]]; exit; }; done
    sleep 0.05
  done
  echo "no answer" >&2; exit 1 ;;
*) echo "usage: demo.sh start|stop|pid|speech|ctl …" >&2; exit 2 ;;
esac
