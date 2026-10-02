# Bundled VLC runtime

This directory contains the VLC 3.0.21 arm64 headers, libraries, and an audio-only selection of plugins copied from the locally installed macOS VLC app. CD Glass builds and runs against this copy; an installation in `/Applications` is not required.

`audio-plugins.txt` lists the 66 retained plugins and the build script copies only these. Video output, video filters, subtitle modules, streaming output, VLC's own interface, Lua scripts, and translations are omitted. Shared libraries such as `libvlc` and `libavcodec_plugin.dylib` still contain code for both audio and video; CD Glass starts libVLC with `--no-video`.

To update VLC, replace the contents from a matching arm64 macOS VLC distribution, apply the selection in `audio-plugins.txt`, and rerun `build.sh`. Keep the headers, libraries, and plugins from the same VLC release.

For redistribution terms and corresponding source requirements, see [VideoLAN's legal information](https://www.videolan.org/legal.html) and [VLC source downloads](https://www.videolan.org/vlc/download-sources.html).
