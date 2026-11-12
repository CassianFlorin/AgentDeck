import AppKit
import Combine

/// All open sessions, the selection, groups, and what we remember between launches.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedID: AgentSession.ID? {
        didSet { selected.map(clearAttention) }
    }
    @Published private(set) var recentDirectories: [String] = []
    /// Group names in display order. Sessions with `group == nil` show first.
    @Published private(set) var groups: [String] = []
    @Published var collapsedGroups: Set<String> = []
    /// Set to show the rename sheet for a session.
    @Published var renaming: AgentSession?

    // MARK: Remote hosts
    @Published private(set) var hosts: [RemoteHost] = []
    /// Aliases from ~/.ssh/config not yet saved as hosts.
    @Published private(set) var sshConfigAliases: [String] = []
    /// ~/.ssh/config aliases the user removed from the sidebar (config file untouched).
    @Published private(set) var hiddenSSHConfigAliases: [String] = []
    /// Set to open the host editor (new or existing host).
    @Published var editingHost: RemoteHost?
    /// Set to open the remote-session picker for a host.
    @Published var pickingSessionFor: RemoteHost?
    private let hostStore = HostStore()

    // MARK: Agents
    let catalog = AgentCatalog()
    /// Set to open the "resume a conversation" sheet.
    @Published var resumeRequest: ResumeRequest?
    @Published var managingAgents = false
    private var hookObserver: NSObjectProtocol?

    private var cancellables: [AgentSession.ID: AnyCancellable] = [:]
    private let store = WorkspaceStore()

    var selected: AgentSession? { sessions.first { $0.id == selectedID } }

    /// Sessions in sidebar order: ungrouped first, then each group.
    var orderedSessions: [AgentSession] {
        sessions.filter { $0.group == nil } + groups.flatMap { g in sessions.filter { $0.group == g } }
    }

    var attentionCount: Int {
        sessions.filter { if case .needsAttention = $0.status { return true } else { return false } }.count
    }

    init() {
        let saved = store.load()
        recentDirectories = saved.recentDirectories
        groups = saved.groups
        hosts = hostStore.load()
        reloadSSHConfig()
        GhosttyRuntime.shared.onAppEvent = { [weak self] event in
            guard let self else { return }
            if case .newSession = event { self.newSessionLikeCurrent(nil) }
        }
        // Agent hooks (see AgentHook) report from separate processes.
        hookObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentHook.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = AgentHook.parse(note.object) else { return }
            MainActor.assumeIsolated {
                self?.sessions.first { $0.pane(withID: event.paneID) != nil }?
                    .handleHook(event.name, message: event.message)
            }
        }
    }

    // MARK: Lifecycle

    /// Re-open what was open last time (fresh processes, same agents, folders and splits).
    func restore() {
        let saved = store.load()
        for s in saved.sessions {
            if let ref = s.remote {
                // Reconnect and re-attach: this is what "restore" means for servers.
                if let host = hosts.first(where: { $0.id == ref.hostID }) {
                    let session = makeRemoteSession(host, sessionName: ref.sessionName, customName: s.customName,
                                                    group: s.group, layout: s.layout)
                    add(session, select: false)
                }
                continue
            }
            let kind = catalog.agent(id: s.kindID) ?? .shell
            // Agents come back *in the same conversation*.
            let (line, conversationID): (String?, String?)
            if let id = s.conversationID, let resume = kind.resumeLine(id) {
                (line, conversationID) = (resume, id)
            } else if s.conversationID == nil, let cont = kind.continueLine(), s.hadAgent == true {
                (line, conversationID) = (cont, nil)
            } else {
                (line, conversationID) = kind.newConversation()
            }
            let session = AgentSession(kind: kind, directory: s.directory, customName: s.customName,
                                       group: s.group, layout: s.layout,
                                       startCommand: line.map { withHooks($0, kind) },
                                       conversationID: conversationID)
            add(session, select: false)
        }
        // Nothing to restore (first launch, or everything was closed): start in a shell at ~.
        if sessions.isEmpty {
            open(kind: .shell, directory: NSHomeDirectory(), select: false)
        }
        selectedID = orderedSessions.first?.id
        persist()
    }

    /// Open a session. With `resume`, the agent continues that conversation.
    @discardableResult
    func open(kind: AgentKind, directory: String, group: String? = nil, select: Bool = true,
              resume: Conversation? = nil) -> AgentSession {
        let (line, conversationID): (String?, String?)
        if let resume, let r = kind.resumeLine(resume.id) {
            (line, conversationID) = (r, resume.id)
        } else {
            (line, conversationID) = kind.newConversation()
        }
        let session = AgentSession(kind: kind, directory: directory, group: group,
                                   startCommand: line.map { withHooks($0, kind) },
                                   conversationID: conversationID)
        if let resume { session.customName = resume.title }
        add(session, select: select)
        remember(directory)
        persist()
        return session
    }

    private func add(_ session: AgentSession, select: Bool) {
        session.isFrontmost = { [weak self, weak session] in self?.selectedID == session?.id }
        session.onWorkspaceEvent = { [weak self] session, event in self?.handle(event, from: session) }
        // Re-publish child changes so sidebar and Dock badge update.
        cancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                self?.updateDockBadge()
                self?.schedulePersist()
            }
        }
        if let g = session.group, !groups.contains(g) { groups.append(g) }
        sessions.append(session)
        if select { selectedID = session.id }
    }

    /// Sessions opened for a one-off command (container logs / shell from the
    /// 性能 panel). They are not restored on relaunch.
    private var ephemeral: Set<UUID> = []

    /// Open a session that runs `command`, locally or on `host`. With a host
    /// the session counts as that server's, so the 性能 panel stays on it.
    @discardableResult
    func openCommand(_ command: String, title: String, on host: RemoteHost?) -> AgentSession {
        let session: AgentSession
        if let host {
            session = AgentSession(kind: .ssh, directory: NSHomeDirectory(), customName: title,
                                   group: selected?.group,
                                   remote: RemoteRef(hostID: host.id, sessionName: nil),
                                   remoteName: host.name, remoteLabel: host.address,
                                   connectCommand: SSH.commandLine(for: host, remoteCommand: command))
        } else {
            session = AgentSession(kind: .shell, directory: NSHomeDirectory(), customName: title,
                                   group: selected?.group, startCommand: command)
        }
        ephemeral.insert(session.id)
        add(session, select: true)
        return session
    }

    func close(_ session: AgentSession) {
        ephemeral.remove(session.id)
        let order = orderedSessions
        guard let idx = order.firstIndex(where: { $0.id == session.id }) else { return }
        cancellables[session.id] = nil
        session.panes.forEach { $0.removeFromSuperview() }
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id {
            let rest = orderedSessions
            selectedID = rest.isEmpty ? nil : rest[min(idx, rest.count - 1)].id
        }
        persist()
        updateDockBadge()
    }

    // MARK: Agents

    private func withHooks(_ line: String, _ kind: AgentKind) -> String {
        let extra = AgentHook.launchArguments(for: kind)
        return extra.isEmpty ? line : "\(line) \(extra)"
    }

    /// After the agent exited: start it again, back in the same conversation if we know it.
    func restartAgent(_ session: AgentSession) {
        let kind = session.kind
        guard kind.isAgent else { return }
        if let id = session.conversationID, let line = kind.resumeLine(id) {
            session.runInAgentPane(withHooks(line, kind), conversationID: id)
        } else {
            let (line, id) = kind.newConversation()
            if let line { session.runInAgentPane(withHooks(line, kind), conversationID: id) }
        }
    }

    func showResume(directory: String? = nil, agentID: String? = nil) {
        let dir = directory ?? selected.flatMap { $0.remote == nil ? $0.directory : nil }
            ?? recentDirectories.first ?? NSHomeDirectory()
        let agent = agentID ?? selected.flatMap { $0.kind.history != .none ? $0.kind.id : nil }
            ?? catalog.visible.first { $0.history != .none }?.id ?? "claude"
        resumeRequest = ResumeRequest(directory: dir, agentID: agent)
    }

    private func newSessionLikeCurrent(_ from: AgentSession?) {
        let src = from ?? selected
        if let ref = src?.remote, let host = hosts.first(where: { $0.id == ref.hostID }) {
            connect(host)   // cmd+t in an SSH session: another session on the same server
            return
        }
        open(kind: src?.kind ?? .shell, directory: src?.directory ?? NSHomeDirectory(), group: src?.group)
    }

    // MARK: Remote

    func reloadSSHConfig() {
        let saved = Set(hosts.map(\.host))
        let hidden = hostStore.hiddenAliases()
        let all = SSHConfigReader.aliases().filter { !saved.contains($0) }
        sshConfigAliases = all.filter { !hidden.contains($0) }
        hiddenSSHConfigAliases = all.filter { hidden.contains($0) }
    }

    /// Remove an ~/.ssh/config alias from AgentDeck's list. Only remembered
    /// here; ~/.ssh/config itself is never touched.
    func hideSSHConfigAlias(_ alias: String) {
        var hidden = hostStore.hiddenAliases()
        hidden.insert(alias)
        hostStore.saveHiddenAliases(hidden)
        reloadSSHConfig()
    }

    /// Show every hidden ~/.ssh/config alias again.
    func unhideSSHConfigAliases() {
        hostStore.saveHiddenAliases([])
        reloadSSHConfig()
    }

    func saveHost(_ host: RemoteHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        hostStore.save(hosts)
        reloadSSHConfig()
        // Keep labels of open sessions in sync.
        for s in sessions where s.remote?.hostID == host.id {
            s.remoteName = host.name
            s.remoteLabel = label(for: host, sessionName: s.remote?.sessionName)
        }
    }

    func deleteHost(_ host: RemoteHost) {
        hosts.removeAll { $0.id == host.id }
        HostKeychain.deletePassword(for: host.id)
        hostStore.save(hosts)
        reloadSSHConfig()
    }

    func host(for session: AgentSession) -> RemoteHost? {
        session.remote.flatMap { ref in hosts.first { $0.id == ref.hostID } }
    }

    /// Sidebar subtitle: address, plus the tmux/zellij session if it isn't the default.
    private func label(for host: RemoteHost, sessionName: String?) -> String {
        guard let s = sessionName, s != "agentdeck" else { return host.address }
        return "\(host.address) · \(s)"
    }

    /// A tmux/zellij name not used by another open session on this host.
    private func freshSessionName(for host: RemoteHost) -> String {
        let base = SSH.sessionName("agentdeck")
        let used = Set(sessions.compactMap { $0.remote?.hostID == host.id ? $0.remote?.sessionName : nil })
        if !used.contains(base) { return base }
        var n = 2
        while used.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func makeRemoteSession(_ host: RemoteHost, sessionName: String?, customName: String? = nil,
                                   group: String? = nil, layout: PaneNode.Layout? = nil) -> AgentSession {
        let name = host.persistence.usesSessionName ? (sessionName ?? freshSessionName(for: host)) : nil
        return AgentSession(kind: .ssh, directory: NSHomeDirectory(), customName: customName,
                            group: group ?? host.group, layout: layout,
                            remote: RemoteRef(hostID: host.id, sessionName: name),
                            remoteName: host.name,
                            remoteLabel: label(for: host, sessionName: name),
                            connectCommand: SSH.commandLine(for: host, sessionName: name))
    }

    /// Open a session on a server. `sessionName` attaches to an existing
    /// tmux/zellij session; nil creates a fresh one.
    @discardableResult
    func connect(_ host: RemoteHost, sessionName: String? = nil) -> AgentSession {
        // Already attached to that remote session? Just go there.
        if let sessionName, let open = sessions.first(where: {
            $0.remote?.hostID == host.id && $0.remote?.sessionName == sessionName
        }) {
            selectedID = open.id
            if open.isDisconnected { reconnect(open) }
            return open
        }
        let session = makeRemoteSession(host, sessionName: sessionName)
        add(session, select: true)
        persist()
        return session
    }

    /// Connecting an ~/.ssh/config alias saves it as a server, so the session
    /// can be reconnected and restored later.
    @discardableResult
    func connect(alias: String) -> AgentSession {
        let host = hosts.first { $0.host == alias } ?? {
            let h = RemoteHost.fromSSHConfig(alias: alias)
            saveHost(h)
            return h
        }()
        return connect(host)
    }

    /// Reconnect with the host's *current* settings (they may have been edited).
    func reconnect(_ session: AgentSession) {
        guard let host = host(for: session) else { return }
        session.reconnect(with: SSH.commandLine(for: host, sessionName: session.remote?.sessionName))
    }

    // MARK: Events bubbled up from sessions

    private func handle(_ event: TerminalEvent, from session: AgentSession) {
        switch event {
        case .newSession: newSessionLikeCurrent(session)
        case .closeSession: close(session)
        case .renameSession: renaming = session
        case .gotoSession(let n): gotoSession(n)
        case .moveSession(let amount): moveWithinGroup(session, by: amount)
        default: break
        }
    }

    /// Ghostty's goto_tab: 1-based index, or -1 prev / -2 next / -3 last.
    func gotoSession(_ n: Int32) {
        let order = orderedSessions
        guard !order.isEmpty else { return }
        let cur = order.firstIndex { $0.id == selectedID } ?? 0
        let target: Int
        switch n {
        case -1: target = (cur - 1 + order.count) % order.count
        case -2: target = (cur + 1) % order.count
        case -3: target = order.count - 1
        default:
            guard n >= 1 else { return }
            target = min(Int(n) - 1, order.count - 1)
        }
        selectedID = order[target].id
    }

    func selectNext(_ delta: Int) { gotoSession(delta > 0 ? -2 : -1) }

    /// Jump to the oldest session that is waiting for you.
    func selectNextNeedingAttention() {
        if let s = orderedSessions.first(where: { if case .needsAttention = $0.status { return true }; return false }) {
            selectedID = s.id
        }
    }

    private func clearAttention(_ s: AgentSession) {
        if case .needsAttention = s.status { s.status = .running }
    }

    // MARK: Rename & groups

    func rename(_ session: AgentSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    func sessions(in group: String?) -> [AgentSession] {
        sessions.filter { $0.group == group }
    }

    func move(_ session: AgentSession, toGroup group: String?) {
        if let group, !groups.contains(group) { groups.append(group) }
        session.group = group
        pruneEmptyGroups()
        persist()
    }

    func renameGroup(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        if groups.contains(name) {
            groups.removeAll { $0 == old }          // merge into existing
        } else if let i = groups.firstIndex(of: old) {
            groups[i] = name
        }
        for s in sessions where s.group == old { s.group = name }
        if collapsedGroups.remove(old) != nil { collapsedGroups.insert(name) }
        persist()
    }

    /// Dissolve a group; its sessions become ungrouped (nothing is closed).
    func ungroup(_ group: String) {
        for s in sessions where s.group == group { s.group = nil }
        groups.removeAll { $0 == group }
        persist()
    }

    private func pruneEmptyGroups() {
        groups.removeAll { g in !sessions.contains { $0.group == g } }
    }

    /// Reorder within one sidebar section (indices are section-relative).
    func move(inGroup group: String?, from: IndexSet, to: Int) {
        var section = sessions(in: group)
        section.move(fromOffsets: from, toOffset: to)
        var it = section.makeIterator()
        sessions = sessions.map { $0.group == group ? it.next()! : $0 }
        persist()
    }

    private func moveWithinGroup(_ session: AgentSession, by amount: Int) {
        let section = sessions(in: session.group)
        guard let i = section.firstIndex(where: { $0.id == session.id }) else { return }
        let j = min(max(i + amount, 0), section.count - 1)
        guard i != j else { return }
        move(inGroup: session.group, from: IndexSet(integer: i), to: j > i ? j + 1 : j)
    }

    // MARK: Persistence

    private func remember(_ dir: String) {
        recentDirectories.removeAll { $0 == dir }
        recentDirectories.insert(dir, at: 0)
        recentDirectories = Array(recentDirectories.prefix(12))
    }

    func persist() {
        store.save(.init(
            sessions: orderedSessions.filter { !ephemeral.contains($0.id) }.map {
                .init(kindID: $0.kind.id, directory: $0.directory, customName: $0.customName,
                      group: $0.group, layout: $0.root.layout, remote: $0.remote,
                      conversationID: $0.conversationID,
                      hadAgent: $0.kind.isAgent && $0.activity != .none ? true : nil)
            },
            recentDirectories: recentDirectories,
            groups: groups))
    }

    private var persistWork: DispatchWorkItem?

    /// Coalesce bursts of changes (typing `cd` a lot, dragging a divider).
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func updateDockBadge() {
        let n = attentionCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}

/// ~/Library/Application Support/AgentDeck/workspace.json
struct WorkspaceStore {
    struct Saved: Codable {
        struct Session: Codable {
            var kindID: String
            var directory: String
            var customName: String?
            var group: String?
            var layout: PaneNode.Layout?
            var remote: RemoteRef?
            /// The agent's conversation id, to resume it on relaunch.
            var conversationID: String?
            /// An agent was running but we never learned its conversation id
            /// (e.g. Codex before the first prompt): continue the latest one.
            var hadAgent: Bool?
        }
        var sessions: [Session] = []
        var recentDirectories: [String] = []
        var groups: [String] = []

        init(sessions: [Session] = [], recentDirectories: [String] = [], groups: [String] = []) {
            self.sessions = sessions
            self.recentDirectories = recentDirectories
            self.groups = groups
        }

        // Tolerate files written by older versions (missing keys).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            recentDirectories = try c.decodeIfPresent([String].self, forKey: .recentDirectories) ?? []
            groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        }
    }

    private var url: URL {
        AppPaths.support.appendingPathComponent("workspace.json")
    }

    func load() -> Saved {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    func save(_ saved: Saved) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(saved) { try? data.write(to: url, options: .atomic) }
    }
}

/// What the "resume a conversation" sheet should show first.
struct ResumeRequest: Identifiable, Equatable {
    let id = UUID()
    var directory: String
    var agentID: String
}
