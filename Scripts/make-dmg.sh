#!/bin/bash
# Package the .app as a DMG — a plain download, no Homebrew needed.
# A downloaded DMG is quarantined and this app is ad-hoc signed (no Developer
# ID), so the first launch needs System Settings > Privacy & Security >
# "Open Anyway". Notarizing removes that step and costs $99/yr.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/make-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/DejaVu.app/Contents/Info.plist)"
DMG="build/ClaudeDejaVu-$VERSION.dmg"

# ponytail: plain drag-to-Applications window. A background image and placed
# icons need a read-write DMG plus AppleScript to set the view — add that if
# the hand-off ever needs to look designed.
STAGE="$(mktemp -d)"
cp -R build/DejaVu.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Claude Deja Vu" -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"

echo "built $DMG"
