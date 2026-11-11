import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var workspace: Workspace
    @State private var renamingGroup: String?
    @State private var newGroupFor: AgentSession?
    @State private var serversExpanded = true

    var body: some View {
        List(selection: $workspace.selectedID) {
            Section("会话") {
                rows(for: nil)
            }
            ForEach(workspace.groups, id: \.self) { group in
                Section(isExpanded: expandedBinding(group)) {
                    rows(for: group)
                } header: {
                    Text(group)
                        .contextMenu {
                            Button("重命名分组…") { renamingGroup = group }
                            Button("解散分组") { workspace.ungroup(group) }
                        }
                }
            }
            Section(isExpanded: $serversExpanded) {
                ServerList()
            } header: {
                HStack {
                    Text("服务器")
                    Spacer()
                    Button { workspace.editingHost = RemoteHost(name: "", host: "") } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加服务器")
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: Binding(get: { renamingGroup.map(GroupRef.init) }, set: { renamingGroup = $0?.name })) { ref in
            RenameSheet(title: "重命名分组", initial: ref.name) { workspace.renameGroup(ref.name, to: $0) }
        }
        .sheet(item: $newGroupFor) { session in
            RenameSheet(title: "新建分组", initial: session.folderName) { name in
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { workspace.move(session, toGroup: n) }
            }
        }
    }

    @ViewBuilder
    private func rows(for group: String?) -> some View {
        ForEach(workspace.sessions(in: group)) { session in
            SessionRow(session: session)
                .tag(session.id)
                .contextMenu { menu(for: session) }
        }
        .onMove { workspace.move(inGroup: group, from: $0, to: $1) }
    }

    @ViewBuilder
    private func menu(for session: AgentSession) -> some View {
        if session.remote != nil {
            Button("重新连接") { workspace.reconnect(session) }
            if let host = workspace.host(for: session) {
                Button("编辑服务器…") { workspace.editingHost = host }
            }
            Divider()
        }
        if session.kind.isAgent && session.remote == nil {
            if session.activity == .exited {
                Button("重新启动 \(session.kind.name)") { workspace.restartAgent(session) }
            }
            if session.kind.history != .none {
                Button("恢复这个文件夹的其他对话…") {
                    workspace.showResume(directory: session.directory, agentID: session.kind.id)
                }
            }
            Divider()
        }
        Button("重命名…") { workspace.renaming = session }
        Menu("移到分组") {
            ForEach(workspace.groups.filter { $0 != session.group }, id: \.self) { g in
                Button(g) { workspace.move(session, toGroup: g) }
            }
            if !workspace.groups.isEmpty { Divider() }
            Button("新建分组…") { newGroupFor = session }
            if session.group != nil {
                Button("移出分组") { workspace.move(session, toGroup: nil) }
            }
        }
        Divider()
        if session.remote == nil {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
            }
            Button("同目录再开一个") {
                workspace.open(kind: session.kind, directory: session.directory, group: session.group)
            }
        }
        Divider()
        Button("关闭", role: .destructive) { workspace.close(session) }
    }

    private func expandedBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { !workspace.collapsedGroups.contains(group) },
            set: { open in
                if open { workspace.collapsedGroups.remove(group) } else { workspace.collapsedGroups.insert(group) }
            })
    }
}

private struct GroupRef: Identifiable {
    let name: String
    var id: String { name }
}

struct SessionRow: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped each time the session starts needing you, to bounce its icon once.
    @State private var nudge = 0

    /// An agent waiting on you, or a bell / notification you haven't looked at.
    private var needsYou: Bool {
        if case .waiting = session.activity { return true }
        if case .needsAttention = session.status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind.symbol)
                .frame(width: 18)
                .foregroundStyle(needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: nudge)
                .animation(.easeInOut(duration: 0.25), value: needsYou)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let label = session.activity.label {
                        ActivityBadge(activity: session.activity, label: label)
                    }
                    Text(session.folderName)
                    if session.panes.count > 1 {
                        Text("· \(session.panes.count) 个窗格")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.activity == .exited {
                Button { workspace.restartAgent(session) } label: {
                    Image(systemName: "play.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(session.conversationID != nil ? "重新启动 \(session.kind.name)，回到同一段对话" : "重新启动 \(session.kind.name)")
            } else if session.isDisconnected {
                Button { workspace.reconnect(session) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("已断开，点击重新连接（会重新附加服务器上的会话）")
            } else {
                StatusDot(status: session.status)
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
        .onChange(of: needsYou) { _, now in
            if now && !reduceMotion { nudge += 1 }
        }
    }

    private var helpText: String {
        var parts = [session.directory.abbreviatingHome]
        if case .needsAttention(let msg?) = session.status { parts.append(msg) }
        if case .waiting(let msg?) = session.activity { parts.append(msg) }
        if let id = session.conversationID { parts.append("对话 \(id)") }
        return parts.joined(separator: "\n")
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .running:
            EmptyView()
        case .needsAttention:
            PulsingDot(color: .orange, size: 8)
                .help("等你处理")
        case .finished(let code):
            Circle().fill(code == 0 || code == -1 ? Color.green.opacity(0.7) : .red).frame(width: 6, height: 6)
        case .disconnected:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
        }
    }
}

struct NewSessionMenu: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog

    var body: some View {
        Menu {
            ForEach(catalog.visible) { kind in
                Menu {
                    Button("选择文件夹…") { NewSessionPanel.present(kind: kind, in: workspace) }
                    if !workspace.recentDirectories.isEmpty {
                        Divider()
                        ForEach(workspace.recentDirectories, id: \.self) { dir in
                            Button(dir.abbreviatingHome) { workspace.open(kind: kind, directory: dir) }
                        }
                    }
                    if kind.history != .none && kind.canResume {
                        Divider()
                        Button("恢复之前的对话…") { workspace.showResume(agentID: kind.id) }
                    }
                } label: {
                    Label(catalog.isInstalled(kind) == false ? "\(kind.name)（未安装）" : kind.name,
                          systemImage: kind.symbol)
                }
            }
            Divider()
            Button("管理 Agent…") { workspace.managingAgents = true }
            Divider()
            Menu {
                ForEach(workspace.hosts) { host in
                    Button { workspace.connect(host) } label: { Label(host.name, systemImage: host.symbol) }
                }
                if !workspace.sshConfigAliases.isEmpty {
                    Divider()
                    Section("~/.ssh/config") {
                        ForEach(workspace.sshConfigAliases, id: \.self) { alias in
                            Button(alias) { workspace.connect(alias: alias) }
                        }
                    }
                }
                Divider()
                Button("添加服务器…") { workspace.editingHost = RemoteHost(name: "", host: "") }
                if !workspace.hiddenSSHConfigAliases.isEmpty {
                    Button("恢复已删除的 ssh config 条目") { workspace.unhideSSHConfigAliases() }
                }
            } label: {
                Label("连接服务器", systemImage: "server.rack")
            }
        } label: {
            Label("新建会话", systemImage: "plus")
        }
        .help("新建会话")
    }
}

enum NewSessionPanel {
    @MainActor
    static func present(kind: AgentKind, in workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "在此打开 \(kind.name)"
        if let recent = workspace.recentDirectories.first {
            panel.directoryURL = URL(fileURLWithPath: recent)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.open(kind: kind, directory: url.path, group: workspace.selected?.group)
    }
}

/// Saved servers plus ~/.ssh/config aliases, inside the sidebar's 服务器 section.
struct ServerList: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        ForEach(workspace.hosts) { host in
            HostRow(host: host, openCount: workspace.sessions.filter { $0.remote?.hostID == host.id }.count)
                .contextMenu {
                    Button("连接（新会话）") { workspace.connect(host) }
                    if host.persistence.usesSessionName {
                        Button("附加到已有会话…") { workspace.pickingSessionFor = host }
                    }
                    Divider()
                    Button("编辑…") { workspace.editingHost = host }
                    Button("复制") {
                        var copy = host
                        copy.id = UUID()
                        copy.name += " 副本"
                        workspace.editingHost = copy
                    }
                    Divider()
                    Button("删除", role: .destructive) { confirmDelete(host) }
                }
        }
        ForEach(workspace.sshConfigAliases, id: \.self) { alias in
            HStack(spacing: 8) {
                Image(systemName: "doc.text").frame(width: 18).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alias).lineLimit(1)
                    Text("~/.ssh/config").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                ConnectButton { workspace.connect(alias: alias) }
            }
            .padding(.vertical, 2)
            .contextMenu {
                Button("连接") { workspace.connect(alias: alias) }
                Button("保存为服务器…") { workspace.editingHost = .fromSSHConfig(alias: alias) }
                Divider()
                Button("从列表中删除", role: .destructive) { confirmHide(alias) }
                if !workspace.hiddenSSHConfigAliases.isEmpty {
                    Button(restoreHiddenTitle) { workspace.unhideSSHConfigAliases() }
                }
            }
        }
        if workspace.hosts.isEmpty && workspace.sshConfigAliases.isEmpty {
            Button("添加服务器…") { workspace.editingHost = RemoteHost(name: "", host: "") }
                .buttonStyle(.link)
        }
        if workspace.sshConfigAliases.isEmpty && !workspace.hiddenSSHConfigAliases.isEmpty {
            Button(restoreHiddenTitle) { workspace.unhideSSHConfigAliases() }
                .buttonStyle(.link)
        }
    }

    private var restoreHiddenTitle: String {
        "恢复已删除的 ssh config 条目（\(workspace.hiddenSSHConfigAliases.count)）"
    }

    private func confirmHide(_ alias: String) {
        let alert = NSAlert()
        alert.messageText = "从列表中删除“\(alias)”？"
        alert.informativeText = "只是不在 AgentDeck 里显示，~/.ssh/config 不会被修改，ssh 命令照常可用。之后可在右键菜单里恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { workspace.hideSSHConfigAlias(alias) }
    }

    private func confirmDelete(_ host: RemoteHost) {
        let alert = NSAlert()
        alert.messageText = "删除服务器“\(host.name)”？"
        alert.informativeText = "只删除 AgentDeck 里的配置和钥匙串里保存的密码，不会影响服务器，也不会关闭已打开的会话。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { workspace.deleteHost(host) }
    }
}

struct HostRow: View {
    let host: RemoteHost
    let openCount: Int
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: host.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(host.name).lineLimit(1)
                    if let p = host.provider {
                        Text(p)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(openCount > 0 ? "\(host.address) · \(openCount) 个已打开" : host.address)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ConnectButton { workspace.connect(host) }
        }
        .padding(.vertical, 2)
        .help(host.address)
    }
}

private struct ConnectButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? "play.circle.fill" : "play.circle")
                .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .scaleEffect(hovering && !reduceMotion ? 1.12 : 1)
        }
        .buttonStyle(.borderless)
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = h }
        }
        .help("连接")
    }
}

/// "运行中 / 等你 / 本轮完成 …" next to the folder name.
///
/// Motion carries meaning: working shimmers, waiting ripples (it's the one
/// that needs you), done/ready stay still. Everything goes static under
/// "Reduce motion".
struct ActivityBadge: View {
    let activity: AgentActivity
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when a turn finishes, for a single bounce of the dot.
    @State private var finished = 0

    var body: some View {
        HStack(spacing: 3) {
            switch activity {
            case .working:
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                Text(label).foregroundStyle(color).shimmer(active: !reduceMotion)
            case .waiting:
                PulsingDot(color: color, size: 5)
                Text(label).foregroundStyle(color).fontWeight(.medium)
            default:
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(color)
                    .symbolEffect(.bounce, value: finished)
                Text(label).foregroundStyle(color)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activity)
        .onChange(of: activity) { old, new in
            if new == .done && old != .done && !reduceMotion { finished += 1 }
        }
    }

    private var color: Color {
        switch activity {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .exited: return .secondary
        default: return .secondary
        }
    }
}

/// A solid dot with a ring that keeps expanding and fading out — "look here".
struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 1)
                        .scaleEffect(expanded ? 2.6 : 1)
                        .opacity(expanded ? 0 : 0.8)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

/// A soft highlight that sweeps across text, for "still working".
private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.3)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -0.6
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}
