#if DEBUG
import AppKit
import SwiftUI

/// Debug-only remote control, so UI can be exercised without synthetic
/// keystrokes (which land in whatever app is frontmost). Post a distributed
/// notification named "AgentDeckDebug" (or "AgentDeckDebug.test" for an
/// instance started with AGENTDECK_HOME, see AppPaths) whose object is a command string:
///
///   binding:<ghostty action>   e.g. binding:new_split:right, binding:scroll_to_top
///   paste:<text>               bracketed-paste text into the focused pane
///   type:<text>                type text as keystrokes into the focused pane (\n = Return)
///   pastefrom:<pasteboard>     paste from a named pasteboard (files → paths, image → saved PNG path)
///   find:<text>                open the find bar with this text
///   session:<n>                select session n (1-based, sidebar order)
///   hosts                      log saved hosts and their ssh command lines
///   connect:<host name or ssh config alias> / reconnect
///   screen                     log the focused pane's visible text (no screenshot needed)
///   history:<agentID>:<dir>    log the newest conversations found for that agent and folder
///   agents                     log the agent catalog and install detection
///   ui:agents | ui:resume[:<agentID>:<dir>] | ui:close   open/close the agent manager / resume sheet
///   restart                    restart an exited agent in the selected session (resume if known)
///   agent:<agentID>            start that agent in a new split of the selected session
///   dashboard[:show|hide]      toggle the Agent 总览, and log its rows
///   reply:<n>:<text>           answer the n-th agent (sidebar order) as the dashboard's reply field does
///   open:<n>                   open the n-th agent as the dashboard does
///   monitor:show|hide|<kinds>  open/close the 性能 panel, or set its monitors (e.g. cpu,sessions)
///   monitor                    log the 性能 panel's latest readings (monitor:script dumps the server script)
///   dump                       write sessions/split trees to ~/Library/Caches/AgentDeck/debug.log
///
/// From a shell:
///   swift -e 'import Foundation; DistributedNotificationCenter.default()
///     .postNotificationName(.init("AgentDeckDebug"), object: "find:login",
///     userInfo: nil, deliverImmediately: true)'
@MainActor
enum DebugHooks {
    private static var token: NSObjectProtocol?

    static func install(_ workspace: Workspace) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(
            forName: .init(AppPaths.debugChannel), object: nil, queue: .main
        ) { [weak workspace] note in
            guard let cmd = note.object as? String else { return }
            MainActor.assumeIsolated { workspace.map { run(cmd, in: $0) } }
        }
    }

    /// Appends to ~/Library/Caches/AgentDeck/debug.log
    static func log(_ msg: String) {
        let url = AppPaths.cache.appendingPathComponent("debug.log")
        let line = Data((msg + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    private static func run(_ cmd: String, in workspace: Workspace) {
        let (verb, arg) = cmd.firstIndex(of: ":").map {
            (String(cmd[..<$0]), String(cmd[cmd.index(after: $0)...]))
        } ?? (cmd, "")
        let pane = workspace.selected?.focusedPane
        switch verb {
        case "binding": pane?.terminal.performBindingAction(arg)
        case "paste": pane?.terminal.insertPasteText(arg.replacingOccurrences(of: "\\n", with: "\r"))
        case "type": pane?.terminal.typeText(arg.replacingOccurrences(of: "\\n", with: "\r"))
        case "pastefrom":
            // Same conversion as ⌘V, but from a named pasteboard so tests
            // don't clobber the user's clipboard.
            if let text = PasteboardText.read(NSPasteboard(name: .init(arg))) { pane?.terminal.insertPasteText(text) }
        case "dump":
            for (i, sess) in workspace.orderedSessions.enumerated() {
                log("\(i + 1) \(sess.displayName) kind=\(sess.kind.id) activity=\(sess.activity) "
                    + "panes=\(sess.panes.count) zoom=\(sess.zoomedPane != nil) tree=\(sess.root.signature)")
                for p in sess.panes {
                    let a = p.agent
                    log("   pane \(p.terminal.paneID) primary=\(p.isPrimary) focused=\(p === sess.focusedPane) "
                        + "agent=\(a?.kind.id ?? "-") activity=\(a.map { "\($0.activity)" } ?? "-") "
                        + "conv=\(a?.conversationID ?? "-") adopted=\(a?.adopted ?? false)")
                }
            }
        case "history":
            // history:<agentID>:<directory>
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let agent = workspace.catalog.agent(id: parts[0]) else { break }
            let items = ConversationHistory.list(for: agent, directory: parts[1], limit: 5)
            log("history \(agent.id) \(parts[1]): \(items.count) shown")
            for c in items { log("  \(c.updated) \(c.id) \(c.title)") }
        case "agents":
            for a in workspace.catalog.agents {
                log("agent \(a.id) installed=\(String(describing: workspace.catalog.isInstalled(a))) path=\(workspace.catalog.path(of: a) ?? "-")")
            }
        case "ui":
            // ui:agents | ui:terminal-settings | ui:resume[:<agentID>:<dir>]
            let parts = arg.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.first == "agents" { workspace.managingAgents = true }
            if parts.first == "terminal-settings" {
                // The Settings scene can't be opened from here; host the page directly.
                let w = NSWindow(contentViewController: NSHostingController(rootView: TerminalSettingsView()))
                w.title = "终端设置 (debug)"
                w.makeKeyAndOrderFront(nil)
            }
            if parts.first == "close" { workspace.managingAgents = false; workspace.resumeRequest = nil }
            if parts.first == "resume" {
                workspace.showResume(directory: parts.count > 2 ? parts[2] : nil, agentID: parts.count > 1 ? parts[1] : nil)
            }
        case "monitor":
            let d = UserDefaults.standard
            switch arg {
            case "show": d.set(true, forKey: MonitorSettings.visibleKey)
            case "hide": d.set(false, forKey: MonitorSettings.visibleKey)
            case "script":
                log(MonitorScript.build(kinds: Set(MonitorKind.allCases), interval: 1, system: true))
            case "":
                let m = PerformanceMonitor.shared, r = m.readings
                log("monitor running=\(m.isRunning) kinds=\(d.string(forKey: MonitorSettings.kindsKey) ?? "-")")
                if let c = r.cpu { log("  cpu \(Fmt.percent(c.total)) user=\(Fmt.percent(c.user)) sys=\(Fmt.percent(c.system)) cores=\(c.perCore.count)") }
                if let m = r.memory { log("  mem \(Fmt.bytes(m.used))/\(Fmt.bytes(m.total)) \(m.extras.map { "\($0.label)=\(Fmt.bytes($0.bytes))" }.joined(separator: " ")) swap=\(Fmt.bytes(m.swapUsed)) p=\(m.pressure)") }
                if let g = r.gpu { log("  gpu \(Fmt.percent(g.utilization)) mem=\(g.memoryInUse.map(Fmt.bytes) ?? "-")") }
                if let n = r.network { log("  net in=\(Fmt.rate(n.a)) out=\(Fmt.rate(n.b))") }
                if let k = r.disk { log("  disk r=\(k.rate.map { Fmt.rate($0.a) } ?? "-") w=\(k.rate.map { Fmt.rate($0.b) } ?? "-") free=\(k.free.map(Fmt.bytes) ?? "-")") }
                log("  target=\(m.target.host?.name ?? "local") error=\(m.remoteError ?? "-")")
                if let p = r.processes { log("  procs " + p.map { "\($0.name)=\(Fmt.cpu($0.cpu))" }.joined(separator: " ")) }
                if let k = r.docker {
                    log("  docker installed=\(k.installed) error=\(k.error ?? "-") \(k.runningCount)/\(k.containers.count)")
                    for c in k.containers { log("    \(c.name) \(c.state) cpu=\(c.cpu.map(Fmt.cpu) ?? "-") mem=\(c.memory ?? "-")") }
                }
                if let s = r.sessions {
                    log("  procs=\(s.totalProcesses) cpu=\(Fmt.cpu(s.totalCPU)) mem=\(Fmt.bytes(s.totalMemory)) app=\(Fmt.cpu(s.appCPU))/\(Fmt.bytes(s.appMemory))")
                    for row in s.rows { log("    \(row.name) \(Fmt.cpu(row.cpu)) \(Fmt.bytes(row.memory)) n=\(row.processes)") }
                }
                log("  history " + m.history.map { "\($0.key)=\($0.value.values.count)" }.sorted().joined(separator: " "))
            default: d.set(arg, forKey: MonitorSettings.kindsKey)
            }
        case "dockerlogs":
            // dockerlogs:<container> — same as 查看日志 in the 性能 panel's Docker card.
            let host = workspace.selected.flatMap(workspace.host(for:))
            workspace.openCommand(DockerControl.logsCommand(arg), title: "日志 · \(arg)", on: host)
        case "restart":
            workspace.selected.map { workspace.restartAgent($0) }
        case "dashboard":
            workspace.showingDashboard = arg.isEmpty ? !workspace.showingDashboard : arg == "show"
            log("dashboard showing=\(workspace.showingDashboard)")
            for (i, e) in workspace.agentEntries.enumerated() {
                log("   \(i + 1) [\(e.state.title)] \(e.title) agent=\(e.agent.kind.id) dir=\(e.directory)")
            }
        case "reply":
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let entries = workspace.agentEntries
            if parts.count == 2, let n = Int(parts[0]), entries.indices.contains(n - 1) {
                entries[n - 1].session.send(parts[1], to: entries[n - 1].pane)
            }
        case "open":
            let entries = workspace.agentEntries
            if let n = Int(arg), entries.indices.contains(n - 1) { workspace.show(entries[n - 1].pane, in: entries[n - 1].session) }
        case "agent":
            if let s = workspace.selected, let kind = workspace.catalog.agent(id: arg) { workspace.addAgent(kind, to: s) }
        case "hosts":
            for h in workspace.hosts { log("host \(h.name) | \(SSH.commandLine(for: h, sessionName: "agentdeck"))") }
            log("aliases \(workspace.sshConfigAliases.count)")
        case "connect":
            if let h = workspace.hosts.first(where: { $0.name == arg }) { workspace.connect(h) }
            else if workspace.sshConfigAliases.contains(arg) { workspace.connect(alias: arg) }
        case "edithost":
            workspace.editingHost = workspace.hosts.first(where: { $0.name == arg }) ?? RemoteHost(name: "", host: "")
        case "inspect":
            // Same path as the editor's 测试连接 button.
            if let h = workspace.hosts.first(where: { $0.name == arg }) {
                Task {
                    switch await SSH.inspect(h) {
                    case .success(let i):
                        log("inspect ok sys=\(i.system) tmux=\(i.hasTmux) zellij=\(i.hasZellij) sessions=\(i.sessions)")
                    case .failure(let e):
                        log("inspect failed: \(e.message)")
                    }
                }
            }
        case "screen":
            // Works even when the Mac is locked and screenshots fail.
            log("--- screen (\(workspace.selected?.displayName ?? "-")) ---\n" + (pane?.terminal.visibleText() ?? "") + "\n--- end ---")
        case "reconnect":
            workspace.selected.map(workspace.reconnect)
        case "find": pane?.showSearch(needle: arg)
        case "session": workspace.gotoSession(Int32(arg) ?? 1)
        default: NSLog("AgentDeckDebug: unknown command %@", cmd)
        }
    }
}
#endif
