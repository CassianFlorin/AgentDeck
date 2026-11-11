import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let session = workspace.selected {
                SessionHost(session: session)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .navigationTitle(session.displayName)
                    .navigationSubtitle(session.directory.abbreviatingHome)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NewSessionMenu() }
        }
        .sheet(item: $workspace.renaming) { session in
            RenameSheet(title: "重命名会话", initial: session.displayName) { name in
                workspace.rename(session, to: name)
            }
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有会话").font(.title3)
            HStack {
                ForEach(AgentKind.builtIn) { kind in
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
