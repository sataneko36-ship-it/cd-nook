#!/bin/zsh
# Builds an isolated, silent copy of the app that renders its own window to PNGs.
# Usage: tests/snapshot.sh <output-dir> <album-folder> [extra env assignments…]
set -euo pipefail
root="${0:A:h:h}"
vlc="$root/vendor/VLC"
out="${1:?output dir}"; album="${2:?album folder}"; shift 2
app="${TMPDIR:-/tmp}/CDGlassSnapshot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out" "$out/store"
sed 's/local.cdglass.player/local.cdglass.snapshot/' "$root/Info.plist" > "$app/Contents/Info.plist"
rsync -a "${root:h:h}/outputs/CD Nook.app/Contents/Resources/Demo CD" "$app/Contents/Resources/" 2>/dev/null || true
cp "$root/data/AnimeTitles.json" "$app/Contents/Resources/"
cp "$root/icon/AppIcon.icns" "$root/icon/IdleCover.jpg" "$app/Contents/Resources/"
rm -rf "$app/Contents/Frameworks/VLC"
mkdir -p "$app/Contents/Frameworks/VLC"
ditto "$vlc/lib" "$app/Contents/Frameworks/VLC/lib"
mkdir -p "$app/Contents/Frameworks/VLC/plugins"
while IFS= read -r plugin; do
  [[ -z "$plugin" || "$plugin" == \#* ]] && continue
  [[ "$plugin" == lib*_plugin.dylib && -f "$vlc/plugins/$plugin" ]] || { echo "Missing VLC audio plugin: $plugin" >&2; exit 1; }
  cp "$vlc/plugins/$plugin" "$app/Contents/Frameworks/VLC/plugins/"
done < "$vlc/audio-plugins.txt"
if [[ -d "$vlc/share" ]]; then ditto "$vlc/share" "$app/Contents/Frameworks/VLC/share"; fi
CLANG_MODULE_CACHE_PATH="${root:h}/clang-cache" clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 -DCDGLASS_SNAPSHOT ${=CDGLASS_CFLAGS:-} -w \
  -I "$vlc/include" "$root"/CDGlass.m "$root"/CDCoverSearch.m "$root"/CDTheme.m "$root"/CDViews.m "$root"/CDHeroes.m "$root"/CDRetroPlayer.m "$root"/CDPixelArt.m "$root"/CDLibrary.m "$root"/CDAlbumWall.m "$root"/CDVolumes.m "$root"/tests/snapshot.m \
  -o "$app/Contents/MacOS/CDGlass" -framework AppKit -framework DiscRecording -framework QuartzCore -framework CoreImage -framework Vision \
  -L "$vlc/lib" -lvlc -Wl,-rpath,@executable_path/../Frameworks/VLC/lib
env CDGLASS_SNAP="$out" CDGLASS_STORE="$out/store" FOLDER="$album" "$@" "$app/Contents/MacOS/CDGlass" -CDGlassEnhancementMode 0 -CDGlassVolume 70 &
pid=$!
for i in {1..120}; do sleep 1; kill -0 $pid 2>/dev/null || break; done
kill $pid 2>/dev/null || true
# KEEP_DEFAULTS=1 keeps the test copy's preferences, to check what a second launch remembers.
[[ -n "${KEEP_DEFAULTS:-}" ]] || defaults delete local.cdglass.snapshot >/dev/null 2>&1 || true
rm -rf ~/Library/Saved\ Application\ State/local.cdglass.snapshot.savedState
