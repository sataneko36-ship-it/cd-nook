from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json
import math
import struct
import wave

root = Path(__file__).resolve().parents[2] / "outputs" / "CD Nook.app" / "Contents" / "Resources" / "Demo CD"
root.mkdir(parents=True, exist_ok=True)

size = 1000
img = Image.new("RGB", (size, size), (24, 25, 28))
draw = ImageDraw.Draw(img)
draw.rectangle((38, 38, 962, 962), outline=(74, 76, 82), width=2)
draw.line((96, 196, 904, 196), fill=(95, 97, 101), width=2)
draw.line((96, 806, 904, 806), fill=(95, 97, 101), width=2)
font_path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
font = ImageFont.truetype(font_path, 94)
small = ImageFont.truetype(font_path, 24)
draw.text((96, 136), "CD NOOK  /  DEMO", font=small, fill=(180, 183, 186))
draw.text((96, 390), "NOOK", font=font, fill=(242, 242, 239))
draw.text((96, 510), "SESSIONS", font=font, fill=(242, 242, 239))
draw.text((96, 840), "VIRTUAL COMPACT DISC     001", font=small, fill=(180, 183, 186))
img.save(root / "cover.jpg", quality=91)

sample_rate = 44100
titles = ["01 - Daylight.wav", "02 - Reflection.wav", "03 - Nightfall.wav"]
chords = [(220, 261.63, 329.63), (174.61, 220, 293.66), (164.81, 207.65, 246.94)]
for title, notes in zip(titles, chords):
    with wave.open(str(root / title), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        samples = bytearray()
        for i in range(sample_rate * 6):
            t = i / sample_rate
            envelope = min(1, t / .12) * min(1, (6 - t) / .5)
            tone = sum(math.sin(2 * math.pi * f * t) for f in notes) / len(notes)
            tone += .08 * math.sin(2 * math.pi * 2 * notes[0] * t)
            amp = int(10000 * envelope * tone)
            samples.extend(struct.pack("<hh", amp, amp))
        wav.writeframes(samples)

(root / "album.json").write_text(json.dumps({"title": "Nook Sessions", "artist": "CD Nook Demo", "tracks": ["Daylight", "Reflection", "Nightfall"]}, ensure_ascii=False, indent=2))
