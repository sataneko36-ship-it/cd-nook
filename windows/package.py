"""Make a portable x64 audio-only release from dotnet publish's output.

Run on the Mac host after publishing in the Windows VM. The runtime comes from
VideoLAN.LibVLC.Windows and remains dynamically linked for LGPL compliance.
"""
from pathlib import Path
import shutil
import sys
import zipfile

HERE = Path(__file__).resolve().parent
PROJECT = HERE / "CDGlass.Windows"
PUBLISH = PROJECT / "bin/Release/net10.0-windows/win-x64/publish"
TARGET = HERE / "dist/CD Glass Windows x64"
MAC_LIST = HERE.parent / "vendor/VLC/audio-plugins.txt"

if not (PUBLISH / "CD Glass.exe").exists():
    raise SystemExit("Run dotnet publish -c Release -r win-x64 --self-contained true first")
if TARGET.exists():
    if "--force" in sys.argv:
        shutil.rmtree(TARGET)
    else:
        raise SystemExit(f"Output already exists: {TARGET}; pass --force to replace the generated package")

TARGET.mkdir(parents=True)
for item in PUBLISH.iterdir():
    if item.name == "libvlc" or item.suffix.lower() in {".pdb", ".lib"}:
        continue
    if item.is_file():
        shutil.copy2(item, TARGET / item.name)
    elif item.name == "Demo CD":
        shutil.copytree(item, TARGET / item.name)

VLC = PUBLISH / "libvlc/win-x64"
VLC_OUT = TARGET / "libvlc/win-x64"
VLC_OUT.mkdir(parents=True)
for name in ("libvlc.dll", "libvlccore.dll"):
    shutil.copy2(VLC / name, VLC_OUT / name)

names = {
    line.strip().replace(".dylib", ".dll")
    for line in MAC_LIST.read_text().splitlines()
    if line.startswith("lib")
}
names |= {
    "libdirectsound_plugin.dll", "libwasapi_plugin.dll",
    "libwaveout_plugin.dll", "libmmdevice_plugin.dll",
}
available = {p.name: p for p in (VLC / "plugins").rglob("*.dll")}
selected = {name for name in names & available.keys()
            if not any(part.startswith("video_") or part.startswith("vout")
                       for part in available[name].relative_to(VLC / "plugins").parts[:-1])}
required = {"libfilesystem_plugin.dll", "libcdda_plugin.dll", "libwav_plugin.dll", "libmp4_plugin.dll", "libavcodec_plugin.dll", "libflac_plugin.dll"}
if not required <= selected:
    raise SystemExit(f"Missing audio modules: {required - selected}")
for name in sorted(selected):
    source = available[name]
    dest = VLC_OUT / source.relative_to(VLC)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)

(TARGET / "README.txt").write_text(
    "CD Glass · Windows 11 x64 预览版\n\n"
    "请先完整解压压缩包，再双击 CD Glass.exe。无需另装 VLC 或 .NET。\n"
    "点击「试听示例」可播放随包附带的三首曲目；「打开文件夹」可播放本地 CD 音频文件夹。\n"
    "在专辑墙扫描文件夹、勾选 CD 后，点击「归档到文件夹…」即可自行选择保存位置。\n"
    "LIST / L 显示或隐藏曲目列表；F11 全屏，Esc 退出；空格播放/暂停。\n"
    "左右键切歌，Shift+左右键前后定位 10 秒；Ctrl+B 返回专辑墙。\n"
    "实体音频 CD 需要兼容光驱，目前尚待实盘验证。\n"
    "这是 Windows 预览版；功能差异详见项目的 windows/README.md。\n",
    encoding="utf-8",
)
(TARGET / "THIRD-PARTY-NOTICES.txt").write_text(
    "LibVLCSharp 3.10.1 and VideoLAN LibVLC 3.0.24 are redistributed under LGPL-2.1-or-later.\n"
    "VLC and LibVLCSharp source and licensing information: https://www.videolan.org/legal.html\n"
    "Source downloads: https://www.videolan.org/vlc/download-sources.html\n"
    "CD Glass invokes libVLC with --no-video and bundles only audio-related plugins.\n",
    encoding="utf-8",
)
shutil.copy2(HERE / "LICENSE-LGPL-2.1.txt", TARGET / "LICENSE-LGPL-2.1.txt")

archive = TARGET.parent / "CD-Glass-Windows-x64.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for path in TARGET.rglob("*"):
        if path.is_file():
            z.write(path, Path(TARGET.name) / path.relative_to(TARGET))
print(f"{archive} ({archive.stat().st_size / (1024 * 1024):.1f} MiB; {len(selected)} VLC audio plugins)")
