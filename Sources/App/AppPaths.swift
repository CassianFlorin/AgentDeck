import Foundation

/// Where Waitlight keeps its files.
///
/// Set `WAITLIGHT_HOME=/some/dir` to run a fully isolated instance (its own
/// workspace, hosts, caches and debug channel) — e.g. for testing next to the
/// copy you are actually using:
///
///   open -n --env WAITLIGHT_HOME=/tmp/ad-test build/.../Waitlight.app
enum AppPaths {
    static let override: URL? = ProcessInfo.processInfo.environment["WAITLIGHT_HOME"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The bundle id is still the one from when the app was called AgentDeck:
    /// changing it would lose preferences, saved SSH passwords and the update
    /// channel of every installed copy.
    static let bundleID = "com.cassianflorin.agentdeck"

    /// "Waitlight" for the real app. A build with another bundle id (e.g. one
    /// made to test updates, which Sparkle relaunches without our environment)
    /// gets its own folders instead of the real workspace.
    private static let isRealApp = (Bundle.main.bundleIdentifier ?? bundleID) == bundleID
    private static let folderName = isRealApp ? "Waitlight" : (Bundle.main.bundleIdentifier ?? bundleID)

    /// ~/Library/Application Support/Waitlight (or $WAITLIGHT_HOME/support)
    static var support: URL {
        dir(override?.appendingPathComponent("support") ?? standard(.applicationSupportDirectory))
    }

    /// ~/Library/Caches/Waitlight (or $WAITLIGHT_HOME/cache)
    static var cache: URL {
        dir(override?.appendingPathComponent("cache") ?? standard(.cachesDirectory))
    }

    private static let standardSupport = migrated(.applicationSupportDirectory)
    private static let standardCache = migrated(.cachesDirectory)

    private static func standard(_ base: FileManager.SearchPathDirectory) -> URL {
        base == .cachesDirectory ? standardCache : standardSupport
    }

    /// The folder under `base`, after moving the AgentDeck-era folder there
    /// once (only for the real app, and only if the new one doesn't exist yet).
    private static func migrated(_ base: FileManager.SearchPathDirectory) -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: base, in: .userDomainMask)[0]
        let url = root.appendingPathComponent(folderName)
        let legacy = root.appendingPathComponent("AgentDeck")
        if isRealApp, !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacy.path) {
            do { try fm.moveItem(at: legacy, to: url) } catch {
                NSLog("Waitlight: could not move %@ to %@: %@", legacy.path, url.path, error.localizedDescription)
            }
        }
        return url
    }

    /// Distributed-notification name for DebugHooks; isolated instances get their own.
    static var debugChannel: String {
        ProcessInfo.processInfo.environment["WAITLIGHT_DEBUG_CHANNEL"]
            ?? (override == nil ? "WaitlightDebug" : "WaitlightDebug.test")
    }

    private static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
