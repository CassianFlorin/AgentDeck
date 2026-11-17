import Foundation
import Combine
import AppKit

/// The agents AgentDeck knows: built-in presets plus your own, with your
/// edits layered on top. Stored in agents.json next to workspace.json.
@MainActor
final class AgentCatalog: ObservableObject {
    @Published private(set) var agents: [AgentKind] = []
    /// executable name → resolved path (nil = not found on your login shell's PATH).
    @Published private(set) var installed: [String: String?] = [:]
    @Published private(set) var detecting = false

    private var url: URL { AppPaths.support.appendingPathComponent("agents.json") }
    private var lastDetection = Date.distantPast
    private var activation: AnyCancellable?
    /// Asked to detect again while a lookup was running (e.g. an agent was saved).
    private var detectAgain = false

    init() {
        load()
        detectInstalled()
        // Installed a CLI in another window? Pick it up when you come back,
        // without spawning a login shell on every app switch.
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, Date().timeIntervalSince(self.lastDetection) > 60 else { return }
                self.detectInstalled()
            }
    }

    /// Not hidden by you (installed or not): what 管理 Agent lists first.
    var visible: [AgentKind] { agents.filter { !$0.hidden } }

    /// Agents for "new session" menus: not hidden, and found on your PATH.
    /// While detection hasn't finished (or couldn't run) everything counts as
    /// available, so a slow shell never empties the menus.
    var available: [AgentKind] { visible.filter { isInstalled($0) != false } }

    func agent(id: String) -> AgentKind? { agents.first { $0.id == id } }

    /// The agent a command line starts, judged by its first word ("codex resume …" → Codex).
    func agent(runBy commandLine: String) -> AgentKind? {
        guard let word = commandLine.split(separator: " ").first.map(String.init) else { return nil }
        return agents.first { $0.isAgent && $0.executable == word }
    }

    /// nil while unknown, true/false once detection finished. Shell is always available.
    func isInstalled(_ agent: AgentKind) -> Bool? {
        guard let exe = agent.executable else { return true }
        guard let entry = installed[exe] else { return nil }
        return entry != nil
    }

    func path(of agent: AgentKind) -> String? {
        agent.executable.flatMap { installed[$0] ?? nil }
    }

    // MARK: Editing

    func save(_ agent: AgentKind) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent } else { agents.append(agent) }
        persist()
        detectInstalled()
    }

    /// Custom agents are removed; built-ins go back to their defaults.
    func remove(_ agent: AgentKind) {
        if let builtIn = AgentKind.builtIns.first(where: { $0.id == agent.id }),
           let i = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[i] = builtIn
        } else {
            agents.removeAll { $0.id == agent.id }
        }
        persist()
    }

    func newCustomAgent() -> AgentKind {
        var n = 1
        while agents.contains(where: { $0.id == "custom-\(n)" }) { n += 1 }
        return AgentKind(id: "custom-\(n)", name: "", symbol: "cpu", command: "")
    }

    // MARK: Persistence

    private func load() {
        var list = AgentKind.builtIns
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([AgentKind].self, from: data) {
            for var a in saved {
                if let i = list.firstIndex(where: { $0.id == a.id }) {
                    a.isBuiltIn = true
                    // Saved by a version that knew fewer ways to get status.
                    if a.hooks == .none { a.hooks = list[i].hooks }
                    if a.promptArgs.isEmpty { a.promptArgs = list[i].promptArgs }
                    // Not editable, so always the current preset's.
                    a.installHint = list[i].installHint
                    list[i] = a
                } else {
                    a.isBuiltIn = false
                    list.append(a)
                }
            }
        }
        agents = list
    }

    private func persist() {
        // Only what differs from the defaults is worth saving, but saving the
        // whole list keeps the file readable and ordering stable.
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(agents) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Detection

    /// Ask the user's login shell where each agent's executable lives —
    /// PATH set up in .zshrc / .bash_profile (nvm, ~/.local/bin…) included.
    func detectInstalled() {
        let names = Array(Set(agents.compactMap(\.executable))).sorted()
        guard !names.isEmpty else { return }
        if detecting { detectAgain = true; return }
        detecting = true
        lastDetection = Date()
        Task.detached {
            let result = Self.lookup(names)
            await MainActor.run {
                // nil = the shell couldn't answer; keep what we knew rather than
                // marking every agent as missing.
                if let result { self.installed = result }
                self.detecting = false
                if self.detectAgain {
                    self.detectAgain = false
                    self.detectInstalled()
                }
            }
        }
    }

    nonisolated private static func lookup(_ names: [String]) -> [String: String?]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = names.map { n in
            "printf '@@%s\\t%s\\n' \(SSH.quote(n)) \"$(command -v \(SSH.quote(n)) 2>/dev/null)\""
        }.joined(separator: "; ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", script]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var result: [String: String?] = [:]
        for n in names { result[n] = .some(nil) }
        do { try p.run() } catch { return nil }

        // Interactive shells can hang on odd rc files; don't wait forever.
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }

        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("@@") {
            let parts = line.dropFirst(2).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            result[String(parts[0])] = path.isEmpty ? .some(nil) : .some(path)
        }
        return result
    }
}
