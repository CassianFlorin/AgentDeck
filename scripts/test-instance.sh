#!/usr/bin/env bash
# Launch an isolated Debug instance next to the one you're using:
# separate workspace/hosts/caches (in $AGENTDECK_HOME) and its own debug channel.
#   AGENTDECK_HOME=/tmp/ad-test scripts/test-instance.sh      # prints the PID
set -euo pipefail
: "${AGENTDECK_HOME:?set AGENTDECK_HOME to a scratch directory}"
APP="$(cd "$(dirname "$0")/.." && pwd)/build/DerivedData/Build/Products/Debug/AgentDeck.app"
mkdir -p "$AGENTDECK_HOME"
open -n -g --env "AGENTDECK_HOME=$AGENTDECK_HOME" "$APP"
sleep 2
pgrep -n -f "$APP/Contents/MacOS/AgentDeck"
