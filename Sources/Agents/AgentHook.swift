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
    static let eventEnv = "AGENTDECK_EVENT"
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
            // Claude Code, Grok and Codex all pass the hook payload as JSON on
            // stdin, with the event in `hook_event_name`.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                name = (e["hook_event_name"] as? String) ?? name
                message = e["message"] as? String
                // A permission request names the tool rather than carrying a message.
                if message == nil, name == "PermissionRequest", let tool = e["tool_name"] as? String {
                    message = "等你批准：\(tool)"
                }
            }
        }
        // A hook registered for one kind of an event says which (see DropIn).
        if let event = env[eventEnv], !event.isEmpty { name = event }
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

    /// The launch line with whatever makes the agent report to us.
    static func decorate(_ line: String, for agent: AgentKind) -> String {
        switch agent.hooks {
        case .claude:
            let extra = launchArguments(for: agent)
            return extra.isEmpty ? line : "\(line) \(extra)"
        case .codex:
            // The profile goes right after the executable: it is a global
            // option, and what follows may be a subcommand ("resume …").
            guard DropIn.codex.isInstalled, let exe = agent.executable, line.hasPrefix(exe) else { return line }
            DropIn.codex.refresh()
            return exe + " -p \(DropIn.codexProfile)" + line.dropFirst(exe.count)
        case .grok:
            if DropIn.grok.isInstalled { DropIn.grok.refresh() }
            return line
        case .none:
            return line
        }
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

// MARK: - Opt-in hooks for agents that only read their own config folder

extension AgentHook {
    /// Grok and Codex have no flag like Claude's `--settings`: they load hooks
    /// from their config folder, and run a new one only after you trust it
    /// there. So nothing is written unless you turn it on in 管理 Agent, and
    /// what is written is one file of our own; yours are left as they are.
    ///
    /// The hook does nothing outside AgentDeck: it checks AGENTDECK_PANE first.
    enum DropIn {
        case grok, codex

        static let codexProfile = "agentdeck"

        /// `$GROK_HOME` / `$CODEX_HOME`, as the agents themselves resolve them.
        private var home: URL {
            let env = ProcessInfo.processInfo.environment
            let (key, fallback) = self == .grok ? ("GROK_HOME", ".grok") : ("CODEX_HOME", ".codex")
            if let dir = env[key], !dir.isEmpty { return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
        }

        var file: URL {
            switch self {
            case .grok: return home.appendingPathComponent("hooks/agentdeck.json")
            // `codex -p agentdeck` layers this on top of the user's config.toml.
            case .codex: return home.appendingPathComponent("\(Self.codexProfile).config.toml")
            }
        }

        var isInstalled: Bool { FileManager.default.fileExists(atPath: file.path) }

        /// (event the agent fires, matcher, event we report it as)
        private var events: [(name: String, matcher: String?, reportAs: String?)] {
            switch self {
            case .grok:
                return [("UserPromptSubmit", nil, nil), ("PreToolUse", nil, nil), ("Stop", nil, nil),
                        ("StopFailure", nil, nil), ("StopCancelled", nil, nil),
                        ("Notification", "permission_prompt", "PermissionRequest")]
            case .codex:
                return [("UserPromptSubmit", nil, nil), ("PreToolUse", nil, nil), ("PermissionRequest", nil, nil),
                        ("Stop", nil, nil), ("Interrupt", nil, nil)]
            }
        }

        private func command(reportAs: String?) -> String? {
            guard let exe = Bundle.main.executablePath else { return nil }
            let event = reportAs.map { "\(eventEnv)=\($0) " } ?? ""
            return "[ -z \"$\(paneEnv)\" ] || \(event)\(modeEnv)=claude \(SSH.quote(exe))"
        }

        private var contents: String? {
            switch self {
            case .grok:
                var hooks: [String: Any] = [:]
                for e in events {
                    guard let cmd = command(reportAs: e.reportAs) else { return nil }
                    var group: [String: Any] = ["hooks": [["type": "command", "command": cmd, "timeout": 5]]]
                    if let m = e.matcher { group["matcher"] = m }
                    hooks[e.name] = [group]
                }
                guard let data = try? JSONSerialization.data(
                    withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
                return String(decoding: data, as: UTF8.self) + "\n"
            case .codex:
                var out = "# Written by AgentDeck (管理 Agent → Codex → 精确状态). Delete this file to turn it off.\n"
                for e in events {
                    // A JSON string is also a valid TOML basic string.
                    guard let cmd = command(reportAs: e.reportAs),
                          let quoted = try? JSONSerialization.data(withJSONObject: cmd, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                    else { return nil }
                    out += "\n[[hooks.\(e.name)]]\n\n[[hooks.\(e.name).hooks]]\ntype = \"command\"\n"
                    out += "command = \(String(decoding: quoted, as: UTF8.self))\ntimeout = 5\n"
                }
                return out
            }
        }

        @discardableResult
        func install() -> Bool {
            guard let contents else { return false }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? contents.write(to: file, atomically: true, encoding: .utf8)) != nil
        }

        func uninstall() { try? FileManager.default.removeItem(at: file) }

        /// The hook names this app's path; keep it right if the app moved.
        /// Left alone when nothing changed: a changed hook has to be trusted again.
        func refresh() {
            guard isInstalled, let contents, (try? String(contentsOf: file, encoding: .utf8)) != contents else { return }
            install()
        }
    }

    static func dropIn(for agent: AgentKind) -> DropIn? {
        switch agent.hooks {
        case .grok: return .grok
        case .codex: return .codex
        default: return nil
        }
    }

    /// Does this agent report its state itself (rather than us guessing)?
    static func isPrecise(_ agent: AgentKind) -> Bool {
        agent.hooks == .claude || dropIn(for: agent)?.isInstalled == true
    }
}
