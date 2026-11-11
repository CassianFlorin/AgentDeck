#if DEBUG
import AppKit

/// Debug-only remote control, so UI can be exercised without synthetic
/// keystrokes (which land in whatever app is frontmost). Post a distributed
/// notification named "AgentDeckDebug" whose object is a command string:
///
///   binding:<ghostty action>   e.g. binding:new_split:right, binding:scroll_to_top
///   paste:<text>               bracketed-paste text into the focused pane
///   type:<text>                type text as keystrokes into the focused pane (\n = Return)
///   pastefrom:<pasteboard>     paste from a named pasteboard (files → paths, image → saved PNG path)
///   find:<text>                open the find bar with this text
///   session:<n>                select session n (1-based, sidebar order)
///   dump                       write sessions/split trees to ~/Library/Caches/AgentDeck/debug.log
///
/// From a shell:
///   swift -e 'import Foundation; DistributedNotificationCenter.default()
///     .postNotificationName(.init("AgentDeckDebug"), object: "find:login",
///     userInfo: nil, deliverImmediately: true)'
@MainActor
enum DebugHooks {
    private static var token: NSObjectProtocol?

    static func install(_ workspace: Workspace) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(
            forName: .init("AgentDeckDebug"), object: nil, queue: .main
        ) { [weak workspace] note in
            guard let cmd = note.object as? String else { return }
            MainActor.assumeIsolated { workspace.map { run(cmd, in: $0) } }
        }
    }

    /// Appends to ~/Library/Caches/AgentDeck/debug.log
    static func log(_ msg: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/debug.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((msg + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    private static func run(_ cmd: String, in workspace: Workspace) {
        let (verb, arg) = cmd.firstIndex(of: ":").map {
            (String(cmd[..<$0]), String(cmd[cmd.index(after: $0)...]))
        } ?? (cmd, "")
        let pane = workspace.selected?.focusedPane
        switch verb {
        case "binding": pane?.terminal.performBindingAction(arg)
        case "paste": pane?.terminal.insertPasteText(arg.replacingOccurrences(of: "\\n", with: "\r"))
        case "type": pane?.terminal.typeText(arg.replacingOccurrences(of: "\\n", with: "\r"))
        case "pastefrom":
            // Same conversion as ⌘V, but from a named pasteboard so tests
            // don't clobber the user's clipboard.
            if let text = PasteboardText.read(NSPasteboard(name: .init(arg))) { pane?.terminal.insertPasteText(text) }
        case "dump":
            for (i, sess) in workspace.orderedSessions.enumerated() {
                log("\(i + 1) \(sess.displayName) panes=\(sess.panes.count) zoom=\(sess.zoomedPane != nil) tree=\(sess.root.signature)")
            }
        case "find": pane?.showSearch(needle: arg)
        case "session": workspace.gotoSession(Int32(arg) ?? 1)
        default: NSLog("AgentDeckDebug: unknown command %@", cmd)
        }
    }
}
#endif
