#!/bin/bash
# Build the viewer and install the menu-bar launcher (~/Applications/Unified Control.app) on this Mac.
# Proxy apps ("Cursor · mini.app") are created by the launcher on demand and refresh themselves from it.
# usage: scripts/install-air.sh [host]   (default mini.local)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
HOST=${1:-mini.local}
APP="$HOME/Applications/Unified Control.app"

swift build -c release --product uc-viewer
pkill -f "Unified Control.app/Contents/MacOS/uc-viewer" || true
bundle "$APP" dev.unified-control.launcher "Unified Control" uc-viewer \
  "<key>UCRole</key><string>launcher</string><key>UCHost</key><string>$HOST</string>"
open --stderr /tmp/uc-launcher.log "$APP"
echo "installed $APP — look for the window icon in the menu bar"
