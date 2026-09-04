#!/bin/bash
# Render Resources/icon.svg into the AppIcon.icns that make-app.sh drops in the
# bundle. Run it after editing the SVG; the .icns is committed so a build needs
# neither rsvg-convert nor this script.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "needs: brew install librsvg"; exit 1; }

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for pair in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
            256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  px="${pair%%:*}"; name="${pair##*:}"
  rsvg-convert -w "$px" -h "$px" Resources/icon.svg -o "$SET/icon_$name.png"
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "built Resources/AppIcon.icns"
