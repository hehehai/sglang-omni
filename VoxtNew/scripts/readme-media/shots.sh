#!/usr/bin/env bash
# The main window's pages, captured by window (screencapture -l: the window
# with its shadow, nothing else), from the running demo app (demo.sh).
#
#   shots.sh en|zh [name:/path …]      # into $RUN/shots/<lang>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="${RUN:-$HOME/voxtnew-demo-run}"
lang="$1"; shift
demo() { "$ROOT/scripts/readme-media/demo.sh" "$@"; }
pid="$(demo pid "$lang")"
[[ -n "$pid" ]] || { echo "the $lang demo is not running" >&2; exit 1; }
out="$RUN/shots/$lang"; mkdir -p "$out"
pages=("$@")
((${#pages[@]})) || pages=(home:/home history:/history0 app-enhancement:/app-enhancement model-services:/providers
  dictionary:/dictionary transcribe:/transcribe settings-general:/settings/general settings-audio:/settings/audio
  settings-overlay:/settings/overlay settings-shortcuts:/settings/shortcuts settings-about:/settings/about)
demo ctl "$lang" "window show" >/dev/null
"$ROOT/build/alcap" activate "$pid"
sleep 0.6
wid() { "$ROOT/build/alcap" windows | awk -v p="pid=$pid" '$2 == p && $4 == "owner=VoxtNew" && $5 == "name=VoxtNew" { sub("id=", "", $1); print $1; exit }'; }
for p in "${pages[@]}"; do
  name="${p%%:*}"; path="${p#*:}"
  case "$path" in
    /history*) demo ctl "$lang" "nav /history" >/dev/null; demo ctl "$lang" "hist 0 ${path#/history}" >/dev/null ;;
    *) demo ctl "$lang" "nav $path" >/dev/null ;;
  esac
  # About: a taller window, for the update switches under the version.
  [[ "$name" == settings-about ]] && "$ROOT/build/alcap" place "$pid" 455 100 800 760
  sleep 1.2
  screencapture -x -l"$(wid)" "$out/$name.png"
  [[ "$name" == settings-about ]] && "$ROOT/build/alcap" place "$pid" 455 173 800 520
  echo "$name $(sips -g pixelWidth -g pixelHeight "$out/$name.png" | awk '/pixel/ {printf "%s ", $2}')"
done
demo ctl "$lang" "nav /home" >/dev/null
