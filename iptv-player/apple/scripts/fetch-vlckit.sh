#!/bin/sh
# Downloads the official VLCKit 3.x binaries (VideoLAN, LGPL-2.1) for iOS and tvOS, verifies
# their SHA-256, thins them and places the xcframeworks in apple/Vendor/VLCKit/ (git-ignored).
#
#   MobileVLCKit.xcframework  → NovaPlayer-iOS   (module `MobileVLCKit`)
#   TVVLCKit.xcframework      → NovaPlayer-tvOS  (module `TVVLCKit`)
#
# Thinning: device slice arm64 only (armv7/armv7s removed), simulator arm64 + x86_64 (i386
# removed). Both stay *dynamic* frameworks (LGPL-2.1 relinking requirement, docs/SECURITY.md).
#
# Idempotent: does nothing when the stamp file matches. XcodeGen runs it as preGenCommand.
# Environment:
#   VLCKIT_CACHE   download cache (default ~/Library/Caches/NovaPlayer/vlckit)
#   VLCKIT_FORCE=1 rebuild even if the stamp matches
set -eu

VERSION="3.7.3"
BUILD="319ed2c0-79128878"
BASE_URL="https://download.videolan.org/pub/cocoapods/prod"
IOS_ARCHIVE="MobileVLCKit-${VERSION}-${BUILD}.tar.xz"
TV_ARCHIVE="TVVLCKit-${VERSION}-${BUILD}.tar.xz"
IOS_SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
TV_SHA256="b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR="${SCRIPT_DIR}/../Vendor/VLCKit"
STAMP="${VENDOR}/.stamp"
CACHE="${VLCKIT_CACHE:-$HOME/Library/Caches/NovaPlayer/vlckit}"
WANT_STAMP="${VERSION}-${BUILD}-thin2"

if [ "${VLCKIT_FORCE:-0}" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ] \
   && [ -d "${VENDOR}/MobileVLCKit.xcframework" ] && [ -d "${VENDOR}/TVVLCKit.xcframework" ]; then
  exit 0
fi

mkdir -p "$CACHE"

fetch() { # archive sha256
  file="${CACHE}/$1"
  if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$2" ]; then
    echo "VLCKit: downloading $1 from download.videolan.org …"
    curl -fL --retry 3 -o "${file}.part" "${BASE_URL}/$1"
    mv "${file}.part" "$file"
  fi
  got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    echo "VLCKit: SHA-256 mismatch for $1 (got $got, want $2)" >&2
    rm -f "$file"
    exit 1
  fi
}

# Keeps only the given architectures in a Mach-O (framework binary or dSYM DWARF file).
thin() { # file arch...
  f="$1"; shift
  have="$(lipo -archs "$f")"
  args=""
  for a in $have; do
    keep=0
    for w in "$@"; do [ "$a" = "$w" ] && keep=1; done
    [ $keep -eq 0 ] && args="$args -remove $a"
  done
  # shellcheck disable=SC2086
  [ -n "$args" ] && lipo $args "$f" -output "$f.thin" && mv "$f.thin" "$f"
  return 0
}

# Thins every slice of an xcframework and rewrites SupportedArchitectures in its Info.plist.
thin_xcframework() { # xcframework module
  xc="$1"; module="$2"
  plist="${xc}/Info.plist"
  i=0
  while id="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${i}:LibraryIdentifier" "$plist" 2>/dev/null)"; do
    variant="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${i}:SupportedPlatformVariant" "$plist" 2>/dev/null || true)"
    if [ "$variant" = "simulator" ]; then archs="arm64 x86_64"; else archs="arm64"; fi
    thin "${xc}/${id}/${module}.framework/${module}" $archs
    dwarf="${xc}/${id}/dSYMs/${module}.framework.dSYM/Contents/Resources/DWARF/${module}"
    if [ "$variant" = "simulator" ]; then
      # Simulator symbols are never uploaded; saves ~300 MB per framework.
      rm -rf "${xc}/${id}/dSYMs"
      /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${i}:DebugSymbolsPath" "$plist" 2>/dev/null || true
    elif [ -f "$dwarf" ]; then
      thin "$dwarf" $archs
    fi
    /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${i}:SupportedArchitectures" "$plist"
    /usr/libexec/PlistBuddy -c "Add :AvailableLibraries:${i}:SupportedArchitectures array" "$plist"
    j=0
    for a in $archs; do
      /usr/libexec/PlistBuddy -c "Add :AvailableLibraries:${i}:SupportedArchitectures:${j} string ${a}" "$plist"
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

fetch "$IOS_ARCHIVE" "$IOS_SHA256"
fetch "$TV_ARCHIVE" "$TV_SHA256"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "VLCKit: extracting …"
tar -xf "${CACHE}/${IOS_ARCHIVE}" -C "$WORK"
tar -xf "${CACHE}/${TV_ARCHIVE}" -C "$WORK"

thin_xcframework "${WORK}/MobileVLCKit-binary/MobileVLCKit.xcframework" MobileVLCKit
thin_xcframework "${WORK}/TVVLCKit-binary/TVVLCKit.xcframework" TVVLCKit

rm -rf "$VENDOR"
mkdir -p "$VENDOR"
mv "${WORK}/MobileVLCKit-binary/MobileVLCKit.xcframework" "$VENDOR/"
mv "${WORK}/TVVLCKit-binary/TVVLCKit.xcframework" "$VENDOR/"
cp "${WORK}/MobileVLCKit-binary/COPYING.txt" "${VENDOR}/COPYING.txt"
cp "${WORK}/MobileVLCKit-binary/NEWS.txt" "${VENDOR}/NEWS.txt"
echo "$WANT_STAMP" > "$STAMP"
echo "VLCKit ${VERSION}: $(du -sh "$VENDOR" | cut -f1) in ${VENDOR}"
