#!/bin/zsh
# Builds AppIcon.icns (16–1024 px, 1x and 2x) from the 1024 px master AppIcon-1024.png.
# The master is drawn by src/icons.m: the pixel-screen housing, a sage dot-matrix window, and a clear jewel case
# whose cover shows the app's own cassette (rendered by src/cassette_snap.m with 磁带标签-像素屏.png as its label).
# To redraw it:  clang -fobjc-arc -O2 src/icons.m -o /tmp/icons -framework AppKit -framework CoreImage
#                /tmp/icons src tones   (writes T-细边框.png — copy it over AppIcon-1024.png)
#                /tmp/icons src big     (writes T-细边框@2x.png — AppIcon-2048.png, the icon at 2048 px)
set -euo pipefail
here="${0:A:h}"
work="$(mktemp -d)"
set="$work/AppIcon.iconset"
mkdir -p "$set"
for s in 16 32 128 256 512; do
  sips -z $s $s "$here/AppIcon-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$here/AppIcon-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$here/AppIcon.icns"
rm -rf "$work"
echo "$here/AppIcon.icns"
