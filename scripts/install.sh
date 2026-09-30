#!/bin/bash
# Build Hither.app and install it in ~/Applications, on this Mac or on another one over SSH.
# Hither shares its Mac's windows (the host runs as a helper inside the app) and, once paired, shows the other
# Mac's windows from its menu bar. Proxy apps ("Cursor · mini.app") are made on demand in ~/Applications/Hither.
# usage: scripts/install.sh              → this Mac
#        scripts/install.sh mini.local   → another Mac, over SSH
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
ON=${1:-}
APP=build/Hither.app
# Restart on the new copy (open proxies relaunch the app the moment it dies, so the new one must already be there).
RESTART='pkill -f "Hither.app/Contents/MacOS/hither"; pkill -x hither-host; sleep 1; open --stderr /tmp/hither.log ~/Applications/Hither.app'

swift build -c release
bundle "$APP" dev.hither.app Hither hither "<key>HitherRole</key><string>launcher</string>
  <key>NSBonjourServices</key><array><string>_hither._tcp</string></array>
  <key>NSLocalNetworkUsageDescription</key><string>Hither connects to your other Mac to show its windows.</string>"
bundle "$APP/Contents/Helpers/Hither Host.app" dev.hither.host "Hither Host" hither-host
sign "$APP"   # again, now that it holds the helper

if [ -z "$ON" ] || [ "$ON" = "$(scutil --get LocalHostName).local" ]; then
  mkdir -p ~/Applications && rsync -a --delete "$APP" ~/Applications/
  eval "$RESTART" || true
else
  ssh "$ON" 'mkdir -p ~/Applications'
  rsync -a --delete "$APP" "$ON":Applications/
  ssh "$ON" "$RESTART"
fi
echo "installed on ${ON:-this Mac}: pair from its menu bar icon (host log: /tmp/hither-host.log)"
