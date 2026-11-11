#!/usr/bin/env bash
# Send a command to a running Debug build of AgentDeck (see Sources/App/DebugHooks.swift).
#   scripts/debug-cmd.sh 'type:ls -la\n'
#   scripts/debug-cmd.sh 'binding:new_split:right'
# Targets the isolated test instance when AGENTDECK_HOME is set (channel AgentDeckDebug.test),
# or an explicit AGENTDECK_DEBUG_CHANNEL.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <command>" >&2; exit 2; }
CHANNEL="${AGENTDECK_DEBUG_CHANNEL:-$([ -n "${AGENTDECK_HOME:-}" ] && echo AgentDeckDebug.test || echo AgentDeckDebug)}"
CMD="$1" CHANNEL="$CHANNEL" swift -e '
import Foundation
let env = ProcessInfo.processInfo.environment
DistributedNotificationCenter.default().postNotificationName(
    .init(env["CHANNEL"]!), object: env["CMD"]!, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
'
