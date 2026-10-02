#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
app="${root:h:h}/outputs/CD Nook.app"
sample="${1:-${root:h}/audio-only-test/01 - Daylight.wav}"
probe="$(mktemp -d /private/tmp/cdglass-vlc-probe.XXXXXX)"
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/Contents/MacOS"
ln -s "$app/Contents/Frameworks" "$probe/Contents/Frameworks"
clang -I "$root/vendor/VLC/include" "$root/tests/vlc_bundle_test.c" \
  -L "$root/vendor/VLC/lib" -lvlc -Wl,-rpath,@executable_path/../Frameworks/VLC/lib \
  -o "$probe/Contents/MacOS/vlc_bundle_test"
"$probe/Contents/MacOS/vlc_bundle_test" "$probe/Contents/Frameworks/VLC/plugins" "$sample"
