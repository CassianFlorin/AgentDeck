import AppKit
import Security

/// Builds ssh invocations for a RemoteHost.
enum SSH {
    /// Single-quote for a POSIX shell.
    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// tmux/zellij-safe session name.
    static func sessionName(_ s: String) -> String {
        let cleaned = s.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "agentdeck" : String(name.prefix(40))
    }

    /// Arguments common to interactive and background use (no destination).
    static func options(for host: RemoteHost, interactive: Bool) -> [String] {
        var a: [String] = []
        if let port = host.port, port != 22 { a += ["-p", String(port)] }
        if let user = host.user, !user.isEmpty { a += ["-l", user] }
        if host.auth == .key, let key = host.identityFile, !key.isEmpty {
            a += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        if host.auth == .password {
            a += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        if let jump = host.jumpHost, !jump.isEmpty { a += ["-J", jump] }
        // Notice dead connections instead of hanging forever.
        a += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        if interactive { a.append("-t") }
        if let extra = host.extraArguments, !extra.isEmpty {
            a += extra.split(separator: " ").map(String.init)
        }
        return a
    }

    /// The command run on the server for an interactive session.
    static func remoteCommand(for host: RemoteHost, sessionName: String?) -> String? {
        let cd = host.remoteDirectory.flatMap { $0.isEmpty ? nil : "cd \(quote($0)) 2>/dev/null; " } ?? ""
        switch host.persistence {
        case .tmux:
            let name = quote(sessionName ?? "agentdeck")
            // Fall back to a plain shell if tmux isn't installed, and say so.
            return cd + "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(name); "
                + "else echo '[AgentDeck] 服务器上没有 tmux，断线后无法恢复。'; exec \"$SHELL\" -l; fi"
        case .zellij:
            let name = quote(sessionName ?? "agentdeck")
            return cd + "if command -v zellij >/dev/null 2>&1; then exec zellij attach -c \(name); "
                + "else echo '[AgentDeck] 服务器上没有 zellij，断线后无法恢复。'; exec \"$SHELL\" -l; fi"
        case .auto:
            // Whatever the server has; silently a plain shell if neither.
            let name = quote(sessionName ?? "agentdeck")
            return cd + "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(name); "
                + "elif command -v zellij >/dev/null 2>&1; then exec zellij attach -c \(name); "
                + "else exec \"$SHELL\" -l; fi"
        case .none:
            return cd.isEmpty ? nil : cd + "exec \"$SHELL\" -l"
        }
    }

    /// The full line typed into the local shell to connect.
    static func commandLine(for host: RemoteHost, sessionName: String?) -> String {
        var env = ["TERM=\(quote(host.term.isEmpty ? "xterm-256color" : host.term))"]
        if host.auth == .password, let exe = Bundle.main.executablePath {
            env += ["SSH_ASKPASS=\(quote(exe))", "SSH_ASKPASS_REQUIRE=force",
                    "\(Askpass.hostEnv)=\(host.id.uuidString)"]
        }
        // `command` skips shell-integration's ssh wrapper (ghostty +ssh), so the
        // host's own TERM setting is what the server sees.
        var parts = env + ["command", "ssh"] + options(for: host, interactive: true).map(quote) + [quote(host.host)]
        if let cmd = remoteCommand(for: host, sessionName: sessionName) { parts.append(quote(cmd)) }
        return parts.joined(separator: " ")
    }

    // MARK: Background probes

    struct ProbeResult {
        var ok: Bool
        var output: String
    }

    /// Run a non-interactive command on the host (connection test, listing sessions).
    static func run(_ host: RemoteHost, command: String, timeout: TimeInterval = 15,
                    verbose: Bool = false) async -> ProbeResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var args = options(for: host, interactive: false)
            args += ["-o", "ConnectTimeout=8"]
            if verbose { args.append("-v") }
            var env = ProcessInfo.processInfo.environment
            if host.auth == .password, let exe = Bundle.main.executablePath {
                env["SSH_ASKPASS"] = exe
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env[Askpass.hostEnv] = host.id.uuidString
            } else {
                // Never hang on a prompt nobody can see.
                args += ["-o", "BatchMode=yes"]
            }
            args += [host.host, command]
            p.arguments = args
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            // Exactly one of termination / timeout / launch failure resumes.
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
            }
            let once = Once()
            let finish: @Sendable (ProbeResult) -> Void = { r in
                if once.claim() { cont.resume(returning: r) }
            }
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                finish(ProbeResult(ok: proc.terminationStatus == 0,
                                   output: String(decoding: data, as: UTF8.self)))
            }
            do { try p.run() } catch {
                finish(ProbeResult(ok: false, output: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                finish(ProbeResult(ok: false, output: "超时（\(Int(timeout)) 秒）"))
            }
        }
    }

    struct ServerInfo {
        var system: String
        var hasTmux: Bool
        var hasZellij: Bool
        var sessions: [String]

        /// Which multiplexer a host with this setting ends up using here.
        func multiplexer(for p: RemoteHost.Persistence) -> String? {
            switch p {
            case .tmux: return hasTmux ? "tmux" : nil
            case .zellij: return hasZellij ? "zellij" : nil
            case .auto: return hasTmux ? "tmux" : (hasZellij ? "zellij" : nil)
            case .none: return nil
            }
        }
    }

    /// One round trip: OS, which multiplexers exist, and their sessions.
    static func inspect(_ host: RemoteHost) async -> Result<ServerInfo, ProbeError> {
        let script = """
        echo "@sys $(uname -sr 2>/dev/null)"; \
        command -v tmux >/dev/null 2>&1 && echo "@tmux" && tmux ls -F '@t #S' 2>/dev/null; \
        command -v zellij >/dev/null 2>&1 && echo "@zellij" && zellij ls -n -s 2>/dev/null | sed 's/^/@z /'; \
        true
        """
        let r = await run(host, command: script)
        guard r.ok else {
            var message = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hint = await diagnose(host, failure: message) { message += "\n\n" + hint }
            return .failure(ProbeError(message: message))
        }
        var info = ServerInfo(system: "", hasTmux: false, hasZellij: false, sessions: [])
        var tmuxSessions: [String] = [], zellijSessions: [String] = []
        for line in r.output.components(separatedBy: .newlines) {
            if line.hasPrefix("@sys ") { info.system = String(line.dropFirst(5)) }
            else if line == "@tmux" { info.hasTmux = true }
            else if line == "@zellij" { info.hasZellij = true }
            else if line.hasPrefix("@t ") { tmuxSessions.append(String(line.dropFirst(3))) }
            else if line.hasPrefix("@z ") { zellijSessions.append(String(line.dropFirst(3))) }
        }
        // Sessions of the multiplexer this host will actually use.
        switch host.persistence {
        case .tmux: info.sessions = tmuxSessions
        case .zellij: info.sessions = zellijSessions
        case .auto: info.sessions = info.hasTmux ? tmuxSessions : zellijSessions
        case .none: info.sessions = []
        }
        return .success(info)
    }

    /// "Connection closed" during key exchange is opaque; look at what the
    /// other end actually sent. A proxy/TUN in the path often answers port 22
    /// with an HTTP error instead of an SSH banner.
    private static func diagnose(_ host: RemoteHost, failure: String) async -> String? {
        guard failure.contains("Connection closed") || failure.contains("kex_exchange_identification") else { return nil }
        let v = await run(host, command: "true", timeout: 12, verbose: true)
        // e.g. "debug1: kex_exchange_identification: banner line 0: HTTP/1.1 403 Forbidden"
        // ssh -v output uses \r\n, which Swift treats as one Character.
        let banner = v.output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let r = line.range(of: #"banner line \d+: "#, options: .regularExpression) else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard let status = banner.first, status.hasPrefix("HTTP/") else { return nil }
        return "对方返回的不是 SSH，而是 HTTP 响应（\(status)）：这条连接被代理拦下了，没有到达服务器。"
            + "常见原因是 Clash 等代理把它交给了代理节点，而节点不放行 22 端口。"
            + "可以给这台服务器加直连规则（如 IP-CIDR,<IP>/32,DIRECT），换一个放行 SSH 的节点，"
            + "或让 sshd 监听代理放行的端口。"
    }

    struct ProbeError: Error {
        var message: String
    }
}

/// Passwords for hosts, in the login Keychain.
enum HostKeychain {
    private static let service = "com.cassianflorin.agentdeck.ssh"

    static func password(for id: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for id: UUID) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func setPassword(_ password: String, for id: UUID, label: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: id.uuidString]
        let data = Data(password.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "AgentDeck SSH: \(label)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deletePassword(for id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
    }
}

/// When ssh runs AgentDeck as SSH_ASKPASS, we answer its prompt and exit
/// without ever starting the UI.
///
/// - Password prompts are answered from the Keychain.
/// - Anything else (host-key confirmation, key passphrase, OTP) gets a small
///   native dialog, so first connections and 2FA still work.
enum Askpass {
    static let hostEnv = "AGENTDECK_ASKPASS_HOST"

    /// Call first thing at launch.
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let hostID = env[hostEnv], env["SSH_ASKPASS"] != nil else { return }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        let lower = prompt.lowercased()

        if lower.contains("password"), !lower.contains("passphrase"),
           let id = UUID(uuidString: hostID), let pw = HostKeychain.password(for: id) {
            FileHandle.standardOutput.write(Data((pw + "\n").utf8))
            exit(0)
        }

        // Fall back to asking the user.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SSH"
        alert.informativeText = prompt
        let secret = lower.contains("password") || lower.contains("passphrase")
            || lower.contains("verification") || lower.contains("code")
        let field: NSTextField = secret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        if lower.contains("yes/no") { field.stringValue = "yes" }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
        exit(0)
    }
}
