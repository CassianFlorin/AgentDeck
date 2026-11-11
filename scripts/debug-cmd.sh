#!/usr/bin/env bash
# Send a command to a running Debug build of AgentDeck (see Sources/App/DebugHooks.swift).
#   scripts/debug-cmd.sh 'paste:ls -la\n'
#   scripts/debug-cmd.sh 'find:error'
#   scripts/debug-cmd.sh 'binding:new_split:right'
#   scripts/debug-cmd.sh 'session:2'
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <command>" >&2; exit 2; }
CMD="$1" swift -e '
import Foundation
let cmd = ProcessInfo.processInfo.environment["CMD"]!
DistributedNotificationCenter.default().postNotificationName(
    .init("AgentDeckDebug"), object: cmd, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
'
