import AppKit
import Combine
import GhosttyKit

/// What runs in a session. The command is *typed* into a login shell, so
/// anything on your PATH works and you get a shell back when it exits.
struct AgentKind: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    /// nil = plain shell.
    var command: String?

    static let claude = AgentKind(id: "claude", name: "Claude Code", symbol: "sparkle", command: "claude")
    static let codex = AgentKind(id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", command: "codex")
    static let shell = AgentKind(id: "shell", name: "Shell", symbol: "terminal", command: nil)

    static let builtIn: [AgentKind] = [.claude, .codex, .shell]
}

enum SessionStatus: Equatable {
    /// Agent/shell is running and nothing asked for you.
    case running
    /// Bell or desktop notification while you were looking elsewhere —
    /// usually "agent finished" or "agent needs permission".
    case needsAttention(String?)
    /// The last shell command finished (from shell integration).
    case finished(exitCode: Int16)
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
    /// Asks the workspace whether this session is the one on screen.
    var isFrontmost: () -> Bool = { false }

    var displayName: String { customName ?? title }
    var folderName: String { (directory as NSString).lastPathComponent }
    var panes: [PaneView] { root.leaves }

    init(kind: AgentKind, directory: String, customName: String? = nil, group: String? = nil,
         layout: PaneNode.Layout? = nil) {
        self.kind = kind
        self.directory = directory
        self.title = kind.name
        self.customName = customName
        self.group = group

        // Placeholder so `self` is fully initialised before panes capture it.
        let agent = Self.makePane(kind: kind, directory: directory, isAgent: true)
        if let layout {
            var usedAgent = false
            root = PaneNode.restore(layout) { l in
                if l.isAgent == true && !usedAgent {
                    usedAgent = true
                    return agent
                }
                return Self.makePane(kind: .shell, directory: l.directory ?? directory, isAgent: false)
            }
            if !usedAgent { root = PaneNode(pane: agent) }
        } else {
            root = PaneNode(pane: agent)
        }
        focusedPane = root.leaves.first { $0.isAgentPane } ?? root.leaves.first
        panes.forEach(wire)
    }

    private static func makePane(kind: AgentKind, directory: String, isAgent: Bool) -> PaneView {
        let term = TerminalSurfaceView(
            workingDirectory: directory,
            initialInput: isAgent ? kind.command.map { $0 + "\n" } : nil,
            env: ["AGENTDECK": "1"])
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
            if isFrontmost() && NSApp.isActive && pane === focusedPane { return }
            status = .needsAttention(message)
            NSApp.requestUserAttention(.informationalRequest)

        case .commandFinished(let code):
            if case .needsAttention = status { return }
            if pane === focusedPane { status = .finished(exitCode: code) }

        case .childExited:
            break

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
