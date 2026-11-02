#!/bin/sh
# Renders the images made from the layered app icon, app/Support/AppIcon.icon (an Icon Composer
# document: a gradient fill and two SVG layers, the bars and the deck):
#
#   app/Support/AppIcon.icns   the icon macOS 14 and 15 show, flattened by actool
#   docs/assets/icon.png       the README image: the default appearance, 512 px
#
# Needs Xcode 26 or later (actool, and ictool inside Icon Composer). Run it after editing the icon.
set -eu
cd "$(dirname "$0")/.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# actool resolves a relative path against its server's directory, not ours.
xcrun actool "$PWD/app/Support/AppIcon.icon" --compile "$tmp" --app-icon AppIcon \
  --platform macosx --minimum-deployment-target 14.0 --target-device mac \
  --standalone-icon-behavior all --output-partial-info-plist "$tmp/partial.plist" >/dev/null
cp "$tmp/AppIcon.icns" app/Support/AppIcon.icns

# On the macOS icon grid the shape is 824 px of a 1024 px canvas: 412 px of 512.
"$ictool" app/Support/AppIcon.icon --export-image --output-file "$tmp/icon.png" \
  --platform macOS --rendition Default --width 412 --height 412 --scale 1 >/dev/null
sips --padToHeightWidth 512 512 "$tmp/icon.png" --out docs/assets/icon.png >/dev/null
echo "rendered app/Support/AppIcon.icns and docs/assets/icon.png"
