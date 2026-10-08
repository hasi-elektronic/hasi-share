#!/usr/bin/env python3
"""Validates a dumped remux HLS (init.mp4 + segN.m4s): per-segment timestamps via ffprobe,
continuity across segments (no gaps/overlaps), A/V start alignment, full decode check."""
import json, os, subprocess, sys, re

d = sys.argv[1]
media = open(os.path.join(d, "media.m3u8")).read()
extinf = [float(x) for x in re.findall(r"#EXTINF:([0-9.]+),", media)]
segs = [l for l in media.splitlines() if l.endswith(".m4s")]
init = open(os.path.join(d, "init.mp4"), "rb").read()

def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "packet=stream_index,pts,dts,duration,flags:stream=index,codec_type,time_base",
                          "-of", "json", path], capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    tb = {}
    kind = {}
    for s in j["streams"]:
        n, dd = s["time_base"].split("/")
        tb[s["index"]] = int(n) / int(dd)
        kind[s["index"]] = s["codec_type"]
    res = {}
    for p in j["packets"]:
        i = p["stream_index"]
        k = kind[i]
        r = res.setdefault(k, {"pts": [], "dts": [], "dur": [], "key": []})
        r["pts"].append(int(p["pts"]) * tb[i])
        r["dts"].append(int(p["dts"]) * tb[i])
        r["dur"].append(int(p.get("duration", 0)) * tb[i])
        r["key"].append("K" in p.get("flags", ""))
    return res

rows = []
tmp = os.path.join(d, "_one.mp4")
for idx, name in enumerate(segs):
    with open(tmp, "wb") as f:
        f.write(init)
        f.write(open(os.path.join(d, name), "rb").read())
    r = probe(tmp)
    v, a = r.get("video"), r.get("audio")
    row = {"i": idx, "extinf": extinf[idx]}
    row["v_first"] = min(v["pts"])
    row["v_end"] = max(p + du for p, du in zip(v["pts"], v["dur"]))
    row["v_dts0"] = v["dts"][0]
    row["v_dts_end"] = v["dts"][-1] + v["dur"][-1]
    row["v_key0"] = v["key"][0]
    row["v_bad_dts"] = sum(1 for i in range(1, len(v["dts"])) if v["dts"][i] <= v["dts"][i - 1])
    row["v_pts_lt_dts"] = sum(1 for p, q in zip(v["pts"], v["dts"]) if p < q - 1e-9)
    if a:
        row["a_first"] = a["pts"][0]
        row["a_end"] = a["pts"][-1] + a["dur"][-1]
        gaps = [a["pts"][i] - (a["pts"][i - 1] + a["dur"][i - 1]) for i in range(1, len(a["pts"]))]
        row["a_maxgap"] = max([abs(g) for g in gaps] or [0])
    rows.append(row)
os.remove(tmp)

fps_dur = None
worst_v = worst_a = worst_av = worst_dts = 0.0
issues = []
for i, r in enumerate(rows):
    if not r["v_key0"]:
        issues.append(f"seg{i}: first video packet not a keyframe")
    if r["v_bad_dts"] or r["v_pts_lt_dts"]:
        issues.append(f"seg{i}: dts order {r['v_bad_dts']} / pts<dts {r['v_pts_lt_dts']}")
    if "a_first" in r:
        worst_av = max(worst_av, abs(r["a_first"] - r["v_first"]))
        if r["a_maxgap"] > 1e-6:
            issues.append(f"seg{i}: audio gap inside segment {r['a_maxgap']*1000:.2f} ms")
    if i + 1 < len(rows):
        n = rows[i + 1]
        dv = n["v_first"] - r["v_end"]
        dd = n["v_dts0"] - r["v_dts_end"]
        worst_v = max(worst_v, abs(dv))
        worst_dts = max(worst_dts, abs(dd))
        if "a_first" in r:
            da = n["a_first"] - r["a_end"]
            worst_a = max(worst_a, abs(da))
            if abs(da) > 1e-6:
                issues.append(f"seg{i}->{i+1}: audio {'gap' if da > 0 else 'overlap'} {da*1000:.3f} ms")
        if abs(dv) > 1e-6:
            issues.append(f"seg{i}->{i+1}: video pts {'gap' if dv > 0 else 'overlap'} {dv*1000:.3f} ms")
        if abs(dd) > 1e-6:
            issues.append(f"seg{i}->{i+1}: video dts {'gap' if dd > 0 else 'overlap'} {dd*1000:.3f} ms")
    # playlist position vs media time (offset = first segment's v_first)
pos = 0.0
worst_pl = 0.0
for i, r in enumerate(rows):
    worst_pl = max(worst_pl, abs((r["v_first"] - rows[0]["v_first"]) - pos))
    pos += r["extinf"]

print(f"segments={len(rows)} worst: video pts boundary {worst_v*1000:.3f} ms, video dts boundary {worst_dts*1000:.3f} ms, "
      f"audio boundary {worst_a*1000:.3f} ms, A/V start offset {worst_av*1000:.2f} ms, playlist-vs-media {worst_pl*1000:.3f} ms")
for x in issues[:15]:
    print("  ISSUE", x)
print(f"issues={len(issues)}")

# Full decode check of the concatenation.
full = os.path.join(d, "_full.mp4")
with open(full, "wb") as f:
    f.write(init)
    for name in segs:
        f.write(open(os.path.join(d, name), "rb").read())
err = subprocess.run(["ffmpeg", "-v", "error", "-i", full, "-f", "null", "-"], capture_output=True, text=True).stderr
lines = [l for l in err.splitlines() if l.strip()]
print(f"decode errors={len(lines)}", ("| " + lines[0]) if lines else "")
os.remove(full)
