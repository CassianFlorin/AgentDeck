import SwiftUI

// MARK: - Agent manager

/// Lists all agents (built-in presets + your own), shows whether each is
/// installed, and lets you edit commands or add a custom agent.
struct AgentManagerView: View {
    @EnvironmentObject private var catalog: AgentCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AgentKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agent").font(.title3.bold())
                Spacer()
                if catalog.detecting { ProgressView().controlSize(.small) }
                Button("重新检测") { catalog.detectInstalled() }
            }
            .padding(16)

            List {
                ForEach(catalog.agents) { agent in
                    AgentRow(agent: agent)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = agent }
                        .contextMenu {
                            Button("编辑…") { editing = agent }
                            Button(agent.hidden ? "在菜单中显示" : "从菜单中隐藏") {
                                var a = agent
                                a.hidden.toggle()
                                catalog.save(a)
                            }
                            if agent.isBuiltIn {
                                Button("恢复默认") { catalog.remove(agent) }
                            } else {
                                Button("删除", role: .destructive) { catalog.remove(agent) }
                            }
                        }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button { editing = catalog.newCustomAgent() } label: { Label("添加自定义 Agent", systemImage: "plus") }
                Spacer()
                Text("双击编辑 · 右键更多").font(.caption).foregroundStyle(.secondary)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 480)
        .sheet(item: $editing) { agent in
            AgentEditor(agent: agent) { catalog.save($0) }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentKind
    @EnvironmentObject private var catalog: AgentCatalog

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name.isEmpty ? agent.id : agent.name)
                    if agent.hidden { Tag(text: "已隐藏") }
                    if !agent.isBuiltIn { Tag(text: "自定义") }
                    if agent.history != .none { Tag(text: "可恢复对话") }
                    if AgentHook.isPrecise(agent) { Tag(text: "精确状态") }
                }
                Text(agent.command ?? "登录 shell")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            installState
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var installState: some View {
        switch catalog.isInstalled(agent) {
        case .some(true):
            Label(catalog.path(of: agent).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "可用",
                  systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green).lineLimit(1)
                .frame(maxWidth: 220, alignment: .trailing)
        case .some(false):
            VStack(alignment: .trailing, spacing: 2) {
                Label("未安装", systemImage: "xmark.circle").font(.caption).foregroundStyle(.orange)
                if let hint = agent.installHint {
                    Text(hint).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1)
                }
            }
            .frame(maxWidth: 260, alignment: .trailing)
        case .none:
            ProgressView().controlSize(.mini)
        }
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Edit a preset or a custom agent.
struct AgentEditor: View {
    @State var agent: AgentKind
    let onSave: (AgentKind) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Whether the agent's status hook file is in place (Grok / Codex).
    @State private var hookInstalled = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $agent.name, prompt: Text("例如：Qwen Code"))
                    Picker("图标", selection: $agent.symbol) {
                        ForEach(AgentKind.symbolChoices, id: \.self) { s in
                            Label(s, systemImage: s).labelStyle(.iconOnly).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("命令", text: Binding(get: { agent.command ?? "" },
                                                   set: { agent.command = $0.isEmpty ? nil : $0 }),
                              prompt: Text("可执行文件和固定参数，例如 qwen 或 codex --search"))
                        .font(.body.monospaced())
                        .disabled(agent.id == "shell")
                }
                Section {
                    TextField("新对话参数", text: $agent.newArgs, prompt: Text("可选，例如 --session-id {id}"))
                    TextField("恢复对话参数", text: $agent.resumeArgs, prompt: Text("例如 --resume {id}"))
                    TextField("继续最近对话参数", text: $agent.continueArgs, prompt: Text("例如 --continue"))
                    TextField("带提示词启动参数", text: $agent.promptArgs, prompt: Text("例如 {prompt}，或 -i {prompt}"))
                } header: {
                    Text("对话")
                } footer: {
                    Text("{id} 会被替换成对话 ID。新对话参数里带 {id} 时，AgentDeck 会自己生成 ID 并记住，重启后能精确恢复。{prompt} 会被替换成在 Agent 总览里派发的任务；留空则这个 Agent 不能被派发。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("历史记录来源", selection: $agent.history) {
                        Text("无").tag(AgentKind.History.none)
                        Text("Claude Code (~/.claude)").tag(AgentKind.History.claude)
                        Text("Codex (~/.codex)").tag(AgentKind.History.codex)
                        Text("Grok (~/.grok)").tag(AgentKind.History.grok)
                    }
                    Toggle("在新建会话菜单中隐藏", isOn: $agent.hidden)
                }
                Section {
                    Picker("状态来源", selection: $agent.hooks) {
                        Text("通用信号（回车、响铃、进度）").tag(AgentKind.Hooks.none)
                        Text("Claude Code hooks").tag(AgentKind.Hooks.claude)
                        Text("Grok hooks").tag(AgentKind.Hooks.grok)
                        Text("Codex hooks").tag(AgentKind.Hooks.codex)
                    }
                    if let dropIn = AgentHook.dropIn(for: agent) {
                        Toggle("安装状态 hook", isOn: Binding(
                            get: { hookInstalled },
                            set: { on in
                                if on { dropIn.install() } else { dropIn.uninstall() }
                                hookInstalled = dropIn.isInstalled
                            }))
                    }
                } header: {
                    Text("精确状态")
                } footer: {
                    Text(hooksNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onAppear { hookInstalled = AgentHook.dropIn(for: agent)?.isInstalled ?? false }
            .onChange(of: agent.hooks) { _, _ in hookInstalled = AgentHook.dropIn(for: agent)?.isInstalled ?? false }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if agent.name.trimmingCharacters(in: .whitespaces).isEmpty { agent.name = agent.executable ?? agent.id }
                    onSave(agent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(agent.id != "shell" && (agent.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    private var hooksNote: String {
        switch agent.hooks {
        case .none:
            return "从回车、响铃、通知和进度推断状态，不需要 Agent 配合。"
        case .claude:
            return "每次启动时用 --settings 带上 hooks，由 Agent 自己报告运行中、等你、本轮完成。你的设置文件不会被改。"
        case .grok:
            let path = AgentHook.DropIn.grok.file.path.abbreviatingHome
            return "Grok 只从它自己的配置目录读 hooks。打开后会新建 \(path)，你已有的文件不动；这个 hook 在 AgentDeck 之外什么也不做。Grok 可能要你先信任这个文件夹的 hooks，之后才生效。"
        case .codex:
            let path = AgentHook.DropIn.codex.file.path.abbreviatingHome
            return "打开后会新建 \(path)，并在启动 Codex 时加上 -p \(AgentHook.DropIn.codexProfile)；你的 config.toml 和 hooks.json 不动。Codex 会把新 hook 标为待审核，在 Codex 里用 /hooks 信任之后才生效。"
        }
    }
}

// MARK: - Resume a conversation

/// Lists an agent's past conversations in a folder and resumes the one you pick.
struct ResumeConversationView: View {
    let request: ResumeRequest
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var directory = ""
    @State private var agentID = ""
    @State private var items: [Conversation] = []
    @State private var loading = false

    private var resumable: [AgentKind] { catalog.agents.filter { $0.history != .none && $0.canResume } }
    private var agent: AgentKind? { catalog.agent(id: agentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("恢复之前的对话").font(.title3.bold())
            HStack {
                Picker("Agent", selection: $agentID) {
                    ForEach(resumable) { a in Label(a.name, systemImage: a.symbol).tag(a.id) }
                }
                .frame(width: 200)
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(directory.abbreviatingHome).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("换文件夹…", action: pickFolder)
            }

            Group {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("读取中…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    Text("这个文件夹里还没有 \(agent?.name ?? "") 的对话")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(items) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).lineLimit(1)
                                Text(c.updated.formatted(.relative(presentation: .named)) + " · " + c.id)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("恢复") { resume(c) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { resume(c) }
                    }
                }
            }
            .frame(minHeight: 260)

            HStack {
                if let agent, catalog.isInstalled(agent) == false {
                    Label("\(agent.name) 未安装，恢复后会在终端里报找不到命令", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .onAppear {
            directory = request.directory
            agentID = resumable.contains { $0.id == request.agentID } ? request.agentID : (resumable.first?.id ?? "")
        }
        .task(id: "\(agentID)|\(directory)") { await load() }
    }

    private func load() async {
        guard let agent, !directory.isEmpty else { items = []; return }
        loading = true
        let dir = directory
        items = await Task.detached { ConversationHistory.list(for: agent, directory: dir) }.value
        loading = false
    }

    private func resume(_ c: Conversation) {
        guard let agent else { return }
        workspace.open(kind: agent, directory: directory, group: workspace.selected?.group, resume: c)
        dismiss()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: directory)
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}
