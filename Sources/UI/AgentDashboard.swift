import SwiftUI

/// One row of the Agent 总览: an agent, the pane it runs in, and that pane's session.
@MainActor
struct AgentEntry: Identifiable {
    let session: AgentSession
    let pane: PaneView
    let agent: PaneAgent

    var id: String { pane.terminal.paneID }
    var directory: String { pane.terminal.currentDirectory ?? session.directory }

    /// The session's name when the agent is all there is to it, else the
    /// agent's own title (its current task, or its name).
    var title: String {
        if session.hasOnlyPrimaryAgent { return session.displayName }
        return session.agentLabel(for: pane)
    }

    var state: AgentDashboardState {
        switch agent.activity {
        case .waiting: return .waiting
        case .working: return .working
        case .exited: return .exited
        default: return .idle
        }
    }

    /// Search: the words you would look for it by.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [title, agent.kind.name, directory, session.displayName]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// The dashboard's sections, in the order you'd want to look at them.
enum AgentDashboardState: Int, CaseIterable {
    case waiting, working, idle, exited

    var title: String {
        switch self {
        case .waiting: return "等你"
        case .working: return "运行中"
        case .idle: return "空闲"
        case .exited: return "已退出"
        }
    }
}

extension Workspace {
    /// Every agent in every session, in sidebar order.
    var agentEntries: [AgentEntry] {
        orderedSessions.flatMap { session in
            session.agentPanes.compactMap { pane in
                pane.agent.map { AgentEntry(session: session, pane: pane, agent: $0) }
            }
        }
    }
}

/// Every agent on one screen, grouped by what it is doing. Select one to peek
/// at its terminal and answer it; open it to go to its session. New work can
/// be handed out from here without leaving.
struct AgentDashboard: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog
    @AppStorage("dashboard.groupByDirectory") private var groupByDirectory = false
    @State private var selection: String?
    @State private var query = ""
    @FocusState private var listFocused: Bool

    private struct Group: Identifiable {
        let id: String
        let title: String
        let entries: [AgentEntry]
    }

    private var groups: [Group] {
        let all = workspace.agentEntries.filter { $0.matches(query) }
        // Pinned ones stay on top, whatever they are doing.
        let pinned = all.filter { $0.session.pinned }
        let rest = all.filter { !$0.session.pinned }
        var result: [Group] = pinned.isEmpty ? [] : [Group(id: "pinned", title: "置顶", entries: pinned)]
        if groupByDirectory {
            var order: [String] = []
            var byDir: [String: [AgentEntry]] = [:]
            for e in rest {
                if byDir[e.directory] == nil { order.append(e.directory) }
                byDir[e.directory, default: []].append(e)
            }
            result += order.map { Group(id: $0, title: $0.abbreviatingHome, entries: byDir[$0] ?? []) }
        } else {
            result += AgentDashboardState.allCases.compactMap { state in
                // Within a state, whatever changed most recently comes first.
                let entries = rest.filter { $0.state == state }.sorted { $0.agent.since > $1.agent.since }
                return entries.isEmpty ? nil : Group(id: "\(state.rawValue)", title: state.title, entries: entries)
            }
        }
        return result
    }

    private var selected: AgentEntry? {
        workspace.agentEntries.first { $0.id == selection }
    }

    var body: some View {
        let groups = groups
        VStack(spacing: 0) {
            header
            AgentDispatchBar(suggestedDirectory: selected?.directory)
            if groups.isEmpty {
                empty
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section("\(group.title)  \(group.entries.count)") {
                            ForEach(group.entries) { entry in
                                AgentDashboardRow(entry: entry, showsFolder: !groupByDirectory).tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                // Return and double-click open the agent.
                .contextMenu(forSelectionType: String.self) { ids in
                    if let entry = workspace.agentEntries.first(where: { ids.contains($0.id) }) {
                        Button("打开") { open(entry) }
                        Button(entry.session.pinned ? "取消置顶" : "置顶") { workspace.togglePinned(entry.session) }
                        if entry.agent.activity == .working {
                            Button("停止这一轮") { entry.session.interrupt(entry.pane) }
                        }
                        if entry.agent.activity == .exited {
                            Button("重新启动 \(entry.agent.kind.name)") {
                                workspace.restartAgent(entry.session, pane: entry.pane)
                            }
                        }
                        Divider()
                        Button("重命名会话…") { workspace.renaming = entry.session }
                        Button("关闭会话", role: .destructive) { workspace.close(entry.session) }
                    }
                } primaryAction: { ids in
                    if let entry = workspace.agentEntries.first(where: { ids.contains($0.id) }) { open(entry) }
                }
                if let entry = selected {
                    Divider()
                    AgentPeek(entry: entry, open: { open(entry) })
                        .id(entry.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { workspace.showingDashboard = false }
        .onAppear {
            // Start on what most needs you (the first row), like the sidebar's ⌘⇧J.
            if selected == nil { selection = groups.first?.entries.first?.id }
            listFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(catalog.visible.filter(\.isAgent)) { kind in
                    Button { NewSessionPanel.present(kind: kind, in: workspace) } label: {
                        Label(catalog.isInstalled(kind) == false ? "\(kind.name)（未安装）" : kind.name,
                              systemImage: kind.symbol)
                    }
                }
                Divider()
                Button("恢复之前的对话…") { workspace.showResume() }
            } label: {
                Label("新建 Agent", systemImage: "plus")
            }
            .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选：名称、Agent、文件夹", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 280)
            Spacer()
            Picker("分组", selection: $groupByDirectory) {
                Text("按状态").tag(false)
                Text("按文件夹").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("还没有正在运行的 Agent").font(.title3)
                Text("在上面写一个任务派给 Agent，或者用“新建 Agent”开一个。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("没有匹配“\(query)”的 Agent").font(.title3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ entry: AgentEntry) {
        workspace.show(entry.pane, in: entry.session)
    }
}

/// Hand a task to a new agent: pick the agent and the folder, write the task,
/// Return. You stay on the list, so several can go out in a row.
private struct AgentDispatchBar: View {
    /// The selected row's folder: the likeliest place for the next task.
    let suggestedDirectory: String?
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog
    @AppStorage("dashboard.dispatchAgent") private var agentID = ""
    @State private var directory: String?
    @State private var prompt = ""

    /// Only agents that can be started with a prompt.
    private var agents: [AgentKind] { catalog.visible.filter(\.canTakePrompt) }
    private var agent: AgentKind? { agents.first { $0.id == agentID } ?? agents.first }
    private var folder: String {
        directory ?? suggestedDirectory ?? workspace.recentDirectories.first ?? NSHomeDirectory()
    }

    var body: some View {
        if let agent {
            HStack(spacing: 8) {
                Picker("Agent", selection: Binding(get: { agent.id }, set: { agentID = $0 })) {
                    ForEach(agents) { a in Label(a.name, systemImage: a.symbol).tag(a.id) }
                }
                .labelsHidden()
                .fixedSize()
                Menu {
                    ForEach(workspace.recentDirectories, id: \.self) { dir in
                        Button(dir.abbreviatingHome) { directory = dir }
                    }
                    if !workspace.recentDirectories.isEmpty { Divider() }
                    Button("选择文件夹…", action: pickFolder)
                } label: {
                    Label((folder as NSString).lastPathComponent, systemImage: "folder")
                }
                .fixedSize()
                .help(folder.abbreviatingHome)
                TextField("派一个新任务给 \(agent.name)，回车开始", text: $prompt)
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                if catalog.isInstalled(agent) == false {
                    Label("未安装", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func send() {
        guard let agent, workspace.dispatch(prompt, to: agent, in: folder) != nil else { return }
        prompt = ""
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        panel.prompt = "在此派发"
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}

private struct AgentDashboardRow: View {
    let entry: AgentEntry
    let showsFolder: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            stateIcon.frame(width: 12)
            Image(systemName: entry.agent.kind.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(entry.title).lineLimit(1)
            if entry.title != entry.agent.kind.name {
                Text(entry.agent.kind.name).foregroundStyle(.secondary).lineLimit(1)
            }
            if showsFolder {
                Text((entry.directory as NSString).lastPathComponent)
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            if entry.session.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Text(detail)
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .truncationMode(.tail)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.age(from: entry.agent.since, to: context.date))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var stateIcon: some View {
        switch entry.agent.activity {
        case .waiting:
            PulsingDot(color: .orange, size: 7)
        case .working:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .done:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
        default:
            Image(systemName: "circle").font(.system(size: 7)).foregroundStyle(.secondary)
        }
    }

    /// What it is waiting for, if it said; else the state in a word.
    private var detail: String {
        if case .waiting(let message?) = entry.agent.activity { return message }
        return entry.agent.activity.label ?? ""
    }

    private var detailColor: Color {
        switch entry.agent.activity {
        case .waiting: return .orange
        case .working: return .blue
        default: return .secondary
        }
    }

    /// "刚刚", "5 分", "2 时", "3 天": how long the agent has been in this state.
    static func age(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分" }
        if s < 86400 { return "\(s / 3600) 时" }
        return "\(s / 86400) 天"
    }
}

/// The selected agent's terminal at a glance, with what you need to answer
/// it without leaving the dashboard: a reply field, the keys a prompt takes,
/// and a way to stop it.
private struct AgentPeek: View {
    let entry: AgentEntry
    let open: () -> Void
    @EnvironmentObject private var workspace: Workspace
    @State private var lines: [String] = []
    @State private var reply = ""

    private static let shownLines = 10
    /// What an agent's own prompts are answered with: an option's number,
    /// Return for the highlighted one, Escape to back out.
    private static let quickKeys: [(label: String, keys: String, help: String)] = [
        ("1", "1", "选第 1 项"), ("2", "2", "选第 2 项"), ("3", "3", "选第 3 项"),
        ("↩", "\r", "回车：确认当前选中的那一项"), ("esc", "\u{1b}", "Esc：取消"),
    ]

    private var isWaiting: Bool {
        if case .waiting = entry.agent.activity { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: entry.agent.kind.symbol).foregroundStyle(.secondary)
                Text(entry.agent.kind.name).fontWeight(.medium)
                Text(entry.directory.abbreviatingHome)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                if entry.agent.activity == .working {
                    Button("停止") { entry.session.interrupt(entry.pane) }
                        .help("停止这一轮（向它发送 Esc）")
                }
                if entry.agent.activity == .exited {
                    Button("重新启动") { workspace.restartAgent(entry.session, pane: entry.pane) }
                }
                Button("打开", action: open)
            }
            .font(.callout)

            Text(lines.isEmpty ? " " : lines.joined(separator: "\n"))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(Self.shownLines, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    TextField("回复 \(entry.agent.kind.name)，回车发送", text: $reply)
                        .textFieldStyle(.plain)
                        .onSubmit(send)
                        .disabled(entry.agent.activity == .exited)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                // A prompt with options is answered with a key, not a sentence.
                if isWaiting {
                    ForEach(Self.quickKeys, id: \.label) { key in
                        Button(key.label) { entry.session.press(key.keys, in: entry.pane) }
                            .help(key.help)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // The terminal keeps changing while you look at it.
        .task {
            while !Task.isCancelled {
                lines = Self.tail(entry.pane.terminal.visibleText())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entry.session.send(text, to: entry.pane)
        reply = ""
    }

    /// The last few lines with something on them.
    private static func tail(_ screen: String) -> [String] {
        var all = screen.components(separatedBy: "\n")
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
        return Array(all.suffix(shownLines))
    }
}
