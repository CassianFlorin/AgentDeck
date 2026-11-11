import AppKit
import Combine

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
    /// The shell itself exited.
    case exited(Int32)
}

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let kind: AgentKind
    let createdAt = Date()

    @Published var title: String
    @Published var directory: String
    @Published var status: SessionStatus = .running
    @Published var customName: String?

    let terminal: TerminalSurfaceView

    var displayName: String { customName ?? title }
    var folderName: String { (directory as NSString).lastPathComponent }

    init(kind: AgentKind, directory: String) {
        self.kind = kind
        self.directory = directory
        self.title = kind.name
        self.terminal = TerminalSurfaceView(
            workingDirectory: directory,
            initialInput: kind.command.map { $0 + "\n" },
            env: ["AGENTDECK_SESSION_ID": UUID().uuidString])
    }

    /// Hook terminal events up. `isFrontmost` tells us if the user is looking
    /// at this session right now (no badge needed then).
    func bind(isFrontmost: @escaping () -> Bool, onClose: @escaping () -> Void) {
        terminal.onTitleChange = { [weak self] t in
            guard let self, !t.isEmpty else { return }
            self.title = t
        }
        terminal.onPwdChange = { [weak self] pwd in
            // OSC 7 gives a file:// URL; plain paths also show up.
            if let url = URL(string: pwd), url.isFileURL {
                self?.directory = url.path
            } else {
                self?.directory = pwd
            }
        }
        terminal.onAttention = { [weak self] message in
            guard let self else { return }
            if isFrontmost() && NSApp.isActive { return }
            self.status = .needsAttention(message)
            NSApp.requestUserAttention(.informationalRequest)
        }
        terminal.onCommandFinished = { [weak self] code in
            guard let self else { return }
            if case .needsAttention = self.status { return }
            self.status = .finished(exitCode: code)
        }
        terminal.onChildExited = { [weak self] code in
            self?.status = .exited(code)
        }
        terminal.onFocus = { [weak self] in
            guard let self else { return }
            if case .needsAttention = self.status { self.status = .running }
        }
        terminal.onCloseRequested = { _ in onClose() }
    }
}
