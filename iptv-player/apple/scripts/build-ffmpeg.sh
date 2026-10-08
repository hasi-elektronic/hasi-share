#!/bin/sh
# Builds a minimal LGPL FFmpeg (demux/remux + audio-fallback transcode only) for iOS and tvOS and
# packages it as ONE dynamic framework per platform slice → apple/Vendor/FFmpeg/FFmpeg.xcframework
# (git-ignored, like VLCKit). Used by the "Apple + Remux (Beta)" engine (MKV → HLS/fMP4 → AVPlayer).
#
#   FFmpeg.xcframework   ios-arm64 · ios-arm64-simulator · tvos-arm64 · tvos-arm64-simulator
#   include/             public FFmpeg headers (identical for all slices; HEADER_SEARCH_PATHS)
#   COPYING.LGPLv2.1     licence text shipped in the app (Settings → Open-source licenses)
#   macos/               (FFMPEG_MACOS=1 only) static macOS arm64 libs for the developer harness
#
# Licence (docs/SECURITY.md, LGPL-2.1+): configured WITHOUT --enable-gpl / --enable-nonfree /
# --enable-version3, so every enabled component is LGPL-2.1-or-later. All four libraries
# (avformat, avcodec, avutil, swresample) are linked into ONE *dynamic* framework, so a user can
# replace FFmpeg.framework with a modified build (LGPL §6 relinking) without touching the app binary.
#
# Reproducible: pinned release tarball, SHA-256 checked (the tarball's GPG signature was verified once
# against https://ffmpeg.org/ffmpeg-devel.asc, key FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8).
# Idempotent (stamp file); ~3–4 min on an M4 Pro for all slices. Intermediates live in a temp dir
# that is removed at the end (disk!).
#
# Environment:
#   FFMPEG_CACHE   download cache (default ~/Library/Caches/NovaPlayer/ffmpeg)
#   FFMPEG_FORCE=1 rebuild even if the stamp matches
#   FFMPEG_MACOS=1 also build static macOS arm64 libs (developer harness only, never shipped)
#   FFMPEG_JOBS    parallel make jobs (default: number of CPUs)
set -eu

VERSION="8.1.3"
ARCHIVE="ffmpeg-${VERSION}.tar.xz"
URL="https://ffmpeg.org/releases/${ARCHIVE}"
SHA256="7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"
MIN_OS="17.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR="${SCRIPT_DIR}/../Vendor/FFmpeg"
STAMP="${VENDOR}/.stamp"
CACHE="${FFMPEG_CACHE:-$HOME/Library/Caches/NovaPlayer/ffmpeg}"
JOBS="${FFMPEG_JOBS:-$(sysctl -n hw.ncpu)}"
# Bump the suffix whenever the configure line below changes.
WANT_STAMP="${VERSION}-remux1"

if [ "${FFMPEG_FORCE:-0}" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ] \
   && [ -d "${VENDOR}/FFmpeg.xcframework" ] && { [ "${FFMPEG_MACOS:-0}" != "1" ] || [ -d "${VENDOR}/macos" ]; }; then
  exit 0
fi

START=$(date +%s)
mkdir -p "$CACHE"
file="${CACHE}/${ARCHIVE}"
if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$SHA256" ]; then
  echo "FFmpeg: downloading ${ARCHIVE} …"
  curl -fL --retry 3 -o "${file}.part" "$URL"
  mv "${file}.part" "$file"
fi
got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
if [ "$got" != "$SHA256" ]; then
  echo "FFmpeg: SHA-256 mismatch for ${ARCHIVE} (got $got, want $SHA256)" >&2
  rm -f "$file"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
tar -xf "$file" -C "$WORK"
SRC="${WORK}/ffmpeg-${VERSION}"

# Only what the remuxer needs (CONTRACT §6.1 "Apple + Remux"): demux MKV/MP4/TS (+ raw audio, HLS),
# mux fragmented MP4 (+ WebVTT for a later subtitle step), parsers for timestamps/extradata, and
# decoders + the native AAC encoder for audio AVPlayer cannot play (DTS, TrueHD, Opus, Vorbis, FLAC, MP2/MP3).
COMMON_FLAGS="--disable-gpl --disable-nonfree --disable-programs --disable-doc --disable-everything
  --disable-autodetect --enable-zlib --enable-pthreads
  --disable-avdevice --disable-avfilter --disable-swscale --enable-swresample
  --enable-static --disable-shared --enable-pic --disable-debug
  --enable-demuxer=matroska,mov,mpegts,aac,ac3,eac3,mp3,hls
  --enable-muxer=mp4,mov,webvtt
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,mpegvideo,dca,opus,vorbis,flac,mlp
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata
  --enable-decoder=aac,ac3,eac3,mp2,mp3,dca,opus,vorbis,flac,truehd,mlp
  --enable-encoder=aac
  --enable-protocol=file"

# build <name> <sdk> <clang target triple>
build() {
  name="$1"; sdk="$2"; triple="$3"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  out="${WORK}/out/${name}"
  bdir="${WORK}/build/${name}"
  mkdir -p "$bdir" "$out"
  echo "FFmpeg: configuring ${name} (${triple}) …"
  # shellcheck disable=SC2086
  (cd "$bdir" && "${SRC}/configure" --prefix="$out" --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc="$cc" --sysroot="$sysroot" \
      --extra-cflags="-target ${triple} -fno-common -O2" --extra-ldflags="-target ${triple}" \
      $COMMON_FLAGS >"${bdir}/configure.log" 2>&1) || { tail -30 "${bdir}/config.log" >&2; exit 1; }
  echo "FFmpeg: building ${name} …"
  (cd "$bdir" && make -j"$JOBS" >"${bdir}/make.log" 2>&1 && make install >>"${bdir}/make.log" 2>&1) \
    || { tail -40 "${bdir}/make.log" >&2; exit 1; }
}

# framework <name> <sdk> <triple> <platform plist name>
framework() {
  name="$1"; sdk="$2"; triple="$3"; platform="$4"
  out="${WORK}/out/${name}"
  fw="${WORK}/fw/${name}/FFmpeg.framework"
  mkdir -p "$fw"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  # One dylib from the four static libs (all symbols exported; app → FFmpeg API only).
  "$cc" -target "$triple" -isysroot "$sysroot" -dynamiclib \
    -install_name @rpath/FFmpeg.framework/FFmpeg \
    -compatibility_version 1 -current_version "$VERSION" \
    -Wl,-all_load "${out}/lib/libavformat.a" "${out}/lib/libavcodec.a" "${out}/lib/libswresample.a" "${out}/lib/libavutil.a" \
    -lz -o "${fw}/FFmpeg"
  xcrun strip -x "${fw}/FFmpeg"
  cat >"${fw}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>FFmpeg</string>
  <key>CFBundleIdentifier</key><string>com.hasielektronic.ffmpeg</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>FFmpeg</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${platform}</string></array>
  <key>MinimumOSVersion</key><string>${MIN_OS}</string>
</dict>
</plist>
PLIST
}

build ios        iphoneos         "arm64-apple-ios${MIN_OS}"
build ios-sim    iphonesimulator  "arm64-apple-ios${MIN_OS}-simulator"
build tvos       appletvos        "arm64-apple-tvos${MIN_OS}"
build tvos-sim   appletvsimulator "arm64-apple-tvos${MIN_OS}-simulator"
framework ios      iphoneos         "arm64-apple-ios${MIN_OS}"           iPhoneOS
framework ios-sim  iphonesimulator  "arm64-apple-ios${MIN_OS}-simulator" iPhoneSimulator
framework tvos     appletvos        "arm64-apple-tvos${MIN_OS}"          AppleTVOS
framework tvos-sim appletvsimulator "arm64-apple-tvos${MIN_OS}-simulator" AppleTVSimulator

rm -rf "$VENDOR"
mkdir -p "$VENDOR"
xcodebuild -create-xcframework \
  -framework "${WORK}/fw/ios/FFmpeg.framework" \
  -framework "${WORK}/fw/ios-sim/FFmpeg.framework" \
  -framework "${WORK}/fw/tvos/FFmpeg.framework" \
  -framework "${WORK}/fw/tvos-sim/FFmpeg.framework" \
  -output "${VENDOR}/FFmpeg.xcframework" >/dev/null
cp -R "${WORK}/out/ios/include" "${VENDOR}/include"
cp "${SRC}/COPYING.LGPLv2.1" "${VENDOR}/COPYING.LGPLv2.1"

if [ "${FFMPEG_MACOS:-0}" = "1" ]; then
  build macos macosx "arm64-apple-macos13.0"
  mkdir -p "${VENDOR}/macos"
  cp "${WORK}"/out/macos/lib/lib*.a "${VENDOR}/macos/"
fi

echo "$WANT_STAMP" > "$STAMP"
END=$(date +%s)
echo "FFmpeg ${VERSION}: built in $((END - START)) s → $(du -sh "$VENDOR" | cut -f1) in ${VENDOR}"
for s in ios tvos; do
  echo "  ${s} device dylib: $(stat -f %z "${WORK}/fw/${s}/FFmpeg.framework/FFmpeg") bytes"
done
