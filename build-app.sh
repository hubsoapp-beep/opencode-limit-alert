#!/bin/sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$DIR/LimitAlertApp"
BUILD_DIR="$APP_DIR/.build/release"
OUT="$HOME/Applications/LimitAlert.app"

cd "$APP_DIR"
swift build -c release 2>&1 | tail -5

mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BUILD_DIR/LimitAlert" "$OUT/Contents/MacOS/LimitAlert"
chmod +x "$OUT/Contents/MacOS/LimitAlert"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>LimitAlert</string>
  <key>CFBundleIdentifier</key>
  <string>com.opencode.limit-alert</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleExecutable</key>
  <string>LimitAlert</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
</dict>
</plist>
PLIST

echo "Built $OUT"