#!/bin/bash
# Installs DeviceHop to /Applications and starts it at login.
# Usage: ./install.sh            install or update
#        ./install.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"

APP_DEST="/Applications/DeviceHop.app"
AGENT="$HOME/Library/LaunchAgents/local.devicehop.plist"

stop_running() {
  launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
  pkill -x DeviceHop 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  stop_running
  rm -f "$AGENT"
  rm -rf "$APP_DEST"
  echo "DeviceHop uninstalled."
  exit 0
fi

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Run: xcode-select --install"
  echo "Then run ./install.sh again."
  exit 1
fi

./build.sh
stop_running
rm -rf "$APP_DEST"
cp -R build/DeviceHop.app "$APP_DEST"
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.devicehop</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>$APP_DEST</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo
echo "DeviceHop installed and running (keyboard icon in the menu bar)."
echo "It will start automatically at login. Allow the Bluetooth and Local Network prompts."
