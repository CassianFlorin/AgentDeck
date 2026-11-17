#!/usr/bin/env bash
# Launch an isolated Debug instance next to the one you're using:
# separate workspace/hosts/caches (in $WAITLIGHT_HOME) and its own debug channel.
#   WAITLIGHT_HOME=/tmp/ad-test scripts/test-instance.sh      # prints the PID
set -euo pipefail
: "${WAITLIGHT_HOME:?set WAITLIGHT_HOME to a scratch directory}"
APP="$(cd "$(dirname "$0")/.." && pwd)/build/DerivedData/Build/Products/Debug/Waitlight.app"
mkdir -p "$WAITLIGHT_HOME"
open -n -g --env "WAITLIGHT_HOME=$WAITLIGHT_HOME" "$APP"
sleep 2
pgrep -n -f "$APP/Contents/MacOS/Waitlight"
