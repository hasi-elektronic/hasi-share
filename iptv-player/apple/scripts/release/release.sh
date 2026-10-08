#!/bin/bash
# Archive, export and upload iOS + tvOS to TestFlight, then wait until App Store Connect reports the build VALID.
# Usage: apple/scripts/release/release.sh <outDir>   (build number comes from Config/Shared.xcconfig)
# Needs ~/.hermes/.env: APPLE_ISSUER_ID, APPLE_KEY_ID, APPLE_KEY_PATH; App Store profiles "NovaPlayer iOS AppStore" / "NovaPlayer tvOS AppStore".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; APPLE="$(cd "$HERE/../.." && pwd)"; OUT="${1:?outDir}"; mkdir -p "$OUT"
eval "$(grep -E '^APPLE_(ISSUER_ID|KEY_ID)=' ~/.hermes/.env)"
BUILD=$(grep -E '^CURRENT_PROJECT_VERSION' "$APPLE/Config/Shared.xcconfig" | awk '{print $3}')
cd "$APPLE" && xcodegen generate -q || exit 1
for p in iOS:ios tvOS:appletvos; do plat=${p%%:*}; t=${p##*:}
  rm -rf "$OUT/b$BUILD-$plat.xcarchive" "$OUT/b$BUILD-ipa-$plat"
  xcodebuild archive -project NovaPlayer.xcodeproj -scheme NovaPlayer-$plat -configuration Release -destination "generic/platform=$plat" \
    -archivePath "$OUT/b$BUILD-$plat.xcarchive" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=KL2U82NUL6 \
    CODE_SIGN_IDENTITY=7E71558BC4220D8F5E0DB584E84B586BAC7185C5 "PROVISIONING_PROFILE_SPECIFIER=NovaPlayer $plat AppStore" -quiet \
    > "$OUT/b$BUILD-archive-$plat.log" 2>&1 || { echo "$plat archive FAILED"; grep error: "$OUT/b$BUILD-archive-$plat.log" | head -5; exit 1; }
  xcodebuild -exportArchive -archivePath "$OUT/b$BUILD-$plat.xcarchive" -exportPath "$OUT/b$BUILD-ipa-$plat" \
    -exportOptionsPlist "$HERE/export-$plat.plist" > "$OUT/b$BUILD-export-$plat.log" 2>&1 || { echo "$plat export FAILED"; tail -5 "$OUT/b$BUILD-export-$plat.log"; exit 1; }
  xcrun altool --upload-app -f "$OUT/b$BUILD-ipa-$plat/NovaPlayer.ipa" -t $t --apiKey "$APPLE_KEY_ID" --apiIssuer "$APPLE_ISSUER_ID" \
    > "$OUT/b$BUILD-upload-$plat.log" 2>&1 || { echo "$plat upload FAILED"; grep -E "ERROR|error" "$OUT/b$BUILD-upload-$plat.log" | head -8; exit 1; }
  echo "$plat build $BUILD uploaded"
done
for i in $(seq 1 90); do n=$(node "$HERE/builds.mjs" | grep -cE "build $BUILD (VALID|INVALID|FAILED)"); [ "$n" = "2" ] && break; sleep 30; done
node "$HERE/builds.mjs" | head -3
