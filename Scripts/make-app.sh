#!/bin/bash
# Wrap the SwiftPM binary in a .app so it gets a dock icon, a menu bar, and a
# double-click launch. No Xcode project, no signing identity needed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DejaVu.app"
# --disable-sandbox: SwiftPM sandboxes its own manifest compile, which cannot nest
# inside the Homebrew build sandbox. Nothing here needs SwiftPM's sandbox.
swift build -c release --disable-sandbox
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --disable-sandbox --show-bin-path)/DejaVu" "$APP/Contents/MacOS/DejaVu"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Claude Deja Vu</string>
  <key>CFBundleDisplayName</key>       <string>Claude Déjà Vu</string>
  <key>CFBundleExecutable</key>        <string>DejaVu</string>
  <key>CFBundleIdentifier</key>        <string>dev.xsreality.dejavu</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: free, and all Apple Silicon needs to execute the binary.
# Not Developer ID — that only matters once a download quarantines the bundle.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP — open it with: open $APP"
