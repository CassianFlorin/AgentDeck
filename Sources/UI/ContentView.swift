import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace
    @AppStorage(MonitorSettings.visibleKey) private var showMonitor = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            Group {
                if let session = workspace.selected {
                    SessionHost(session: session)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .navigationTitle(session.displayName)
                        .navigationSubtitle(session.directory.abbreviatingHome)
                        // The window paints the tint (see GlassWindowConfigurator); the title bar adds none.
                        .toolbarBackground(.hidden, for: .windowToolbar)
                } else {
                    EmptyStateView()
                }
            }
            // 性能 panel. A collapsed inspector keeps its content alive, so build
            // the panel only while open: its sampling starts and stops with it.
            .inspector(isPresented: $showMonitor) {
                Group {
                    if showMonitor { MonitorPanel() } else { Color.clear }
                }
                .inspectorColumnWidth(min: 230, ideal: 270, max: 400)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NewSessionMenu() }
            ToolbarItem(placement: .primaryAction) {
                Button { showMonitor.toggle() } label: {
                    Label("性能监视器", systemImage: "gauge.with.dots.needle.33percent")
                }
                .help(showMonitor ? "隐藏性能监视器（⌥⌘P）" : "显示性能监视器（⌥⌘P）")
            }
        }
        .background(GlassWindowConfigurator())
        .preferredColorScheme(.dark)
        .sheet(item: $workspace.renaming) { session in
            RenameSheet(title: "重命名会话", initial: session.displayName) { name in
                workspace.rename(session, to: name)
            }
        }
        .sheet(item: $workspace.resumeRequest) { request in
            ResumeConversationView(request: request)
        }
        .sheet(isPresented: $workspace.managingAgents) {
            AgentManagerView()
        }
        .sheet(item: $workspace.editingHost) { host in
            HostEditor(host: host, isNew: !workspace.hosts.contains { $0.id == host.id }) { saved, password in
                if let password { HostKeychain.setPassword(password, for: saved.id, label: saved.name) }
                workspace.saveHost(saved)
            }
        }
        .sheet(item: $workspace.pickingSessionFor) { host in
            RemoteSessionPicker(host: host) { name in workspace.connect(host, sessionName: name) }
        }
    }
}

/// Hosts the selected session's split tree. All sessions keep running in the
/// background; only the selected one is in the view hierarchy.
struct SessionHost: NSViewRepresentable {
    @ObservedObject var session: AgentSession

    func makeNSView(context: Context) -> SessionContainerView { SessionContainerView() }

    func updateNSView(_ view: SessionContainerView, context: Context) {
        view.show(session)
    }
}

final class SessionContainerView: NSView {
    private weak var session: AgentSession?
    private var builtSignature = ""
    private var builtVersion = -1

    override var isFlipped: Bool { false }

    func show(_ session: AgentSession) {
        let sig = session.root.signature + "|zoom:\(session.zoomedPane.map { ObjectIdentifier($0).hashValue } ?? 0)"
        let sameSession = self.session === session
        guard !sameSession || sig != builtSignature || session.layoutVersion != builtVersion else {
            session.updateDimming()
            return
        }
        self.session = session
        builtSignature = sig
        builtVersion = session.layoutVersion
        rebuild(session)
        if !sameSession || window?.firstResponder !== session.focusedPane?.terminal {
            let target = session.focusedPane ?? session.panes.first
            DispatchQueue.main.async { target?.terminal.focus() }
        }
    }

    private func rebuild(_ session: AgentSession) {
        subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        if let zoomed = session.zoomedPane {
            content = zoomed
        } else {
            content = build(session.root)
        }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        session.updateDimming()
    }

    private func build(_ node: PaneNode) -> NSView {
        if let pane = node.pane {
            pane.removeFromSuperview()
            return pane
        }
        let split = PaneSplitView(horizontal: node.horizontal, ratio: node.ratio,
                                  first: build(node.children[0]), second: build(node.children[1]))
        split.onRatioChange = { [weak node] r in node?.ratio = r }
        node.splitView = split
        return split
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有会话").font(.title3)
            HStack {
                ForEach(catalog.visible) { kind in
                    Button {
                        NewSessionPanel.present(kind: kind, in: workspace)
                    } label: {
                        Label(kind.name, systemImage: kind.symbol)
                    }
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small "name it" sheet used for sessions and groups.
struct RenameSheet: View {
    let title: String
    let initial: String
    let onDone: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("名称", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("好", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = initial }
    }

    private func commit() {
        onDone(text)
        dismiss()
    }
}

extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
