import AppKit
import Combine
import GhosttyKit

/// What an agent session's agent is doing right now (sidebar label).
enum AgentActivity: Equatable {
    /// Not an agent session (plain shell / SSH).
    case none
    /// Agent launched, waiting for your first prompt.
    case ready
    /// Working on a prompt.
    case working
    /// Needs you: a permission prompt, a question, or a notification.
    case waiting(String?)
    /// Finished its turn.
    case done
    /// The agent process exited; you're back at the shell.
    case exited

    var label: String? {
        switch self {
        case .none: return nil
        case .ready: return "就绪"
        case .working: return "运行中"
        case .waiting: return "等你"
        case .done: return "本轮完成"
        case .exited: return "已退出"
        }
    }
}

enum SessionStatus: Equatable {
    /// Agent/shell is running and nothing asked for you.
    case running
    /// Bell or desktop notification while you were looking elsewhere —
    /// usually "agent finished" or "agent needs permission".
    case needsAttention(String?)
    /// The last shell command finished (from shell integration).
    case finished(exitCode: Int16)
    /// Remote session whose ssh exited; reconnecting re-attaches tmux/zellij.
    case disconnected(exitCode: Int16)
}

/// One sidebar entry: a split tree of terminal panes in a working folder.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let kind: AgentKind

    @Published var title: String
    @Published var directory: String
    @Published var status: SessionStatus = .running
    @Published var customName: String?
    @Published var group: String?
    /// Bumped whenever the split structure changes, so the host re-lays out.
    @Published private(set) var layoutVersion = 0
    @Published private(set) var zoomedPane: PaneView?
    @Published private(set) var focusedPane: PaneView?

    private(set) var root: PaneNode
    private var paneTitles: [ObjectIdentifier: String] = [:]

    /// Session-level events (new session, goto/move/close session…) for the workspace.
    var onWorkspaceEvent: ((AgentSession, TerminalEvent) -> Void)?

    /// For agent sessions: the agent's own conversation id, so the conversation
    /// can be resumed after a relaunch. Known up front for agents that accept
    /// one (Claude Code, Grok); discovered after launch for Codex.
    @Published var conversationID: String?
    @Published var activity: AgentActivity = .none
    private var discovery: Task<Void, Never>?

    /// Set for SSH sessions.
    let remote: RemoteRef?
    /// For SSH sessions: the server's name (title) and address (subtitle).
    @Published var remoteName: String?
    @Published var remoteLabel: String?
    /// The line typed to (re)connect.
    private(set) var connectCommand: String?
    /// Asks the workspace whether this session is the one on screen.
    var isFrontmost: () -> Bool = { false }

    /// SSH sessions are named after the server; the terminal title would just
    /// be the local shell's cwd whenever we're disconnected.
    var displayName: String { customName ?? remoteName ?? agentAwareTitle }

    /// Shell integration titles a running command with its whole command line
    /// ("claude --session-id … --settings …"); show the agent's name instead.
    /// Titles the agent sets itself (e.g. the current task) pass through.
    private var agentAwareTitle: String {
        guard kind.isAgent, let exe = kind.executable else { return title }
        let t = title.trimmingCharacters(in: .whitespaces)
        if t == exe || t.hasPrefix(exe + " ") || (kind.command.map { t.hasPrefix($0) } ?? false) { return kind.name }
        return title
    }
    var folderName: String { remoteLabel ?? (directory as NSString).lastPathComponent }
    var isDisconnected: Bool { if case .disconnected = status { return true } else { return false } }
    var panes: [PaneView] { root.leaves }

    /// - Parameters:
    ///   - startCommand: for agent sessions, the agent line typed into the first pane.
    ///   - connectCommand: for SSH sessions, the ssh line typed into the first pane.
    init(kind: AgentKind, directory: String, customName: String? = nil, group: String? = nil,
         layout: PaneNode.Layout? = nil, startCommand: String? = nil, conversationID: String? = nil,
         remote: RemoteRef? = nil, remoteName: String? = nil,
         remoteLabel: String? = nil, connectCommand: String? = nil) {
        self.kind = kind
        self.directory = directory
        self.title = remoteName ?? kind.name
        self.customName = customName
        self.group = group
        self.remote = remote
        self.remoteName = remoteName
        self.remoteLabel = remoteLabel
        self.connectCommand = connectCommand
        self.conversationID = conversationID
        if kind.isAgent && startCommand != nil { activity = .ready }

        let firstInput = connectCommand ?? startCommand
        let agent = Self.makePane(input: firstInput, directory: directory, isAgent: true)
        if let layout {
            var usedAgent = false
            root = PaneNode.restore(layout) { l in
                if l.isAgent == true && !usedAgent {
                    usedAgent = true
                    return agent
                }
                return Self.makePane(input: nil, directory: l.directory ?? directory, isAgent: false)
            }
            if !usedAgent { root = PaneNode(pane: agent) }
        } else {
            root = PaneNode(pane: agent)
        }
        focusedPane = root.leaves.first { $0.isAgentPane } ?? root.leaves.first
        panes.forEach(wire)
        if kind.history == .codex && conversationID == nil && startCommand != nil { discoverCodexSession() }
    }

    deinit { discovery?.cancel() }

    private static func makePane(input: String?, directory: String, isAgent: Bool) -> PaneView {
        let term = TerminalSurfaceView(
            workingDirectory: directory,
            initialInput: input.map { $0 + "\n" },
            env: [:])
        return PaneView(terminal: term, isAgentPane: isAgent)
    }

    private func wire(_ pane: PaneView) {
        pane.onEvent = { [weak self] pane, event in self?.handle(event, from: pane) }
    }

    // MARK: Events

    private func handle(_ event: TerminalEvent, from pane: PaneView) {
        switch event {
        case .title(let t):
            guard !t.isEmpty else { return }
            paneTitles[ObjectIdentifier(pane)] = t
            if pane === focusedPane { title = t }

        case .pwd:
            if pane === focusedPane, let dir = pane.terminal.currentDirectory { directory = dir }

        case .attention(let message):
            if isAgentPane(pane) { activity = .waiting(message) }
            if isFrontmost() && NSApp.isActive && pane === focusedPane { return }
            status = .needsAttention(message)
            NSApp.requestUserAttention(.informationalRequest)

        case .commandFinished(let code):
            // In an SSH session the first pane's local command *is* ssh:
            // when it finishes, we've been disconnected.
            if remote != nil, pane.isAgentPane {
                status = .disconnected(exitCode: code)
                return
            }
            // The agent's own command finished: the agent exited.
            if isAgentPane(pane) { activity = .exited }
            if case .needsAttention = status { return }
            if pane === focusedPane { status = .finished(exitCode: code) }

        case .childExited:
            break

        case .userSubmitted:
            guard isAgentPane(pane) else { return }
            switch activity {
            case .ready, .done, .waiting: activity = .working
            default: break
            }

        case .progress(let state):
            guard isAgentPane(pane) else { return }
            switch state {
            case GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_INDETERMINATE: activity = .working
            case GHOSTTY_PROGRESS_STATE_ERROR: activity = .waiting("出错了")
            case GHOSTTY_PROGRESS_STATE_REMOVE: if activity == .working { activity = .done }
            default: break
            }

        case .closeRequested(let processAlive):
            close(pane, confirm: processAlive)

        case .focused:
            setFocused(pane)

        case .newSplit(let dir):
            split(pane, direction: dir)
        case .gotoSplit(let dir):
            goto(from: pane, dir)
        case .resizeSplit(let dir, let amount):
            resize(pane, dir, amount: amount)
        case .equalizeSplits:
            root.equalize()
            layoutVersion += 1
        case .toggleZoom:
            guard panes.count > 1 else { return }
            zoomedPane = zoomedPane == nil ? pane : nil
            layoutVersion += 1
            DispatchQueue.main.async { pane.terminal.focus() }

        default:
            onWorkspaceEvent?(self, event)
        }
    }

    // MARK: Agent

    /// The first pane runs the agent; other panes are plain shells.
    private func isAgentPane(_ pane: PaneView) -> Bool {
        kind.isAgent && remote == nil && pane.isAgentPane && activity != .none
    }

    /// Does this session contain the pane with this AGENTDECK_PANE id?
    func pane(withID id: String) -> PaneView? {
        panes.first { $0.terminal.paneID == id }
    }

    /// An event from the agent's own hooks (precise; see AgentHook).
    func handleHook(_ name: String, message: String?) {
        switch name {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            activity = .working
        case "Notification":
            activity = .waiting(message)
            if !(isFrontmost() && NSApp.isActive) {
                status = .needsAttention(message)
                NSApp.requestUserAttention(.informationalRequest)
            }
        case "Stop":
            activity = .done
            if !(isFrontmost() && NSApp.isActive) { status = .needsAttention("本轮完成") }
        default:
            break
        }
    }

    /// Type a (re)start line into the agent pane, e.g. after the agent exited.
    func runInAgentPane(_ line: String, conversationID: String?) {
        guard let pane = panes.first(where: { $0.isAgentPane }) else { return }
        if let conversationID { self.conversationID = conversationID }
        activity = .ready
        pane.terminal.typeText(line + "\r")
        pane.terminal.focus()
        if kind.history == .codex && conversationID == nil { discoverCodexSession() }
    }

    /// Codex can't be given an id up front: watch its session folder for the
    /// conversation started here after launch.
    private func discoverCodexSession() {
        discovery?.cancel()
        let dir = directory, since = Date()
        discovery = Task { [weak self] in
            for _ in 0..<400 {   // ~20 minutes: Codex writes the file at the first prompt
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let found = await Task.detached { ConversationHistory.findNewCodexSession(directory: dir, since: since) }.value
                if let found {
                    await MainActor.run { self?.conversationID = found }
                    return
                }
            }
        }
    }

    /// Re-run ssh in the first pane; tmux/zellij brings the remote state back.
    func reconnect(with command: String? = nil) {
        if let command { connectCommand = command }
        guard let cmd = connectCommand, let pane = panes.first(where: { $0.isAgentPane }) else { return }
        status = .running
        pane.terminal.typeText(cmd + "\r")
        pane.terminal.focus()
    }

    private func setFocused(_ pane: PaneView) {
        focusedPane = pane
        if let t = paneTitles[ObjectIdentifier(pane)] { title = t }
        if let dir = pane.terminal.currentDirectory { directory = dir }
        if case .needsAttention = status { status = .running }
        updateDimming()
    }

    func updateDimming() {
        let multi = panes.count > 1 && zoomedPane == nil
        for p in panes { p.isDimmed = multi && p !== focusedPane }
    }

    // MARK: Splits

    func split(_ pane: PaneView? = nil, direction: ghostty_action_split_direction_e) {
        guard let pane = pane ?? focusedPane, let node = root.find(pane) else { return }
        let newPane = PaneView(terminal: TerminalSurfaceView(splittingFrom: pane.terminal), isAgentPane: false)
        wire(newPane)
        let horizontal = direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT
        let before = direction == GHOSTTY_SPLIT_DIRECTION_LEFT || direction == GHOSTTY_SPLIT_DIRECTION_UP
        node.split(with: newPane, horizontal: horizontal, before: before)
        zoomedPane = nil
        focusedPane = newPane
        layoutVersion += 1
        DispatchQueue.main.async { newPane.terminal.focus() }
    }

    private func close(_ pane: PaneView, confirm: Bool) {
        if confirm {
            let alert = NSAlert()
            alert.messageText = "关闭这个窗格？"
            alert.informativeText = "里面还有正在运行的进程，关闭会终止它。"
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // A close for a pane we no longer hold (e.g. a duplicate notification)
        // must never take the whole session down with it.
        guard let node = root.find(pane) else { return }
        if node === root {
            // Last pane: the session goes away.
            onWorkspaceEvent?(self, .closeSession)
            return
        }
        guard root.removeLeaf(node) else { return }
        paneTitles[ObjectIdentifier(pane)] = nil
        pane.removeFromSuperview()
        if zoomedPane === pane { zoomedPane = nil }
        let next = root.leaves.first { $0.isAgentPane } ?? root.leaves.first
        focusedPane = next
        layoutVersion += 1
        if let next { DispatchQueue.main.async { next.terminal.focus() } }
    }

    private func goto(from pane: PaneView, _ dir: ghostty_action_goto_split_e) {
        let all = panes
        guard all.count > 1, let i = all.firstIndex(where: { $0 === pane }) else { return }
        var target: PaneView?
        switch dir {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: target = all[(i - 1 + all.count) % all.count]
        case GHOSTTY_GOTO_SPLIT_NEXT: target = all[(i + 1) % all.count]
        default: target = neighbor(of: pane, dir, in: all)
        }
        guard let target else { return }
        if zoomedPane != nil { zoomedPane = target; layoutVersion += 1 }
        target.terminal.focus()
    }

    /// Nearest pane in a direction, by on-screen geometry.
    private func neighbor(of pane: PaneView, _ dir: ghostty_action_goto_split_e, in all: [PaneView]) -> PaneView? {
        func rect(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
        let r = rect(pane)
        let candidates = all.filter { $0 !== pane }.compactMap { p -> (PaneView, CGFloat)? in
            let o = rect(p)
            switch dir {
            case GHOSTTY_GOTO_SPLIT_LEFT:
                guard o.maxX <= r.minX + 1, o.maxY > r.minY, o.minY < r.maxY else { return nil }
                return (p, r.minX - o.maxX)
            case GHOSTTY_GOTO_SPLIT_RIGHT:
                guard o.minX >= r.maxX - 1, o.maxY > r.minY, o.minY < r.maxY else { return nil }
                return (p, o.minX - r.maxX)
            case GHOSTTY_GOTO_SPLIT_UP: // window coords are bottom-up
                guard o.minY >= r.maxY - 1, o.maxX > r.minX, o.minX < r.maxX else { return nil }
                return (p, o.minY - r.maxY)
            case GHOSTTY_GOTO_SPLIT_DOWN:
                guard o.maxY <= r.minY + 1, o.maxX > r.minX, o.minX < r.maxX else { return nil }
                return (p, r.minY - o.maxY)
            default: return nil
            }
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    private func resize(_ pane: PaneView, _ dir: ghostty_action_resize_split_direction_e, amount: UInt16) {
        let wantHorizontal = dir == GHOSTTY_RESIZE_SPLIT_LEFT || dir == GHOSTTY_RESIZE_SPLIT_RIGHT
        var node = root.find(pane)?.parent
        while let n = node, n.horizontal != wantHorizontal { node = n.parent }
        guard let branch = node, let view = branch.splitView else { return }
        let positive = dir == GHOSTTY_RESIZE_SPLIT_RIGHT || dir == GHOSTTY_RESIZE_SPLIT_DOWN
        view.nudge(by: CGFloat(amount) * (positive ? 1 : -1))
    }
}
