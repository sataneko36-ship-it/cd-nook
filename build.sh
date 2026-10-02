#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
out="${root:h:h}/outputs/CD Nook.app"
vlc="$root/vendor/VLC"
[[ -f "$vlc/lib/libvlc.dylib" && -d "$vlc/plugins" && -d "$vlc/include/vlc" ]] || { echo "Missing bundled VLC runtime in $vlc" >&2; exit 1; }
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$root/Info.plist" "$out/Contents/Info.plist"
cp "$root/data/AnimeTitles.json" "$out/Contents/Resources/AnimeTitles.json"
cp "$root/icon/AppIcon.icns" "$out/Contents/Resources/AppIcon.icns"
cp "$root/icon/IdleCover.jpg" "$out/Contents/Resources/IdleCover.jpg"
mkdir -p "$out/Contents/Resources/RealESRGAN/models"
cp "$root/vendor/RealESRGAN/realesrgan-ncnn-vulkan" "$out/Contents/Resources/RealESRGAN/"
cp "$root/vendor/RealESRGAN/models/"*.bin "$root/vendor/RealESRGAN/models/"*.param "$out/Contents/Resources/RealESRGAN/models/"
cp "$root/vendor/RealESRGAN/README_macos.md" "$out/Contents/Resources/RealESRGAN/"
if [[ -f "$root/vendor/RealESRGAN/LICENSE" ]]; then cp "$root/vendor/RealESRGAN/LICENSE" "$out/Contents/Resources/RealESRGAN/"; fi
rm -rf "$out/Contents/Frameworks/VLC"
mkdir -p "$out/Contents/Frameworks/VLC"
ditto "$vlc/lib" "$out/Contents/Frameworks/VLC/lib"
mkdir -p "$out/Contents/Frameworks/VLC/plugins"
while IFS= read -r plugin; do
  [[ -z "$plugin" || "$plugin" == \#* ]] && continue
  [[ "$plugin" == lib*_plugin.dylib && -f "$vlc/plugins/$plugin" ]] || { echo "Missing VLC audio plugin: $plugin" >&2; exit 1; }
  cp "$vlc/plugins/$plugin" "$out/Contents/Frameworks/VLC/plugins/"
done < "$vlc/audio-plugins.txt"
if [[ -d "$vlc/share" ]]; then ditto "$vlc/share" "$out/Contents/Frameworks/VLC/share"; fi
sources=("$root/CDGlass.m" "$root/CDVolumes.m" "$root/CDCoverSearch.m" "$root/CDTheme.m" "$root/CDViews.m" "$root/CDHeroes.m" "$root/CDRetroPlayer.m" "$root/CDPixelArt.m" "$root/CDLibrary.m" "$root/CDAlbumWall.m")
CLANG_MODULE_CACHE_PATH="${root:h}/clang-cache" clang -fobjc-arc -fmodules -mmacosx-version-min=26.0 -O2 \
  -I "$vlc/include" "${sources[@]}" \
  -o "$out/Contents/MacOS/CDGlass" \
  -framework AppKit -framework DiscRecording -framework QuartzCore -framework CoreImage -framework Vision \
  -L "$vlc/lib" -lvlc \
  -Wl,-rpath,@executable_path/../Frameworks/VLC/lib
python3 "$root/make_demo.py"
codesign --force --deep --sign - "$out" >/dev/null
echo "$out"
