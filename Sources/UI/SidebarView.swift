import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var workspace: Workspace
    @State private var renamingGroup: String?
    @State private var newGroupFor: AgentSession?

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
        Button("在 Finder 中显示") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
        }
        Button("同目录再开一个") {
            workspace.open(kind: session.kind, directory: session.directory, group: session.group)
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
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
            StatusDot(status: session.status)
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    private var helpText: String {
        var parts = [session.directory.abbreviatingHome]
        if case .needsAttention(let msg?) = session.status { parts.append(msg) }
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
            Circle().fill(.orange).frame(width: 8, height: 8)
                .help("等你处理")
        case .finished(let code):
            Circle().fill(code == 0 || code == -1 ? Color.green.opacity(0.7) : .red).frame(width: 6, height: 6)
        }
    }
}

struct NewSessionMenu: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        Menu {
            ForEach(AgentKind.builtIn) { kind in
                Menu {
                    Button("选择文件夹…") { NewSessionPanel.present(kind: kind, in: workspace) }
                    if !workspace.recentDirectories.isEmpty {
                        Divider()
                        ForEach(workspace.recentDirectories, id: \.self) { dir in
                            Button(dir.abbreviatingHome) { workspace.open(kind: kind, directory: dir) }
                        }
                    }
                } label: {
                    Label(kind.name, systemImage: kind.symbol)
                }
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
