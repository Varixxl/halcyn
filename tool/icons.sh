#!/usr/bin/env bash
# Renders every platform's icon from assets/icon/*.svg. Needs rsvg-convert and ImageMagick.
set -euo pipefail
cd "$(dirname "$0")/.."
icon=assets/icon
res=android/app/src/main/res
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# The notification icon: the white mark filling most of its square.
rsvg-convert -w 1024 "$icon/mono.svg" -o "$tmp/mono.png"
magick "$tmp/mono.png" -trim +repage "$tmp/mono-trim.png"
stat_icon() {
  local inner=$(( $1 * 20 / 24 ))
  magick "$tmp/mono-trim.png" -resize "${inner}x${inner}" -background none \
    -gravity center -extent "$1x$1" "$2"
}

for pair in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  density=${pair%:*} scale=${pair#*:}
  px() { awk "BEGIN { print int($1 * $scale + 0.5) }"; }
  mkdir -p "$res/mipmap-$density" "$res/drawable-$density"
  png "$icon/halcyn.svg" "$(px 48)" "$res/mipmap-$density/ic_launcher.png"
  # Adaptive icons (Android 8+) are 108dp, of which the middle 66dp always shows.
  png "$icon/mark.svg" "$(px 108)" "$res/mipmap-$density/ic_launcher_foreground.png"
  png "$icon/mono.svg" "$(px 108)" "$res/mipmap-$density/ic_launcher_monochrome.png"
  stat_icon "$(px 24)" "$res/drawable-$density/ic_stat_halcyn.png"
done

for size in 16 24 32 48 64 128 256; do png "$icon/halcyn.svg" $size "$tmp/$size.png"; done
magick "$tmp"/{16,24,32,48,64,128,256}.png windows/runner/resources/app_icon.ico

png "$icon/halcyn.svg" 256 linux/halcyn.png
echo "icons written"
