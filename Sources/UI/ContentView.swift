import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let session = workspace.selected {
                TerminalHost(session: session)
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
    }
}

/// Hosts the selected session's terminal view. All sessions keep running
/// in the background; only the selected one is in the view tree.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: AgentSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let term = session.terminal
        guard term.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        term.frame = container.bounds
        term.autoresizingMask = [.width, .height]
        container.addSubview(term)
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
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

extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
