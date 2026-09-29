#!/bin/bash
# Build the host on this Mac, sign it, install it on the host Mac and (re)launch it.
# usage: scripts/deploy-host.sh [host]   (default mini.local)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
HOST=${1:-mini.local}
APP=build/UnifiedControlHost.app

swift build -c release --product uc-host
bundle "$APP" dev.unified-control.host "Unified Control Host" uc-host

ssh "$HOST" 'mkdir -p ~/.unified-control ~/Applications && chmod 700 ~/.unified-control; pkill -x uc-host || true'
scp -q ~/.unified-control/psk "$HOST":.unified-control/psk
ssh "$HOST" 'chmod 600 ~/.unified-control/psk'
rsync -a --delete "$APP" "$HOST":Applications/
ssh "$HOST" 'open --stderr /tmp/uc-host.log ~/Applications/UnifiedControlHost.app'
sleep 2
ssh "$HOST" 'tail -3 /tmp/uc-host.log'
