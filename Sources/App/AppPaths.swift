import Foundation

/// Where AgentDeck keeps its files.
///
/// Set `AGENTDECK_HOME=/some/dir` to run a fully isolated instance (its own
/// workspace, hosts, caches and debug channel) — e.g. for testing next to the
/// copy you are actually using:
///
///   open -n --env AGENTDECK_HOME=/tmp/ad-test build/.../AgentDeck.app
enum AppPaths {
    static let override: URL? = ProcessInfo.processInfo.environment["AGENTDECK_HOME"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// "AgentDeck" for the real app. A build with another bundle id (e.g. one
    /// made to test updates, which Sparkle relaunches without our environment)
    /// gets its own folders instead of the real workspace.
    private static let folderName: String = {
        let id = Bundle.main.bundleIdentifier ?? "com.cassianflorin.agentdeck"
        return id == "com.cassianflorin.agentdeck" ? "AgentDeck" : id
    }()

    /// ~/Library/Application Support/AgentDeck (or $AGENTDECK_HOME/support)
    static var support: URL {
        dir(override?.appendingPathComponent("support")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folderName))
    }

    /// ~/Library/Caches/AgentDeck (or $AGENTDECK_HOME/cache)
    static var cache: URL {
        dir(override?.appendingPathComponent("cache")
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folderName))
    }

    /// Distributed-notification name for DebugHooks; isolated instances get their own.
    static var debugChannel: String {
        ProcessInfo.processInfo.environment["AGENTDECK_DEBUG_CHANNEL"]
            ?? (override == nil ? "AgentDeckDebug" : "AgentDeckDebug.test")
    }

    private static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
