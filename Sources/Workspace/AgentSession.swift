import AppKit
import Combine
import GhosttyKit

/// What an agent is doing right now (sidebar label).
enum AgentActivity: Equatable {
    /// No agent (plain shell / SSH).
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

extension AgentActivity {
    /// Which one a session with several agents shows: the one that needs you first.
    fileprivate var urgency: Int {
        switch self {
        case .waiting: return 5
        case .working: return 4
        case .done: return 3
        case .ready: return 2
        case .exited: return 1
        case .none: return 0
        }
    }

    var isBusy: Bool {
        switch self {
        case .working, .waiting: return true
        default: return false
        }
    }
}

/// How to start an agent in a pane: the line to type, and the conversation it opens.
struct AgentLaunch {
    let kind: AgentKind
    let line: String
    let conversationID: String?
}

/// An agent running in one pane. A session can hold several, one per pane;
/// each has its own state and its own conversation.
final class PaneAgent {
    let kind: AgentKind
    /// The agent's own conversation id, so the conversation can be resumed
    /// after a relaunch. Known up front for agents that accept one (Claude
    /// Code, Grok); discovered after launch for Codex.
    var conversationID: String?
    var activity: AgentActivity = .ready { didSet { since = Date() } }
    /// When it entered its current state.
    private(set) var since = Date()
    /// Not started by AgentDeck: you typed the agent's command into a shell
    /// pane. Tracked from generic signals, and forgotten when it exits.
    let adopted: Bool
    fileprivate var discovery: Task<Void, Never>?

    init(kind: AgentKind, conversationID: String?, adopted: Bool = false) {
        self.kind = kind
        self.conversationID = conversationID
        self.adopted = adopted
    }

    deinit { discovery?.cancel() }
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

    /// Recognises an agent's command line in a terminal title (see `adopt`).
    var detectAgent: (String) -> AgentKind? = { _ in nil }

    /// Panes that run an agent, in reading order.
    var agentPanes: [PaneView] { panes.filter { $0.agent != nil } }
    /// The session's agents at a glance: the most urgent state among them.
    var activity: AgentActivity {
        agentPanes.compactMap { $0.agent?.activity }.max { $0.urgency < $1.urgency } ?? .none
    }
    /// True when the only agent is the one the session was opened with, so
    /// the sidebar row can speak for it without listing agents.
    var hasOnlyPrimaryAgent: Bool {
        let agents = agentPanes
        return agents.count == 1 && agents[0].isPrimary && agents[0].agent?.kind.id == kind.id
    }

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
    var displayName: String {
        customName ?? remoteName ?? Self.agentAware(title, agent: focusedPane?.agent?.kind)
    }

    /// Shell integration titles a running command with its whole command line
    /// ("claude --session-id … --settings …"); show the agent's name instead.
    /// Titles the agent sets itself (e.g. the current task) pass through.
    private static func agentAware(_ title: String, agent: AgentKind?) -> String {
        guard let agent, let exe = agent.executable else { return title }
        let t = title.trimmingCharacters(in: .whitespaces)
        if t == exe || t.hasPrefix(exe + " ") || (agent.command.map { t.hasPrefix($0) } ?? false) { return agent.name }
        return title
    }

    /// What to call the agent in `pane`: the title it set (its current task), else its name.
    func agentLabel(for pane: PaneView) -> String {
        guard let agent = pane.agent else { return "" }
        guard let t = paneTitles[ObjectIdentifier(pane)] else { return agent.kind.name }
        return Self.agentAware(t, agent: agent.kind)
    }
    var folderName: String { remoteLabel ?? (directory as NSString).lastPathComponent }
    var isDisconnected: Bool { if case .disconnected = status { return true } else { return false } }
    var panes: [PaneView] { root.leaves }

    /// - Parameters:
    ///   - agent: the agent started in the first pane.
    ///   - restoreAgent: for a restored layout, the agent to start in another pane, if it had one.
    ///   - startCommand: a plain command typed into the first pane (no agent).
    ///   - connectCommand: for SSH sessions, the ssh line typed into the first pane.
    init(kind: AgentKind, directory: String, customName: String? = nil, group: String? = nil,
         layout: PaneNode.Layout? = nil, agent: AgentLaunch? = nil,
         restoreAgent: ((PaneNode.Layout) -> AgentLaunch?)? = nil, startCommand: String? = nil,
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

        // Agents run locally; an SSH session's first pane is the connection.
        let primaryAgent = remote == nil ? agent : nil
        let primary = Self.makePane(input: connectCommand ?? primaryAgent?.line ?? startCommand,
                                    directory: directory, isPrimary: true, agent: primaryAgent)
        if let layout {
            var usedPrimary = false
            root = PaneNode.restore(layout) { l in
                if l.isAgent == true && !usedPrimary {
                    usedPrimary = true
                    return primary
                }
                let launch = restoreAgent?(l)
                return Self.makePane(input: launch?.line, directory: l.directory ?? directory,
                                     isPrimary: false, agent: launch)
            }
            if !usedPrimary { root = PaneNode(pane: primary) }
        } else {
            root = PaneNode(pane: primary)
        }
        focusedPane = root.leaves.first { $0.isPrimary } ?? root.leaves.first
        panes.forEach(wire)
        panes.forEach(discoverCodexSession)
    }

    private static func makePane(input: String?, directory: String, isPrimary: Bool,
                                 agent: AgentLaunch?) -> PaneView {
        let term = TerminalSurfaceView(
            workingDirectory: directory,
            initialInput: input.map { $0 + "\n" },
            env: [:])
        return PaneView(terminal: term, isPrimary: isPrimary,
                        agent: agent.map { PaneAgent(kind: $0.kind, conversationID: $0.conversationID) })
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
            adopt(title: t, in: pane)

        case .pwd:
            if pane === focusedPane, let dir = pane.terminal.currentDirectory { directory = dir }

        case .attention(let message):
            setActivity(.waiting(message), in: pane)
            if isFrontmost() && NSApp.isActive && pane === focusedPane { return }
            status = .needsAttention(message)
            NSApp.requestUserAttention(.informationalRequest)

        case .commandFinished(let code):
            // In an SSH session the first pane's local command *is* ssh:
            // when it finishes, we've been disconnected.
            if remote != nil, pane.isPrimary {
                status = .disconnected(exitCode: code)
                return
            }
            // The agent's own command finished: the agent exited. One you
            // started by hand leaves a plain shell pane behind.
            if let agent = pane.agent {
                if agent.adopted {
                    objectWillChange.send()
                    pane.agent = nil
                } else {
                    setActivity(.exited, in: pane)
                }
            }
            if case .needsAttention = status { return }
            if pane === focusedPane { status = .finished(exitCode: code) }

        case .childExited:
            break

        case .userSubmitted:
            switch pane.agent?.activity {
            case .ready, .done, .waiting: setActivity(.working, in: pane)
            default: break
            }

        case .progress(let state):
            switch state {
            case GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_INDETERMINATE: setActivity(.working, in: pane)
            case GHOSTTY_PROGRESS_STATE_ERROR: setActivity(.waiting("出错了"), in: pane)
            case GHOSTTY_PROGRESS_STATE_REMOVE: if pane.agent?.activity == .working { setActivity(.done, in: pane) }
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

    // MARK: Agents

    /// Agent state lives on the pane; the session publishes its changes.
    private func setActivity(_ activity: AgentActivity, in pane: PaneView) {
        guard let agent = pane.agent, agent.activity != activity else { return }
        objectWillChange.send()
        agent.activity = activity
    }

    /// Shell integration titles a running command with its command line. If
    /// that is an agent's command typed into a plain shell pane, the pane has
    /// an agent now; if it is this pane's exited agent, it is back.
    private func adopt(title: String, in pane: PaneView) {
        guard remote == nil else { return }
        if let agent = pane.agent {
            guard agent.activity == .exited, let exe = agent.kind.executable,
                  title.split(separator: " ").first.map(String.init) == exe else { return }
            setActivity(.ready, in: pane)
        } else if let kind = detectAgent(title) {
            objectWillChange.send()
            pane.agent = PaneAgent(kind: kind, conversationID: nil, adopted: true)
            discoverCodexSession(pane)
        }
    }

    /// Does this session contain the pane with this AGENTDECK_PANE id?
    func pane(withID id: String) -> PaneView? {
        panes.first { $0.terminal.paneID == id }
    }

    /// An event from the hooks of the agent in `pane` (precise; see AgentHook).
    func handleHook(_ name: String, message: String?, in pane: PaneView) {
        guard pane.agent != nil else { return }
        switch name {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            setActivity(.working, in: pane)
        case "Notification":
            setActivity(.waiting(message), in: pane)
            if !(isFrontmost() && NSApp.isActive) {
                status = .needsAttention(message)
                NSApp.requestUserAttention(.informationalRequest)
            }
        case "Stop":
            setActivity(.done, in: pane)
            if !(isFrontmost() && NSApp.isActive) { status = .needsAttention("本轮完成") }
        default:
            break
        }
    }

    /// Type a (re)start line into a pane, e.g. after its agent exited.
    func run(_ launch: AgentLaunch, in pane: PaneView) {
        guard remote == nil, root.find(pane) != nil else { return }
        objectWillChange.send()
        pane.agent = PaneAgent(kind: launch.kind, conversationID: launch.conversationID)
        pane.terminal.typeText(launch.line + "\r")
        focus(pane)
        discoverCodexSession(pane)
    }

    /// Start an agent in a new pane split off `pane` (default: the focused one).
    func split(_ pane: PaneView? = nil, direction: ghostty_action_split_direction_e = GHOSTTY_SPLIT_DIRECTION_RIGHT,
               agent launch: AgentLaunch) {
        guard remote == nil else { return }
        split(pane, direction: direction, input: launch.line,
              agent: PaneAgent(kind: launch.kind, conversationID: launch.conversationID))
    }

    /// Answer the agent in `pane` without going to it: paste the text, then Return.
    func send(_ text: String, to pane: PaneView) {
        guard root.find(pane) != nil, !text.isEmpty else { return }
        pane.terminal.insertPasteText(text)
        // A TUI takes a moment to take in a paste; Return right behind it can get lost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak pane] in pane?.terminal.typeText("\r") }
        switch pane.agent?.activity {
        case .ready, .done, .waiting: setActivity(.working, in: pane)
        default: break
        }
    }

    /// Bring a pane forward, e.g. from the sidebar's agent list.
    func focus(_ pane: PaneView) {
        guard root.find(pane) != nil else { return }
        if zoomedPane != nil, zoomedPane !== pane {
            zoomedPane = pane
            layoutVersion += 1
        }
        setFocused(pane)
        DispatchQueue.main.async { pane.terminal.focus() }
    }

    /// Codex can't be given an id up front: watch its session folder for the
    /// conversation started in this pane after launch.
    private func discoverCodexSession(_ pane: PaneView) {
        guard let agent = pane.agent, agent.kind.history == .codex, agent.conversationID == nil else { return }
        agent.discovery?.cancel()
        let dir = pane.terminal.currentDirectory ?? directory, since = Date()
        agent.discovery = Task { [weak self, weak agent] in
            for _ in 0..<400 {   // ~20 minutes: Codex writes the file at the first prompt
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                // Two Codex agents in one folder must not claim the same conversation.
                let taken = await MainActor.run {
                    Set(self?.panes.compactMap { $0.agent?.conversationID } ?? [])
                }
                let found = await Task.detached {
                    ConversationHistory.findNewCodexSession(directory: dir, since: since, excluding: taken)
                }.value
                if let found {
                    await MainActor.run {
                        guard let agent else { return }
                        self?.objectWillChange.send()
                        agent.conversationID = found
                    }
                    return
                }
            }
        }
    }

    /// Re-run ssh in the first pane; tmux/zellij brings the remote state back.
    func reconnect(with command: String? = nil) {
        if let command { connectCommand = command }
        guard let cmd = connectCommand, let pane = panes.first(where: { $0.isPrimary }) else { return }
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
        split(pane, direction: direction, input: nil, agent: nil)
    }

    private func split(_ pane: PaneView?, direction: ghostty_action_split_direction_e,
                       input: String?, agent: PaneAgent?) {
        guard let pane = pane ?? focusedPane, let node = root.find(pane) else { return }
        let terminal = TerminalSurfaceView(splittingFrom: pane.terminal, initialInput: input.map { $0 + "\n" })
        let newPane = PaneView(terminal: terminal, isPrimary: false, agent: agent)
        wire(newPane)
        discoverCodexSession(newPane)
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
        let next = root.leaves.first { $0.isPrimary } ?? root.leaves.first
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
