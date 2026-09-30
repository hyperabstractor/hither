#!/bin/bash
# Build "Unified Control.app" and install it on a Mac. It shares that Mac's windows (its host runs as a helper
# inside the app) and shows <peer>'s windows in its menu bar. Proxy apps ("Cursor · mini.app") are made on demand.
# usage: scripts/install.sh [peer] [install-on]      (defaults: mini.local, this Mac)
#   scripts/install.sh                          → this Mac shows the Mini's apps
#   scripts/install.sh air.local mini.local     → the Mini shows the Air's apps
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
PEER=${1:-mini.local}
ON=${2:-$(scutil --get LocalHostName).local}
APP="build/Unified Control.app"
# Restart on the new copy (open proxies relaunch the app the moment it dies, so the new one must already be in
# place). The standalone host app this replaces goes too.
RESTART='pkill -f "Unified Control.app/Contents/MacOS/uc-viewer"; pkill -x uc-host; rm -rf ~/Applications/UnifiedControlHost.app
  sleep 1; open --stderr /tmp/uc-launcher.log ~/Applications/Unified\ Control.app'

swift build -c release
bundle "$APP" dev.unified-control.launcher "Unified Control" uc-viewer \
  "<key>UCRole</key><string>launcher</string><key>UCHost</key><string>$PEER</string>"
bundle "$APP/Contents/Helpers/Unified Control Host.app" dev.unified-control.host "Unified Control Host" uc-host
sign "$APP"   # again, now that it holds the helper

if [ "$ON" = "$(scutil --get LocalHostName).local" ]; then
  mkdir -p ~/Applications && rsync -a --delete "$APP" ~/Applications/
  eval "$RESTART" || true
else
  ssh "$ON" 'mkdir -p ~/Applications ~/.unified-control && chmod 700 ~/.unified-control'
  scp -q ~/.unified-control/psk "$ON":.unified-control/psk
  ssh "$ON" 'chmod 600 ~/.unified-control/psk'
  rsync -a --delete "$APP" "$ON":Applications/
  ssh "$ON" "$RESTART"
fi
echo "installed on $ON, showing $PEER's apps (host log: $ON:/tmp/uc-host.log)"
