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
        GhosttyRuntime.shared.onAppEvent = { [weak self] event in
            guard let self else { return }
            if case .newSession = event { self.newSessionLikeCurrent(nil) }
        }
    }

    // MARK: Lifecycle

    /// Re-open what was open last time (fresh processes, same agents, folders and splits).
    func restore() {
        let saved = store.load()
        for s in saved.sessions {
            let kind = AgentKind.builtIn.first { $0.id == s.kindID } ?? .shell
            let session = AgentSession(kind: kind, directory: s.directory, customName: s.customName,
                                       group: s.group, layout: s.layout)
            add(session, select: false)
        }
        selectedID = orderedSessions.first?.id
        persist()
    }

    @discardableResult
    func open(kind: AgentKind, directory: String, group: String? = nil, select: Bool = true) -> AgentSession {
        let session = AgentSession(kind: kind, directory: directory, group: group)
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

    func close(_ session: AgentSession) {
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

    private func newSessionLikeCurrent(_ from: AgentSession?) {
        let src = from ?? selected
        open(kind: src?.kind ?? .shell, directory: src?.directory ?? NSHomeDirectory(), group: src?.group)
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
            sessions: orderedSessions.map {
                .init(kindID: $0.kind.id, directory: $0.directory, customName: $0.customName,
                      group: $0.group, layout: $0.root.layout)
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workspace.json")
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
