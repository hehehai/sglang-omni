#!/usr/bin/env bash
# The backdrop of the README's captures: a soft blue-violet-orange gradient
# at the Mac's screen size (3420×2214 pixels, 1710×1107 points).
#
#   scripts/readme-media/wallpaper.sh wall.png && scp wall.png mac-air:auralink-demo-run/
set -euo pipefail
convert -size 342x221 xc: -sparse-color Shepards \
  '0,0 #1b2a6b  342,0 #3a62d9  0,221 #2a1f5c  342,221 #f08a4b  170,40 #4f7cf0  260,120 #c86fd0  80,160 #6a5bd8  300,200 #ffb36b  150,210 #8d4fc4' \
  -blur 0x18 -resize 3420x2214! "${1:-wall.png}"
