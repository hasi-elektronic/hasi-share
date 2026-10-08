#!/bin/sh
# Remux spike: macOS developer harness (server + segment dump + AVPlayer TTFF/seek bench) built from
# the SAME Swift/C sources as the app (Shared/Player/Remux). Needs the macOS FFmpeg libs:
#   FFMPEG_MACOS=1 FFMPEG_FORCE=1 sh scripts/build-ffmpeg.sh
# usage: build-harness.sh <out-dir>
#   <out>/harness <url> dump <dir> [--shuffle] [--transcode]   → then: validate.py <dir>, avsync.py <dir>
#   <out>/harness <url> avplayer                                 → TTFF + seeks 10/50/90 %, access log
#   env: SEG (target s), BLOCK_KB, INFLIGHT
set -eu
A="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?out dir}"
mkdir -p "$OUT"
clang -c -O2 -g -Wall -Wextra -Wno-unused-parameter -I "$A/Vendor/FFmpeg/include" \
  "$A/Shared/Player/Remux/CNovaRemux/nova_remux.c" -o "$OUT/nova_remux.o"
swiftc -swift-version 6 -O -g -I "$A/Shared/Player/Remux/CNovaRemux" \
  "$A/Shared/Player/Remux/RemuxByteSource.swift" "$A/Shared/Player/Remux/RemuxSession.swift" \
  "$A/Shared/Player/Remux/RemuxHTTPServer.swift" "$(dirname "$0")/harness-main.swift" "$OUT/nova_remux.o" \
  "$A/Vendor/FFmpeg/macos/libavformat.a" "$A/Vendor/FFmpeg/macos/libavcodec.a" \
  "$A/Vendor/FFmpeg/macos/libswresample.a" "$A/Vendor/FFmpeg/macos/libavutil.a" -lz -o "$OUT/harness"
echo "built $OUT/harness"
