import Foundation

/// A past conversation an agent can resume.
struct Conversation: Identifiable, Hashable {
    let id: String
    let agentID: String
    let title: String
    let updated: Date
}

/// Reads each agent's own on-disk session store (read-only) to list past
/// conversations for a folder.
///
/// Formats (2026-11):
/// - Claude Code: ~/.claude/projects/<cwd with non-alphanumerics → "-">/<id>.jsonl
///   title = last `custom-title` entry, else the first real user message.
/// - Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl; first line is
///   `session_meta` with id / cwd / source (sub-agent threads are skipped).
/// - Grok: ~/.grok/sessions/<percent-encoded cwd>/<id>/summary.json
enum ConversationHistory {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Newest first. Call off the main thread: it reads files.
    static func list(for agent: AgentKind, directory: String, limit: Int = 50) -> [Conversation] {
        let dir = (directory as NSString).standardizingPath
        let items: [Conversation]
        switch agent.history {
        case .claude: items = claude(dir, agentID: agent.id)
        case .codex: items = codex(dir, agentID: agent.id)
        case .grok: items = grok(dir, agentID: agent.id)
        case .none: items = []
        }
        // A resumed Codex conversation gets a new rollout file with the same id.
        var seen = Set<String>()
        let unique = items.sorted { $0.updated > $1.updated }.filter { seen.insert($0.id).inserted }
        return Array(unique.prefix(limit))
    }

    // MARK: Claude Code

    static func claudeProjectDir(for directory: String) -> URL {
        let encoded = String(directory.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects/\(encoded)")
    }

    private static func claude(_ dir: String, agentID: String) -> [Conversation] {
        let folder = claudeProjectDir(for: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { return nil }   // skip agent-*.jsonl side chains
            let head = readHead(url, bytes: 512 * 1024)
            var firstUser: String?
            for line in head.split(separator: "\n") {
                guard line.contains("\"type\":\"user\""),
                      let e = json(line), e["type"] as? String == "user",
                      (e["isSidechain"] as? Bool) != true,
                      let msg = e["message"] as? [String: Any] else { continue }
                if let t = userText(msg["content"]), !t.hasPrefix("<") { firstUser = t; break }
            }
            // Titles are appended over time; look at the end of the file.
            var title: String?
            for line in readTail(url, bytes: 256 * 1024).split(separator: "\n").reversed()
                where line.contains("\"custom-title\"") || line.contains("\"type\":\"summary\"") {
                if let e = json(line) { title = (e["customTitle"] as? String) ?? (e["summary"] as? String) }
                if title != nil { break }
            }
            guard let name = title ?? firstUser else { return nil }   // empty session
            return Conversation(id: id, agentID: agentID, title: clean(name), updated: modified(url))
        }
    }

    private static func userText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            let t = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    // MARK: Codex

    private static var codexRoot: URL { home.appendingPathComponent(".codex/sessions") }

    private static func codex(_ dir: String, agentID: String) -> [Conversation] {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        return codexRollouts(modifiedAfter: cutoff).compactMap { url in
            guard let meta = codexMeta(url), meta.cwd == dir, !meta.isSubAgent else { return nil }
            let title = codexFirstUserMessage(url) ?? "(无标题)"
            return Conversation(id: meta.id, agentID: agentID, title: clean(title), updated: modified(url))
        }
    }

    /// The Codex session started in `directory` after `since`, if it has been written yet.
    /// Codex can't be told an id up front, so we find it afterwards.
    static func findNewCodexSession(directory: String, since: Date) -> String? {
        let dir = (directory as NSString).standardizingPath
        let candidates = codexRollouts(modifiedAfter: since.addingTimeInterval(-5))
            .compactMap { url -> (String, Date)? in
                guard let meta = codexMeta(url), meta.cwd == dir, !meta.isSubAgent,
                      meta.started >= since.addingTimeInterval(-5) else { return nil }
                return (meta.id, meta.started)
            }
        return candidates.min { $0.1 < $1.1 }?.0   // the first one started after launch
    }

    private static func codexRollouts(modifiedAfter cutoff: Date) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            if modified(url) >= cutoff { out.append(url) }
        }
        return out
    }

    private struct CodexMeta { let id: String; let cwd: String; let started: Date; let isSubAgent: Bool }

    private static func codexMeta(_ url: URL) -> CodexMeta? {
        // The first line embeds the base instructions and can be large.
        guard let first = readFirstLine(url, max: 4 * 1024 * 1024),
              let e = json(first[...]), e["type"] as? String == "session_meta",
              let p = e["payload"] as? [String: Any],
              let id = p["id"] as? String, let cwd = p["cwd"] as? String else { return nil }
        let src = p["source"]
        let isSub = (src as? [String: Any])?["subagent"] != nil
        let started = (p["timestamp"] as? String).flatMap(parseISO) ?? modified(url)
        return CodexMeta(id: id, cwd: (cwd as NSString).standardizingPath, started: started, isSubAgent: isSub)
    }

    /// The first thing the user actually typed. The CLI logs it as an
    /// `event_msg/user_message`; the desktop app only as `response_item`s,
    /// preceded by injected context (AGENTS.md, <environment_context>, page
    /// snapshots), which we skip.
    private static func codexFirstUserMessage(_ url: URL) -> String? {
        func isInjected(_ t: String) -> Bool {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty || s.hasPrefix("<") || s.hasPrefix("# AGENTS.md")
        }
        /// Messages with attachments start with a "# Files mentioned by the
        /// user:" block; the actual words follow "## My request…:".
        func request(_ t: String) -> String {
            guard t.contains("# Files mentioned by the user"),
                  let r = t.range(of: #"## My request[^:\n]*:"#, options: .regularExpression) else { return t }
            return String(t[r.upperBound...])
        }
        for line in readHead(url, bytes: 2 * 1024 * 1024).split(separator: "\n").dropFirst() {
            guard line.contains("\"user"), let e = json(line), let p = e["payload"] as? [String: Any] else { continue }
            if p["type"] as? String == "user_message", let m = p["message"] as? String, !isInjected(m) {
                return request(m)
            }
            if e["type"] as? String == "response_item", p["role"] as? String == "user",
               let parts = p["content"] as? [[String: Any]] {
                for part in parts where (part["type"] as? String) == "input_text" {
                    if let t = part["text"] as? String, !isInjected(t) { return request(t) }
                }
            }
        }
        return nil
    }

    // MARK: Grok

    private static func grok(_ dir: String, agentID: String) -> [Conversation] {
        let root = home.appendingPathComponent(".grok/sessions")
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        guard let folder = folders.first(where: { ($0.removingPercentEncoding ?? $0) == dir }) else { return [] }
        let base = root.appendingPathComponent(folder)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return ids.compactMap { id in
            let summary = base.appendingPathComponent(id).appendingPathComponent("summary.json")
            guard let data = try? Data(contentsOf: summary),
                  let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let info = e["info"] as? [String: Any]
            let sid = (info?["id"] as? String) ?? id
            let title = (e["session_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(无标题)"
            let updated = (e["updated_at"] as? String).flatMap(parseISO) ?? modified(summary)
            return Conversation(id: sid, agentID: agentID, title: clean(title), updated: updated)
        }
    }

    // MARK: Helpers

    private static func readHead(_ url: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }

    /// Reads 64 KB at a time until the first newline.
    private static func readFirstLine(_ url: URL, max: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < max, let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let nl = chunk.firstIndex(of: 0x0A) {
                buf.append(chunk[chunk.startIndex..<nl])
                return String(decoding: buf, as: UTF8.self)
            }
            buf.append(chunk)
        }
        return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self)
    }

    private static func readTail(_ url: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func clean(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}
