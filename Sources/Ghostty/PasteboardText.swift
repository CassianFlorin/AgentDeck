import AppKit

/// Turns whatever is on a pasteboard into text a terminal can take.
///
/// - Files (copied in Finder, or dragged in) become shell-escaped paths.
/// - Images (screenshots, copied images) are saved as PNG and pasted as a path.
///   Claude Code, Codex & co. pick up image paths typed into their prompt,
///   so this is how you hand an agent a screenshot.
/// - Otherwise plain text.
enum PasteboardText {
    static func read(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { shellEscape($0.path) }.joined(separator: " ")
        }
        if let text = pb.string(forType: .string) {
            return text
        }
        if let path = saveImage(from: pb) {
            return shellEscape(path)
        }
        return nil
    }

    /// Writes an image on the pasteboard to ~/Library/Caches/AgentDeck/pastes.
    static func saveImage(from pb: NSPasteboard) -> String? {
        let png: Data?
        if let data = pb.data(forType: .png) {
            png = data
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }

        let dir = AppPaths.cache.appendingPathComponent("pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("paste-\(fmt.string(from: Date())).png")
        do {
            try png.write(to: url, options: .atomic)
            return url.path
        } catch {
            NSLog("AgentDeck: failed to save pasted image: %@", error.localizedDescription)
            return nil
        }
    }

    /// Backslash-escape characters the shell would otherwise interpret.
    static func shellEscape(_ s: String) -> String {
        let special: Set<Character> = [" ", "\\", "(", ")", "[", "]", "{", "}", "<", ">", "'", "\"",
                                       "`", "!", "#", "$", "&", ";", "|", "*", "?", "\t", "~"]
        var out = ""
        for c in s {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
