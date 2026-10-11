#!/bin/sh
# NovaPlayer brand assets (icon F "flow": play + motion trails, owner choice 2026-10-11) from mark.svgfrag + defs.svgfrag.
# Renders with headless Chrome (no SVG tools needed). usage: brand/render.sh   (writes into apple/ and android/)
set -eu
B="$(cd "$(dirname "$0")" && pwd)"; R="$B/.."; T="$(mktemp -d)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MARK="$(cat "$B/mark.svgfrag")"; DEFS="$(cat "$B/defs.svgfrag")"
# render <out.png> <w> <h> <svg body (viewBox w h)> <viewBox> [transparent]
render() {
  out="$1"; w="$2"; h="$3"; body="$4"; vb="$5"; bg="${6:-}"
  printf '<html><body style="margin:0;background:transparent"><svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="%s">%s%s</svg></body></html>' "$w" "$h" "$vb" "$DEFS" "$body" > "$T/p.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --default-background-color=00000000 \
    --window-size="$w,$h" --screenshot="$T/s.png" "file://$T/p.html" >/dev/null 2>&1
  if [ -z "$bg" ]; then sips -s format jpeg "$T/s.png" --out "$T/s.jpg" >/dev/null && sips -s format png "$T/s.jpg" --out "$out" >/dev/null   # opaque, no alpha
  else cp "$T/s.png" "$out"; fi
}
BG='<rect width="100%" height="100%" fill="url(#bg)"/>'
# iOS (1024, opaque)
render "$R/apple/Apps/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png" 1024 1024 "$BG$MARK" "0 0 1024 1024"
# tvOS layered icon: back = gradient, front = mark (transparent), 5:3
TV="$R/apple/Apps/tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
for s in "App Icon.imagestack:400:240:@1x" "App Icon.imagestack:800:480:@2x" "App Icon - App Store.imagestack:1280:768:@1x"; do
  set -- $(echo "$s" | tr ':' ' ' | sed 's/App Icon - App Store.imagestack/AS/;s/App Icon.imagestack/AI/')
  dir=$([ "$1" = AS ] && echo "App Icon - App Store.imagestack" || echo "App Icon.imagestack"); w=$2; h=$3; sc=$4
  render "$TV/$dir/Back.imagestacklayer/Content.imageset/back$sc.png" $w $h "$BG" "0 0 $w $h"
  # mark: 1024 box scaled to 72% of the layer height, centred
  render "$TV/$dir/Front.imagestacklayer/Content.imageset/front$sc.png" $w $h "<g transform=\"translate($((w/2)) $((h/2))) scale($(echo "$h*1.0/1024" | bc -l)) translate(-512 -512)\">$MARK</g>" "0 0 $w $h" transparent
done
# Top Shelf: gradient, mark left, wordmark
shelf() { out="$1"; w=$2; h=$3; s=$(echo "$h/720" | bc -l)
  render "$out" $w $h "$BG<g transform=\"scale($s)\"><g transform=\"translate(330 360) scale(0.5) translate(-512 -512)\">$MARK</g><text x=\"620\" y=\"405\" font-family=\"-apple-system,Helvetica\" font-weight=\"800\" font-size=\"130\" fill=\"#FFFFFF\">NovaPlayer</text></g>" "0 0 $w $h"; }
shelf "$TV/Top Shelf Image.imageset/topshelf@1x.png" 1920 720
shelf "$TV/Top Shelf Image.imageset/topshelf@2x.png" 3840 1440
shelf "$TV/Top Shelf Image Wide.imageset/topshelf@1x.png" 2320 720
shelf "$TV/Top Shelf Image Wide.imageset/topshelf@2x.png" 4640 1440
# Store listing / preview
render "$B/icon-1024.png" 1024 1024 "$BG$MARK" "0 0 1024 1024"
render "$B/play-store-512.png" 512 512 "$BG$MARK" "0 0 1024 1024"
# Android TV banner (320×180 dp → xhdpi 640×360 PNG; TV guidelines want the app name on the banner)
render "$R/android/app/src/main/res/drawable-xhdpi/tv_banner.png" 640 360 "$BG<g transform=\"translate(118 180) scale(0.27) translate(-512 -512)\">$MARK</g><text x=\"232\" y=\"203\" font-family=\"-apple-system,Helvetica\" font-weight=\"800\" font-size=\"66\" fill=\"#FFFFFF\">NovaPlayer</text>" "0 0 640 360"
rm -rf "$T"; echo "brand assets rendered"
