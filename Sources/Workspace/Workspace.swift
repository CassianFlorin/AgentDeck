import AppKit
import Combine

/// All open sessions, the selection, and the bits we remember between launches.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedID: AgentSession.ID? {
        didSet { selected.map(clearAttention) }
    }
    @Published private(set) var recentDirectories: [String] = []

    private var cancellables: [AgentSession.ID: AnyCancellable] = [:]
    private let store = WorkspaceStore()

    var selected: AgentSession? { sessions.first { $0.id == selectedID } }

    var attentionCount: Int {
        sessions.filter { if case .needsAttention = $0.status { return true } else { return false } }.count
    }

    init() {
        let saved = store.load()
        recentDirectories = saved.recentDirectories
        GhosttyRuntime.shared.onNewSessionRequested = { [weak self] view in
            guard let self else { return }
            // cmd+t inside a session: same agent, same folder.
            let from = self.sessions.first { $0.terminal === view } ?? self.selected
            self.open(kind: from?.kind ?? .shell, directory: from?.directory ?? NSHomeDirectory())
        }
    }

    /// Re-open what was open last time (fresh processes, same agents and folders).
    func restore() {
        let saved = store.load()
        for s in saved.sessions {
            let kind = AgentKind.builtIn.first { $0.id == s.kindID } ?? .shell
            open(kind: kind, directory: s.directory, select: false, persist: false)
        }
        selectedID = sessions.first?.id
        persist()
    }

    @discardableResult
    func open(kind: AgentKind, directory: String, select: Bool = true, persist: Bool = true) -> AgentSession {
        let session = AgentSession(kind: kind, directory: directory)
        session.bind(
            isFrontmost: { [weak self, weak session] in self?.selectedID == session?.id },
            onClose: { [weak self, weak session] in
                guard let self, let session else { return }
                self.close(session)
            })
        // Re-publish child changes so the sidebar badge / dock badge update.
        cancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.updateDockBadge() }
        }
        sessions.append(session)
        remember(directory)
        if select { selectedID = session.id }
        if persist { self.persist() }
        return session
    }

    func close(_ session: AgentSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        cancellables[session.id] = nil
        session.terminal.removeFromSuperview()
        sessions.remove(at: idx)
        if selectedID == session.id {
            selectedID = sessions.indices.contains(idx) ? sessions[idx].id : sessions.last?.id
        }
        persist()
        updateDockBadge()
    }

    func move(from: IndexSet, to: Int) {
        sessions.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func selectNext(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        let i = sessions.firstIndex { $0.id == selectedID } ?? 0
        selectedID = sessions[(i + delta + sessions.count) % sessions.count].id
    }

    /// Jump to the oldest session that is waiting for you.
    func selectNextNeedingAttention() {
        if let s = sessions.first(where: { if case .needsAttention = $0.status { return true }; return false }) {
            selectedID = s.id
        }
    }

    private func clearAttention(_ s: AgentSession) {
        if case .needsAttention = s.status { s.status = .running }
    }

    private func remember(_ dir: String) {
        recentDirectories.removeAll { $0 == dir }
        recentDirectories.insert(dir, at: 0)
        recentDirectories = Array(recentDirectories.prefix(12))
    }

    func persist() {
        store.save(.init(
            sessions: sessions.map { .init(kindID: $0.kind.id, directory: $0.directory) },
            recentDirectories: recentDirectories))
    }

    private func updateDockBadge() {
        let n = attentionCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}

/// ~/Library/Application Support/AgentDeck/workspace.json
struct WorkspaceStore {
    struct Saved: Codable {
        struct Session: Codable { var kindID: String; var directory: String }
        var sessions: [Session] = []
        var recentDirectories: [String] = []
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
