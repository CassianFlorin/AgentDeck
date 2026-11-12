import Foundation
import Combine

/// The agents AgentDeck knows: built-in presets plus your own, with your
/// edits layered on top. Stored in agents.json next to workspace.json.
@MainActor
final class AgentCatalog: ObservableObject {
    @Published private(set) var agents: [AgentKind] = []
    /// executable name → resolved path (nil = not found on your login shell's PATH).
    @Published private(set) var installed: [String: String?] = [:]
    @Published private(set) var detecting = false

    private var url: URL { AppPaths.support.appendingPathComponent("agents.json") }

    init() {
        load()
        detectInstalled()
    }

    /// Agents for "new session" menus.
    var visible: [AgentKind] { agents.filter { !$0.hidden } }

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
        detecting = true
        Task.detached {
            let result = Self.lookup(names)
            await MainActor.run {
                self.installed = result
                self.detecting = false
            }
        }
    }

    nonisolated private static func lookup(_ names: [String]) -> [String: String?] {
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
        do { try p.run() } catch { return result }

        // Interactive shells can hang on odd rc files; don't wait forever.
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }

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
