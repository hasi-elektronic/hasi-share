#!/usr/bin/env python3
"""A/V sync test clip for Settings → Advanced → "Calibrate audio sync" (Build 16).

Design (10 s, loops seamlessly, 640x360 @ 25 fps, H.264 + AAC 48 kHz mono):
  * every full second (frame 0, 25, 50, …) is ONE all-white "flash" frame;
  * at exactly the same presentation time a 1 kHz beep of 40 ms starts (sample-accurate);
  * every other frame is dark with a big timecode "s.ff" (second.frame), the frame number, a row of
    25 cells (the current frame's cell lit) and a marker sweeping left → right once per second – it
    reaches the right edge just before the flash, so the eye knows when to expect it.
In sync, beep and flash are perceived together. Audio heard after the flash = audio late
→ the calibration value goes negative (VLC sign: + = audio later).

Outputs (next to the app's shared resources):
  Shared/Resources/avsync-test.mkv  → VLCKit (the engine being calibrated)
  Shared/Resources/avsync-test.mp4  → AVPlayer ("Reference (Apple)")
Both carry the same encoded streams (stream copy). The AAC encoder delay (priming) is signalled in
both containers (MP4 edit list, Matroska CodecDelay), `--check` measures the beep onset vs. the flash
frame after decoding each file.

Usage: python3 scripts/make-avsync-clip.py [--check]   (needs ffmpeg + Pillow)
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

W, H, FPS, SECONDS = 640, 360, 25, 10
BEEP_HZ, BEEP_MS, RATE = 1000, 40, 48000
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "Shared", "Resources"))


def font(size):
    for path in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Helvetica.ttc",
                 "/Library/Fonts/Arial.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


BIG, SMALL = font(120), font(26)


def frame(n):
    second, sub = divmod(n, FPS)
    if sub == 0:
        img = Image.new("RGB", (W, H), (255, 255, 255))
        d = ImageDraw.Draw(img)
        d.text((W / 2, H / 2), "BEEP", font=BIG, fill=(0, 0, 0), anchor="mm")
        return img
    img = Image.new("RGB", (W, H), (18, 20, 26))
    d = ImageDraw.Draw(img)
    d.text((W / 2, 120), f"{second}.{sub:02d}", font=BIG, fill=(235, 235, 235), anchor="mm")
    d.text((W / 2, 215), f"frame {n:03d}  ·  flash + beep every 1 s", font=SMALL, fill=(150, 160, 175), anchor="mm")
    cell = (W - 40) / FPS
    for i in range(FPS):
        x = 20 + i * cell
        lit = i == sub
        d.rectangle([x + 2, 260, x + cell - 2, 290], fill=(58, 186, 223) if lit else (55, 60, 70))
    x = 20 + (W - 40) * sub / FPS
    d.rectangle([x - 3, 305, x + 3, 345], fill=(255, 107, 0))
    return img


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def build():
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, ".avsync-tmp.mkv")
    beep = f"if(lt(mod(t\\,1)\\,{BEEP_MS / 1000})\\,0.8*sin(2*PI*{BEEP_HZ}*t)\\,0)"
    ff = subprocess.Popen([
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
        "-f", "lavfi", "-i", f"aevalsrc={beep}:s={RATE}:d={SECONDS}:c=mono",
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "slow", "-crf", "32", "-g", str(FPS), "-keyint_min", str(FPS),
        "-pix_fmt", "yuv420p", "-tune", "animation",
        "-c:a", "aac", "-b:a", "48k", "-shortest", tmp,
    ], stdin=subprocess.PIPE)
    for n in range(FPS * SECONDS):
        ff.stdin.write(frame(n).tobytes())
    ff.stdin.close()
    if ff.wait() != 0:
        sys.exit("ffmpeg failed")
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c", "copy", os.path.join(OUT, "avsync-test.mkv")])
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c", "copy", "-movflags", "+faststart",
         os.path.join(OUT, "avsync-test.mp4")])
    os.remove(tmp)
    for name in ("avsync-test.mkv", "avsync-test.mp4"):
        print(name, os.path.getsize(os.path.join(OUT, name)), "bytes")


def check():
    """Beep onset (first sample above 0.1 after second 2) vs. the flash frame time, per container."""
    import array
    for name in ("avsync-test.mkv", "avsync-test.mp4"):
        path = os.path.join(OUT, name)
        pcm = run(["ffmpeg", "-loglevel", "error", "-i", path, "-map", "0:a", "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                  capture_output=True).stdout
        samples = array.array("h", pcm)
        start = 2 * RATE - RATE // 10
        onset = next(i for i in range(start, len(samples)) if abs(samples[i]) > 3000)
        frames = run(["ffprobe", "-loglevel", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                      "-of", "csv=p=0", path], capture_output=True, text=True).stdout.split()
        first_video = float(frames[0].strip(","))
        audio_start = float(run(["ffprobe", "-loglevel", "error", "-select_streams", "a", "-show_entries",
                                 "stream=start_time", "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip() or 0)
        flash = first_video + 2.0
        beep = audio_start + onset / RATE
        print(f"{name}: flash {flash:.3f} s, beep {beep:.3f} s → offset {1000 * (beep - flash):+.1f} ms")


if __name__ == "__main__":
    if "--check" not in sys.argv:
        build()
    check()
