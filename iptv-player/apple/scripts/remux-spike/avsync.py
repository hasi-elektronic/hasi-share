#!/usr/bin/env python3
"""Measures A/V offset of the flash+beep clip: beep onset (silencedetect) − flash frame (YAVG).
Usage: avsync.py <file or dump dir>  (dir → init+segments concatenated)."""
import os, re, subprocess, sys, statistics

src = sys.argv[1]
if os.path.isdir(src):
    media = open(os.path.join(src, "media.m3u8")).read()
    segs = [l for l in media.splitlines() if l.endswith(".m4s")]
    path = os.path.join(src, "_sync.mp4")
    with open(path, "wb") as f:
        f.write(open(os.path.join(src, "init.mp4"), "rb").read())
        for s in segs:
            f.write(open(os.path.join(src, s), "rb").read())
else:
    path = src

def esc(p):
    return p.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")

v = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", f"movie='{esc(path)}',signalstats",
                    "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0"],
                   capture_output=True, text=True).stdout
flashes = []
prev = 0
for line in v.splitlines():
    parts = line.split(",")
    if len(parts) < 2: continue
    t, y = float(parts[0]), float(parts[1])
    if y > 128 and prev <= 128: flashes.append(t)
    prev = y
a = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", f"amovie='{esc(path)}',asetnsamples=n=120,astats=metadata=1:reset=1",
                    "-show_entries", "frame=pts_time:frame_tags=lavfi.astats.Overall.RMS_level", "-of", "csv=p=0"],
                   capture_output=True, text=True).stdout
beeps = []
loud = False
for line in a.splitlines():
    parts = line.split(",")
    if len(parts) < 2: continue
    try:
        t, rms = float(parts[0]), float(parts[1])
    except ValueError:
        rms = -200.0
    if rms > -30 and not loud and (not beeps or t - beeps[-1] > 0.5): beeps.append(t)
    loud = rms > -30
offsets = []
for b in beeps:
    near = min(flashes, key=lambda f: abs(f - b)) if flashes else None
    if near is not None and abs(near - b) < 0.5: offsets.append((b - near) * 1000)
if os.path.isdir(src): os.remove(path)
if offsets:
    print(f"flashes={len(flashes)} beeps={len(beeps)} pairs={len(offsets)} offset(audio-video) ms: "
          f"mean {statistics.mean(offsets):.1f} min {min(offsets):.1f} max {max(offsets):.1f} stdev {statistics.pstdev(offsets):.1f}")
else:
    print(f"no pairs (flashes={len(flashes)} beeps={len(beeps)})")
