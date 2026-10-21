# Real media samples

Generated with `jrottenberg/ffmpeg:7.1-alpine` (2 s, 160x90 test pattern, 440 Hz tone):

```sh
ffmpeg -f lavfi -i testsrc=size=160x90:rate=25:duration=2 -f lavfi -i sine=frequency=440:duration=2 \
  -c:v libx264 -b:v 80k -c:a aac -b:a 32k -f mpegts sample.ts
ffmpeg -i sample.ts -c copy -movflags +faststart sample.mp4
ffmpeg -i sample.ts -c copy sample.mkv
ffmpeg -i sample.ts -c:v libx264 -c:a aac -f flv sample.flv
ffmpeg -i sample.ts -c:v mpeg4 -c:a libmp3lame sample.avi
ffmpeg -i sample.ts -c:v libvpx-vp9 -c:a libopus sample.webm
ffmpeg -i sample.ts -c copy -f hls -hls_time 1 -hls_playlist_type vod hls/index.m3u8
ffmpeg -i sample.mp4 -c copy -f dash dash/manifest.mpd
# two audio tracks tagged tur / eng
ffmpeg -f lavfi -i testsrc=… -f lavfi -i sine=440 -f lavfi -i sine=880 -map 0:v -map 1:a -map 2:a \
  -metadata:s:a:0 language=tur -metadata:s:a:1 language=eng -f mpegts sample_multiaudio.ts
```

Uses:
1. Unit tests of the container sniffer on both platforms (`expected.json`).
2. On-device playback checks: serve this folder on the LAN
   (`python3 -m http.server 8000`) and run *Settings → Diagnostics → Format test*
   (`../stream-samples.json`).
