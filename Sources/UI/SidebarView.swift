import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        List(selection: $workspace.selectedID) {
            Section("会话") {
                ForEach(workspace.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
                            }
                            Button("同目录再开一个") {
                                workspace.open(kind: session.kind, directory: session.directory)
                            }
                            Divider()
                            Button("关闭", role: .destructive) { workspace.close(session) }
                        }
                }
                .onMove { workspace.move(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
    }
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
                Text(session.folderName)
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
        case .exited:
            Image(systemName: "stop.circle").font(.caption).foregroundStyle(.secondary)
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
        workspace.open(kind: kind, directory: url.path)
    }
}
