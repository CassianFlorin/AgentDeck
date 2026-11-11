import Foundation

/// Precise agent status via the agent's own hooks.
///
/// For Claude Code we pass `--settings '<json>'` at launch (merged with, never
/// replacing, the user's settings files). Each hook runs AgentDeck's own
/// binary with AGENTDECK_HOOK set; that process forwards the event to the
/// running app as a distributed notification and exits immediately.
/// The pane is identified by AGENTDECK_PANE, which every terminal gets in its
/// environment.
enum AgentHook {
    static let modeEnv = "AGENTDECK_HOOK"
    static let paneEnv = "AGENTDECK_PANE"
    static let notificationName = Notification.Name("AgentDeckAgentEvent")

    struct Event {
        let paneID: String
        let name: String
        let message: String?
    }

    /// Call first thing at launch. Returns only if we're not in hook mode.
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env[modeEnv] else { return }
        let pane = env[paneEnv] ?? ""
        var name = mode
        var message: String?
        if mode == "claude" {
            // Claude Code passes the hook payload as JSON on stdin.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                name = (e["hook_event_name"] as? String) ?? name
                message = e["message"] as? String
            }
        }
        if !pane.isEmpty {
            let payload = [pane, name, message ?? ""].joined(separator: "\t")
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: payload, userInfo: nil, deliverImmediately: true)
        }
        exit(0)
    }

    static func parse(_ object: Any?) -> Event? {
        guard let s = object as? String else { return nil }
        let parts = s.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let msg = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return Event(paneID: parts[0], name: parts[1], message: msg)
    }

    /// Extra arguments for an agent launch line (already shell-quoted), or "".
    /// For Claude Code this writes claude-hooks.json into the support folder.
    static func launchArguments(for agent: AgentKind) -> String {
        guard agent.hooks == .claude, let exe = Bundle.main.executablePath else { return "" }
        let command = "\(modeEnv)=claude \(SSH.quote(exe))"
        let hook: [String: Any] = ["type": "command", "command": command, "timeout": 5]
        func entry(matcher: String? = nil) -> [[String: Any]] {
            var e: [String: Any] = ["hooks": [hook]]
            if let matcher { e["matcher"] = matcher }
            return [e]
        }
        let settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": entry(),
            "PreToolUse": entry(matcher: "*"),
            "Notification": entry(),
            "Stop": entry(),
        ]]
        // A file keeps the typed command short and readable.
        let file = AppPaths.support.appendingPathComponent("claude-hooks.json")
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: file, options: .atomic)) != nil else { return "" }
        return "--settings \(SSH.quote(file.path))"
    }
}
