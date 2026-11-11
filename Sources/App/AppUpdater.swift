import AppKit
import Combine
import Sparkle

/// In-app updates through Sparkle. The feed is `appcast.xml` on the latest
/// GitHub Release (Info.plist `SUFeedURL`). Each update ZIP is EdDSA-signed by
/// CI, and Sparkle also checks that the new app has the same Developer ID
/// signature as this one.
///
/// Debug builds don't start the updater (they would replace a dev build
/// with a release one) unless `AGENTDECK_UPDATER=1` is set, for testing.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    /// Lets the update prompt know whether agents are mid-turn.
    weak var workspace: Workspace?
    @Published private(set) var canCheckForUpdates = false
    let isEnabled: Bool
    private var controller: SPUStandardUpdaterController?

    private override init() {
        #if DEBUG
        isEnabled = ProcessInfo.processInfo.environment["AGENTDECK_UPDATER"] == "1"
        #else
        isEnabled = true
        #endif
        super.init()
        guard isEnabled else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    /// `AGENTDECK_UPDATE_FEED` points the updater at another feed, for testing
    /// against a local server. The feed and the update still have to be
    /// signed with the key in Info.plist.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["AGENTDECK_UPDATE_FEED"]
    }

    /// Relaunching kills every terminal. Sessions, splits and conversations
    /// come back, but an agent mid-turn loses that turn, so ask first.
    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            let busy = (workspace?.sessions ?? []).filter {
                switch $0.activity {
                case .working, .waiting: return true
                default: return false
                }
            }
            guard !busy.isEmpty else { return false }

            let alert = NSAlert()
            alert.messageText = "现在重启以完成更新？"
            alert.informativeText = """
                有 \(busy.count) 个 Agent 正在运行或等你回复，重启会中断它们当前这一轮。\
                会话、分屏和对话在重启后会恢复。
                也可以先继续工作，退出 AgentDeck 时会自动安装更新。
                """
            alert.addButton(withTitle: "退出时再安装")
            alert.addButton(withTitle: "立即重启")
            if alert.runModal() == .alertSecondButtonReturn {
                installHandler()
            }
            // Not invoking the handler leaves the update staged; Sparkle
            // installs it when the app quits.
            return true
        }
    }
}
