import SwiftUI

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace: Workspace

    init() {
        // When an agent hook runs us (AGENTDECK_HOOK), forward the event and exit.
        AgentHook.runIfRequested()
        // When ssh runs us as SSH_ASKPASS, answer and exit before any UI.
        Askpass.runIfRequested()
        // libghostty must be initialised before any surface exists.
        GhosttyRuntime.shared.start()
        _workspace = StateObject(wrappedValue: Workspace())
        // After the hook/askpass early exits: those runs must not touch Sparkle.
        _ = AppUpdater.shared
    }

    var body: some Scene {
        Window("AgentDeck", id: "main") {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(workspace.catalog)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    appDelegate.workspace = workspace
                    AppUpdater.shared.workspace = workspace
                    #if DEBUG
                    DebugHooks.install(workspace)
                    #endif
                    if workspace.sessions.isEmpty { workspace.restore() }
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands { AppCommands(workspace: workspace) }

        Settings {
            TabView {
                AppearanceSettingsView()
                    .tabItem { Label("外观", systemImage: "paintbrush") }
                TerminalSettingsView()
                    .tabItem { Label("终端", systemImage: "terminal") }
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// Menu bar. Terminal-ish commands are sent to the focused pane as Ghostty
/// binding actions, so menu and keyboard (incl. the user's own Ghostty
/// keybinds) go through exactly the same path.
struct AppCommands: Commands {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage(MonitorSettings.visibleKey) private var showMonitor = false

    /// Terminal commands need a terminal on screen.
    private var hasSession: Bool { workspace.selected != nil && !workspace.showingDashboard }

    private func act(_ action: String) {
        workspace.selected?.focusedPane?.terminal.performBindingAction(action)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isEnabled {
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .newItem) {
            // ⌘⇧1…9 follow the order in 管理 Agent.
            ForEach(Array(workspace.catalog.visible.prefix(9).enumerated()), id: \.element.id) { i, kind in
                Button("新建 \(kind.name)…") { NewSessionPanel.present(kind: kind, in: workspace) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .shift])
            }
            Divider()
            Button("恢复之前的对话…") { workspace.showResume() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("管理 Agent…") { workspace.managingAgents = true }
        }

        CommandGroup(after: .sidebar) {
            Button(showMonitor ? "隐藏性能监视器" : "显示性能监视器") { showMonitor.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("查找…") { act("start_search") }
                .keyboardShortcut("f", modifiers: .command).disabled(!hasSession)
            Button("查找下一个") { act("navigate_search:next") }
                .keyboardShortcut("g", modifiers: .command).disabled(!hasSession)
            Button("查找上一个") { act("navigate_search:previous") }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!hasSession)
            Button("用所选内容查找") { act("search_selection") }
                .keyboardShortcut("e", modifiers: .command).disabled(!hasSession)
            Divider()
            Button("滚动到顶部") { act("scroll_to_top") }
                .keyboardShortcut(.home, modifiers: .command).disabled(!hasSession)
            Button("滚动到底部") { act("scroll_to_bottom") }
                .keyboardShortcut(.end, modifiers: .command).disabled(!hasSession)
            Button("上一个提示符") { act("jump_to_prompt:-1") }
                .keyboardShortcut(.upArrow, modifiers: .command).disabled(!hasSession)
            Button("下一个提示符") { act("jump_to_prompt:1") }
                .keyboardShortcut(.downArrow, modifiers: .command).disabled(!hasSession)
            Button("清屏") { act("clear_screen") }
                .keyboardShortcut("k", modifiers: .command).disabled(!hasSession)
        }

        CommandMenu("窗格") {
            Group {
            Button("向右分屏") { act("new_split:right") }
                .keyboardShortcut("d", modifiers: .command)
            Button("向下分屏") { act("new_split:down") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("上一个窗格") { act("goto_split:previous") }
                .keyboardShortcut("[", modifiers: .command)
            Button("下一个窗格") { act("goto_split:next") }
                .keyboardShortcut("]", modifiers: .command)
            Button("放大 / 还原窗格") { act("toggle_split_zoom") }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("均分窗格") { act("equalize_splits") }
                .keyboardShortcut("=", modifiers: [.command, .control])
            Divider()
            Button("关闭窗格") { act("close_surface") }
                .keyboardShortcut("w", modifiers: .command)
            }
            .disabled(!hasSession)
        }

        CommandMenu("会话") {
            Button(workspace.showingDashboard ? "回到会话" : "Agent 总览") { workspace.showingDashboard.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("下一个会话") { workspace.gotoSession(-2) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个会话") { workspace.gotoSession(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("跳到等待中的会话") { workspace.selectNextNeedingAttention() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("重新连接") { workspace.selected.map(workspace.reconnect) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace.selected?.isDisconnected != true)
            Button("添加服务器…") { workspace.editingHost = RemoteHost(name: "", host: "") }
            Divider()
            Button("重命名会话…") { workspace.renaming = workspace.selected }
                .disabled(!hasSession)
            Button("关闭会话") { workspace.selected.map(workspace.close) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!hasSession)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AgentDeck is always dark: it sits on a (translucent) terminal background.
        NSApp.appearance = NSAppearance(named: .darkAqua)
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
