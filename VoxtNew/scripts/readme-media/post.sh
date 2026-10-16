#!/usr/bin/env bash
# Turns the Mac's captures (shots.sh, take.sh, pulled into SRC) into the
# README's media: window shots, the hero, the menu bar menu and overlay
# stills in docs/images (English) and docs/images/zh, animated WebP in
# docs/media and docs/media/zh with the full-size MP4s beside them. Needs
# ImageMagick, pngquant and ffmpeg with libwebp and libx264.
#
#   rsync -a mac-air:auralink-demo-run/{shots,takes} "$SRC"/
#   SRC=/tmp/almedia scripts/readme-media/post.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${SRC:?SRC: the folder with shots/ and takes/}"

for lang in en zh; do
  img="$ROOT/docs/images"; media="$ROOT/docs/media"
  [[ $lang == zh ]] && img="$img/zh" && media="$media/zh"
  mkdir -p "$img" "$media"
  s="$SRC/shots/$lang" t="$SRC/takes"

  # The main window's pages: the window and its shadow, as captured (2x).
  for p in home history app-enhancement dictionary model-services settings-audio settings-about; do
    cp "$s/$p.png" "$img/$p.png"
  done

  # The hero: the main window behind TextEdit and the translation card.
  convert "$t/$lang-hero.png" -resize 1800x "$img/hero.png"

  # The menu bar menu. The item is drawn by the system, not captured: the
  # app's own icon (internal/trayicon), on the highlight of an open item.
  convert "$s/menu.png" \
    -fill 'rgba(255,255,255,0.35)' -draw 'roundrectangle 86,10 158,58 12,12' \
    \( "$ROOT/internal/trayicon/menubar.png" -fill 'rgba(20,20,30,0.9)' -colorize 100 \) -geometry +104+16 -composite \
    -crop 500x650+30+0 +repage "$img/menu.png"

  # Overlay stills from the takes (2x frames of the 840×600 pt region).
  still() { ffmpeg -v error -y -ss "$2" -i "$t/$lang-$1.mov" -frames:v 1 -vf "crop=$3" "$img/$4.png"; }
  still transcribe 9.0 800:260:440:900 overlay-recording
  still transcribe 11.5 800:260:440:900 overlay-live
  # The cards in their setting: TextEdit, the card and our language menu.
  still translate 2.5 1680:1200:0:0,scale=1200:-1:flags=lanczos overlay-card
  case $lang in en) rw=13.5 ;; zh) rw=15.5 ;; esac
  still rewrite $rw 1680:1200:0:0,scale=1200:-1:flags=lanczos overlay-rewrite

  # Animations: from just before the shortcut, the end held for 2 s;
  # Rewrite (two turns) a little faster.
  for k in transcribe translate rewrite; do
    speed=1; [[ $k == rewrite ]] && speed=1.25
    vf="setpts=PTS/$speed,tpad=stop_mode=clone:stop_duration=2"
    ffmpeg -v error -y -ss 1.2 -i "$t/$lang-$k.mov" -vf "$vf,fps=15,scale=1200:-1:flags=lanczos" \
      -c:v libwebp_anim -lossless 0 -q:v 82 -compression_level 6 -loop 0 "$media/$k.webp"
    ffmpeg -v error -y -ss 1.2 -i "$t/$lang-$k.mov" -vf "$vf,fps=30,format=yuv420p" \
      -c:v libx264 -preset slow -crf 20 -movflags +faststart -an "$media/$k.mp4"
  done
done

pngquant --force --skip-if-larger --ext .png --quality 75-95 "$ROOT"/docs/images/*.png "$ROOT"/docs/images/zh/*.png || true
du -sh "$ROOT/docs/images" "$ROOT/docs/media"
