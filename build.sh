#!/bin/bash
# Builds DeviceHop.app (universal if possible) into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCHS[@]}"; then
  ARCHS=()
  swift build -c release
fi
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/DeviceHop"

VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
APP="build/DeviceHop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DeviceHop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.devicehop</string>
  <key>CFBundleName</key><string>DeviceHop</string>
  <key>CFBundleExecutable</key><string>DeviceHop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>DeviceHop pairs your keyboard and mouse, and talks to DeviceHop on your other Macs.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/DeviceHop"))"
