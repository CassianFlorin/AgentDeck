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

    /// ~/Library/Application Support/AgentDeck (or $AGENTDECK_HOME/support)
    static var support: URL {
        dir(override?.appendingPathComponent("support")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentDeck"))
    }

    /// ~/Library/Caches/AgentDeck (or $AGENTDECK_HOME/cache)
    static var cache: URL {
        dir(override?.appendingPathComponent("cache")
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentDeck"))
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
