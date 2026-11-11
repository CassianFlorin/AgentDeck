import SwiftUI

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace: Workspace

    init() {
        // libghostty must be initialised before any surface exists.
        GhosttyRuntime.shared.start()
        _workspace = StateObject(wrappedValue: Workspace())
    }

    var body: some Scene {
        Window("AgentDeck", id: "main") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    appDelegate.workspace = workspace
                    if workspace.sessions.isEmpty { workspace.restore() }
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                ForEach(Array(AgentKind.builtIn.enumerated()), id: \.element.id) { i, kind in
                    Button("新建 \(kind.name)…") { NewSessionPanel.present(kind: kind, in: workspace) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .shift])
                }
            }
            CommandMenu("会话") {
                Button("下一个会话") { workspace.selectNext(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("上一个会话") { workspace.selectNext(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("跳到等待中的会话") { workspace.selectNextNeedingAttention() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Divider()
                Button("关闭会话") { workspace.selected.map(workspace.close) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(workspace.selected == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateColorScheme()
        DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in self?.updateColorScheme() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { workspace?.persist() }
    }

    private func updateColorScheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        GhosttyRuntime.shared.setColorScheme(dark: dark)
    }
}
