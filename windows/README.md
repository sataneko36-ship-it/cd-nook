# CD Glass for Windows

Windows 11 x64 preview. This is a separate WPF/.NET implementation alongside the existing macOS app. It targets x64 PCs and can also run under Windows 11 ARM64 x64 emulation.

## Available now

- Four animated player faces: floating square cover, transparent CD jewel case, cassette and pixel screen; eight matching palettes, floating particles, and selectable solid, blurred-cover or cover-tinted backgrounds.
- Smooth CD rotation and cassette reel movement, player entrance transitions and artwork flights between the wall and player.
- LIST toggles the small corner track list and recomputes the native stage layout; borderless fullscreen fades controls after 3.5 seconds of playback inactivity and restores them on input.
- Cached blurred-cover backgrounds avoid recomputing a live blur on every frame.
- Local WAV, AIFF, MP3, M4A, FLAC, OGG and Opus playback with bundled audio-only libVLC; pause, track selection, seek and volume. The built-in three-track demo CD works without a disc drive.
- CUE album/track metadata and INDEX 01 boundaries, including Shift-JIS cue sheets and multiple tracks sharing one audio file.
- Folder drag and drop, album.json title/artist, local and FLAC-embedded artwork, manual artwork replacement/reset and optional MusicBrainz/Cover Art Archive search. A physical CD can also use a saved manual cover.
- Local CD library scanning, anime-title grouping, layered wall stack expansion, playback from a stack and return to that stack on the first wall-button click.
- Copy selected albums into a folder chosen at archive time. In an expanded stack, right-click a sleeve to select it for archiving, then return to the wall and use the archive action. Library and preferences live under `%LOCALAPPDATA%\CD Glass`.
- Physical CD insertion/removal detection through Windows TOC, cdda playback path, MusicBrainz disc ID and automatic disc metadata/artwork lookup with a local cache. The optical-drive path still awaits a real audio CD test.

## Remaining parity work

The four player subjects now use material layers exported from the native Mac renderer, with dynamic Windows artwork and playback state. Their geometry, stage layout, corner list, control layout, square wall sleeves and seeded ring layout follow the Mac source. See `visual-parity/index.html` for six actual screenshot pairs.

This is not complete visual parity. Windows system fonts, text rasterization, shadows, cover focus and background details still differ. The wall burst currently uses WPF transforms; the native blur wave, 3D perspective and spring curves are not fully reproduced. Pixel artwork ports the Mac whole-cover processing path; Vision subject segmentation and artwork enhancement remain unavailable. Its playing spectrum is decorative rather than measured from the audio. The disc TOC reader, cdda playback and live metadata lookup still require a real audio CD test.

## Keyboard controls

- `Space`: play/pause; `←` / `→`: previous/next; `Shift+←` / `Shift+→`: seek 10 seconds.
- `↑` / `↓`: volume; `L`: track list; `F` / `F11`: fullscreen; `Esc`: leave fullscreen or return within the wall.
- `Ctrl+B`: album wall; `Ctrl+O`: open folder; `Ctrl+W`: end the current CD session.

## Visual rebuild verification (2026-09-30)

The new build published successfully without compiler warnings in the Windows VM. Rendered all four real WPF faces and both library pages at 1500 × 1000; compared them with isolated Mac snapshots of the same demo CD. The live navigation check also played a CD from a burst and confirmed the first wall-button return restored the same stack and selected CD. Packaged the self-contained build with 60 audio plugins and no plugins in video categories.

The new mouse seek handler needs a hardware-input check: synthetic mouse clicks in the VM did not reliably activate the visible controls. The pause and next buttons responded through their automation invoke path. Do not treat the new slider's mouse handling as verified from these runs.

## Earlier functional verification (2026-09-30)

Built and run in the local Windows 11 ARM VM using x64 emulation. Verified folder playback, LIST layout changes, fullscreen control fade and exit with playback continuing, wall stack expansion, first return to the same stack with the selected CD highlighted, rapid CUE next/previous without a stale delayed seek, pause retaining the disc angle, and final-package demo playback with both pixel LIST layouts. Real audio CD playback remains unverified.

## Build

On Windows 11 x64 with .NET 10 SDK:

```powershell
dotnet publish .\CDGlass.Windows\CDGlass.Windows.csproj -c Release -r win-x64 --self-contained true
```

The solution references the official `LibVLCSharp` and `VideoLAN.LibVLC.Windows` NuGet packages. `package.py` runs on the Mac host after publication and produces a portable zip with only x64 VLC audio plugins. Pass `--force` when replacing a previously generated package. Unzip the complete archive and run `CD Glass.exe`; neither VLC nor .NET needs a separate installation.

For quick checks, `CD Glass.exe <folder>` opens an audio folder and `CD Glass.exe --scan <folder>` scans it into the wall. The app also provides folder pickers and drag and drop.
