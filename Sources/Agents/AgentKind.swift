import Foundation

/// What runs in a session: a coding agent CLI, or a plain shell.
///
/// The command is *typed* into the user's login shell (so anything on PATH
/// works and you get a shell back when the agent exits). Argument templates
/// may contain `{id}`, replaced by a conversation id.
struct AgentKind: Codable, Hashable, Identifiable {
    /// Where an agent keeps its conversations, so we can list and resume them.
    enum History: String, Codable, CaseIterable {
        case none, claude, codex, grok
    }

    /// How AgentDeck learns what the agent is doing.
    enum Hooks: String, Codable {
        /// Generic signals only: Return pressed, bell / OSC 9 notifications,
        /// OSC 9;4 progress, the agent exiting.
        case none
        /// Claude Code hooks, injected per launch with `--settings` (the
        /// user's own settings files are never touched).
        case claude
        /// Grok and Codex run the same kind of hooks, but only load them from
        /// their own config folder, and only once you trust them there. So
        /// these are opt-in: a file of our own next to yours (see AgentHook.DropIn).
        case grok
        case codex
    }

    var id: String
    var name: String
    var symbol: String
    /// Executable plus fixed arguments, e.g. "claude" or "codex --search". nil = plain shell.
    var command: String?
    /// Extra arguments for a brand-new conversation. `{id}` = an id AgentDeck picks,
    /// so the conversation can be resumed exactly later.
    var newArgs: String = ""
    /// Arguments that resume a specific conversation (`{id}`).
    var resumeArgs: String = ""
    /// Arguments that continue the most recent conversation in this folder.
    var continueArgs: String = ""
    /// Arguments that start a new conversation with a first prompt (`{prompt}`),
    /// so a task can be handed over without going to the terminal.
    var promptArgs: String = ""
    var history: History = .none
    var hooks: Hooks = .none
    var installHint: String?
    var isBuiltIn = false
    /// Hidden from the new-session menus.
    var hidden = false

    var isAgent: Bool { command != nil }
    /// First word of the command: what we look up on PATH.
    var executable: String? { command?.split(separator: " ").first.map(String.init) }
    var assignsConversationID: Bool { newArgs.contains("{id}") }
    var canResume: Bool { isAgent && resumeArgs.contains("{id}") }
    var canContinue: Bool { isAgent && !continueArgs.isEmpty }
    var canTakePrompt: Bool { isAgent && promptArgs.contains("{prompt}") }
    /// The install hint, when it is a shell command we can run for you
    /// (some hints are just a pointer to the vendor's instructions).
    var installCommand: String? {
        guard let hint = installHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty,
              hint.allSatisfy(\.isASCII) else { return nil }
        return hint
    }

    init(id: String, name: String, symbol: String, command: String?, newArgs: String = "",
         resumeArgs: String = "", continueArgs: String = "", promptArgs: String = "", history: History = .none,
         hooks: Hooks = .none, installHint: String? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.command = command
        self.newArgs = newArgs
        self.resumeArgs = resumeArgs
        self.continueArgs = continueArgs
        self.promptArgs = promptArgs
        self.history = history
        self.hooks = hooks
        self.installHint = installHint
        self.isBuiltIn = isBuiltIn
    }

    // Tolerant decoding: agents.json from another version must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "terminal"
        command = try c.decodeIfPresent(String.self, forKey: .command)
        newArgs = try c.decodeIfPresent(String.self, forKey: .newArgs) ?? ""
        resumeArgs = try c.decodeIfPresent(String.self, forKey: .resumeArgs) ?? ""
        continueArgs = try c.decodeIfPresent(String.self, forKey: .continueArgs) ?? ""
        promptArgs = try c.decodeIfPresent(String.self, forKey: .promptArgs) ?? ""
        history = (try? c.decodeIfPresent(History.self, forKey: .history)) ?? .none
        hooks = (try? c.decodeIfPresent(Hooks.self, forKey: .hooks)) ?? .none
        installHint = try c.decodeIfPresent(String.self, forKey: .installHint)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    // MARK: Built-ins

    static let claude = AgentKind(
        id: "claude", name: "Claude Code", symbol: "sparkle", command: "claude",
        newArgs: "--session-id {id}", resumeArgs: "--resume {id}", continueArgs: "--continue",
        promptArgs: "{prompt}", history: .claude, hooks: .claude,
        installHint: "curl -fsSL https://claude.ai/install.sh | bash", isBuiltIn: true)

    static let codex = AgentKind(
        id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", command: "codex",
        newArgs: "", resumeArgs: "resume {id}", continueArgs: "resume --last",
        promptArgs: "{prompt}", history: .codex, hooks: .codex, installHint: "brew install codex", isBuiltIn: true)

    static let grok = AgentKind(
        id: "grok", name: "Grok", symbol: "bolt", command: "grok",
        newArgs: "--session-id {id}", resumeArgs: "--resume {id}", continueArgs: "--continue",
        promptArgs: "{prompt}", history: .grok, hooks: .grok, installHint: "见 x.ai 的 Grok CLI 安装说明", isBuiltIn: true)

    static let gemini = AgentKind(
        id: "gemini", name: "Gemini", symbol: "diamond", command: "gemini",
        newArgs: "", resumeArgs: "--resume {id}", continueArgs: "--resume latest",
        promptArgs: "-i {prompt}", installHint: "npm install -g @google/gemini-cli", isBuiltIn: true)

    // Below: launch and the generic status signals work for all of them. The
    // conversation arguments are filled only where the CLI documents them;
    // anything left empty just hides that feature for the agent.

    static let opencode = AgentKind(
        id: "opencode", name: "opencode", symbol: "curlybraces", command: "opencode",
        resumeArgs: "--session {id}", continueArgs: "--continue", promptArgs: "--prompt {prompt}",
        installHint: "npm install -g opencode-ai", isBuiltIn: true)

    static let qwen = AgentKind(
        id: "qwen", name: "Qwen Code", symbol: "q.circle", command: "qwen",
        resumeArgs: "--resume {id}", continueArgs: "--continue", promptArgs: "-i {prompt}",
        installHint: "npm install -g @qwen-code/qwen-code@latest", isBuiltIn: true)

    static let cursor = AgentKind(
        id: "cursor", name: "Cursor CLI", symbol: "cursorarrow.rays", command: "cursor-agent",
        resumeArgs: "--resume {id}", continueArgs: "resume", promptArgs: "{prompt}",
        installHint: "curl https://cursor.com/install -fsS | bash", isBuiltIn: true)

    static let copilot = AgentKind(
        id: "copilot", name: "Copilot CLI", symbol: "airplane", command: "copilot",
        resumeArgs: "--resume={id}", continueArgs: "--continue", promptArgs: "-i {prompt}",
        installHint: "npm install -g @github/copilot", isBuiltIn: true)

    static let droid = AgentKind(
        id: "droid", name: "Droid", symbol: "ant", command: "droid",
        resumeArgs: "--resume {id}", continueArgs: "--resume", promptArgs: "{prompt}",
        installHint: "curl -fsSL https://app.factory.ai/cli | sh", isBuiltIn: true)

    static let amp = AgentKind(
        id: "amp", name: "Amp", symbol: "waveform", command: "amp",
        installHint: "curl -fsSL https://ampcode.com/install.sh | bash", isBuiltIn: true)

    static let crush = AgentKind(
        id: "crush", name: "Crush", symbol: "heart", command: "crush",
        installHint: "brew install charmbracelet/tap/crush", isBuiltIn: true)

    static let aider = AgentKind(
        id: "aider", name: "Aider", symbol: "hammer", command: "aider",
        continueArgs: "--restore-chat-history",
        installHint: "python -m pip install aider-install && aider-install", isBuiltIn: true)

    static let shell = AgentKind(id: "shell", name: "Shell", symbol: "terminal", command: nil, isBuiltIn: true)

    /// Remote session; the actual ssh command comes from the RemoteHost. Not in the catalog.
    static let ssh = AgentKind(id: "ssh", name: "SSH", symbol: "server.rack", command: nil)

    /// Mainstream agents first; the menus only show the ones found on your PATH.
    static let builtIns: [AgentKind] = [.claude, .codex, .gemini, .grok, .opencode, .qwen, .cursor,
                                        .copilot, .droid, .amp, .crush, .aider, .shell]

    /// Symbols offered when creating a custom agent.
    static let symbolChoices = ["sparkle", "bolt", "diamond", "cpu", "brain", "wand.and.stars",
                                "chevron.left.forwardslash.chevron.right", "terminal", "hammer", "ant"]
}

// MARK: - Command lines

extension AgentKind {
    private func line(_ args: String, id: String?) -> String? {
        guard let command else { return nil }
        var a = args
        if let id { a = a.replacingOccurrences(of: "{id}", with: SSH.quote(id)) }
        return a.isEmpty ? command : "\(command) \(a)"
    }

    /// A new conversation, optionally opened with a first prompt. Returns the
    /// command and the conversation id we assigned (if the agent supports
    /// choosing one).
    func newConversation(prompt: String? = nil) -> (line: String?, conversationID: String?) {
        guard isAgent else { return (nil, nil) }
        let id = assignsConversationID ? UUID().uuidString.lowercased() : nil
        var result = line(newArgs, id: id)
        if let prompt, canTakePrompt, let base = result {
            // One line: the command is typed into a shell.
            let oneLine = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
            result = base + " " + promptArgs.replacingOccurrences(of: "{prompt}", with: SSH.quote(oneLine))
        }
        return (result, id)
    }

    func resumeLine(_ conversationID: String) -> String? {
        canResume ? line(resumeArgs, id: conversationID) : nil
    }

    func continueLine() -> String? {
        canContinue ? line(continueArgs, id: nil) : nil
    }
}
