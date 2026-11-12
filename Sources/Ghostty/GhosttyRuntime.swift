import AppKit
import GhosttyKit
import SwiftUI

/// Everything libghostty tells a surface that AgentDeck cares about.
/// Delivered on the main thread via `TerminalSurfaceView.onEvent`.
enum TerminalEvent {
    // Pane-level state
    case title(String)
    case pwd(String)
    case attention(String?)
    case commandFinished(Int16)
    case childExited(Int32)
    case closeRequested(processAlive: Bool)
    case focused

    // Search / scrollback (handled by the pane)
    case startSearch(needle: String?)
    case endSearch
    case searchTotal(Int)
    case searchSelected(Int)
    case scrollbar(total: UInt64, offset: UInt64, length: UInt64)

    // Agent activity signals
    /// Plain Return pressed in this pane.
    case userSubmitted
    /// OSC 9;4 progress (some agents report "busy" this way).
    case progress(ghostty_action_progress_report_state_e)

    // Splits (handled by the session)
    case newSplit(ghostty_action_split_direction_e)
    case gotoSplit(ghostty_action_goto_split_e)
    case resizeSplit(ghostty_action_resize_split_direction_e, amount: UInt16)
    case equalizeSplits
    case toggleZoom

    // Sessions = tabs (handled by the workspace)
    case newSession
    case gotoSession(Int32)
    case moveSession(Int)
    case closeSession
    case renameSession
}

/// Owns the single `ghostty_app_t` for the process and routes libghostty's
/// C callbacks back into Swift.
///
/// libghostty is the terminal engine from Ghostty (https://ghostty.org, MIT).
/// The callback plumbing here is adapted from Ghostty's own macOS app
/// (macos/Sources/Ghostty/Ghostty.App.swift), trimmed to what AgentDeck needs.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    /// Events whose target is the app rather than a surface (e.g. cmd+t with
    /// no terminal focused).
    var onAppEvent: ((TerminalEvent) -> Void)?

    private init() {}

    /// Must be called once, before any surface is created.
    @discardableResult
    func start() -> Bool {
        if app != nil { return true }

        // libghostty finds shell-integration, terminfo and themes through this.
        // The build phase copies them into Contents/Resources/ghostty.
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
           FileManager.default.fileExists(atPath: res.path) {
            setenv("GHOSTTY_RESOURCES_DIR", res.path, 0)
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("AgentDeck: ghostty_init failed")
            return false
        }

        // `ghostty +ssh`, `ghostty +list-themes`, … Shell integration calls
        // "$GHOSTTY_BIN_DIR/ghostty" (a symlink to us, see project.yml); when
        // launched that way libghostty runs the CLI action and exits here.
        ghostty_cli_try_action()

        // Reuse the user's existing Ghostty config (~/.config/ghostty/config etc.),
        // so fonts/themes/keybinds carry over for free.
        guard let cfg = Self.makeConfig() else { return false }
        let diagnostics = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diagnostics {
            let d = ghostty_config_get_diagnostic(cfg, i)
            NSLog("AgentDeck: ghostty config: %@", String(cString: d.message))
        }
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                // May arrive on any thread; ticking must happen on main.
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { ud, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(ud, location: location, state: state,
                                             mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(ud, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { ud, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(ud, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { ud, processAlive in
                guard let view = TerminalSurfaceView.from(userdata: ud) else { return }
                DispatchQueue.main.async { view.onEvent?(.closeRequested(processAlive: processAlive)) }
            }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("AgentDeck: ghostty_app_new failed")
            return false
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp?.isActive ?? true)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
        return true
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Config

    /// The user's Ghostty config, then AgentDeck's overlay on top: the options
    /// changed in 设置 → 终端, then background opacity / blur from 设置 → 外观
    /// (last, so the glass window always gets the opacity it needs).
    private static func makeConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        let overlay = AppPaths.support.appendingPathComponent("ghostty-appearance.conf")
        let text = TerminalSettings.ghosttyOverlay + "\n" + AppearanceSettings.ghosttyOverlay
        try? text.write(to: overlay, atomically: true, encoding: .utf8)
        overlay.path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// The user's own Ghostty config without AgentDeck's overlay. Caller frees it.
    static func userConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// A scalar config value (Bool, Float for f32 keys, Double for f64 keys…).
    static func value<T>(_ cfg: ghostty_config_t, _ key: String) -> T? where T: ExpressibleByBooleanLiteral {
        var v: T = false
        return ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)) ? v : nil
    }

    static func value<T>(_ cfg: ghostty_config_t, _ key: String) -> T? where T: BinaryFloatingPoint {
        var v: T = 0
        return ghostty_config_get(cfg, &v, key, UInt(key.utf8.count)) ? v : nil
    }

    /// A string or enum config value.
    static func string(_ cfg: ghostty_config_t, _ key: String) -> String? {
        var ptr: UnsafePointer<CChar>?
        guard ghostty_config_get(cfg, &ptr, key, UInt(key.utf8.count)), let ptr else { return nil }
        return String(cString: ptr)
    }

    /// Open the user's Ghostty config file (libghostty creates it if missing).
    static func openUserConfig() {
        let s = ghostty_config_open_path()
        defer { ghostty_string_free(s) }
        guard let ptr = s.ptr else { return }
        let path = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(s.len)), as: UTF8.self)
        let url = URL(fileURLWithPath: path)
        // Plain-text files without an extension have no default app; use TextEdit.
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil,
           let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Background, foreground and the 16 ANSI colors currently in effect.
    func currentColors() -> (background: Color, foreground: Color, palette: [Color]) {
        var palette = [Color](repeating: .gray, count: 16)
        guard let config else { return (.black, .white, palette) }
        func color(_ key: String) -> Color? {
            var c = ghostty_config_color_s()
            return ghostty_config_get(config, &c, key, UInt(key.utf8.count)) ? Color(c) : nil
        }
        var p = ghostty_config_palette_s()
        let key = "palette"
        if ghostty_config_get(config, &p, key, UInt(key.utf8.count)) {
            withUnsafeBytes(of: &p.colors) { raw in
                let colors = raw.bindMemory(to: ghostty_config_color_s.self)
                for i in 0..<16 { palette[i] = Color(colors[i]) }
            }
        }
        return (color("background") ?? .black, color("foreground") ?? .white, palette)
    }

    /// Re-read config after an appearance change; libghostty pushes it to every surface.
    func reloadAppearance() {
        guard let app, let cfg = Self.makeConfig() else { return }
        ghostty_app_update_config(app, cfg)
        let old = config
        config = cfg
        if let old { ghostty_config_free(old) }
    }

    /// Blur what's behind a translucent window (radius from `background-blur`).
    func applyBackgroundBlur(to window: NSWindow) {
        guard let app else { return }
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    /// The terminal's `background` color.
    var backgroundColor: NSColor {
        var color = ghostty_config_color_s()
        let key = "background"
        guard let config, ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else {
            return NSColor(white: 0.08, alpha: 1)
        }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                       blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// Overlay for unfocused splits, from the user's Ghostty config
    /// (`unfocused-split-fill`, falling back to `background`; `unfocused-split-opacity`).
    var unfocusedSplitOverlay: NSColor {
        guard let config else { return NSColor.black.withAlphaComponent(0.3) }
        var opacity: Double = 0.85
        let okey = "unfocused-split-opacity"
        _ = ghostty_config_get(config, &opacity, okey, UInt(okey.utf8.count))
        var color = ghostty_config_color_s()
        let fkey = "unfocused-split-fill"
        if !ghostty_config_get(config, &color, fkey, UInt(fkey.utf8.count)) {
            let bkey = "background"
            _ = ghostty_config_get(config, &color, bkey, UInt(bkey.utf8.count))
        }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                       blue: CGFloat(color.b) / 255, alpha: CGFloat(1 - opacity))
    }

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: - Actions

    private static func surfaceView(_ target: ghostty_target_s) -> TerminalSurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return TerminalSurfaceView.from(userdata: ghostty_surface_userdata(surface))
    }

    /// Translate a libghostty action into a TerminalEvent, or nil if we don't handle it.
    private static func event(for action: ghostty_action_s) -> TerminalEvent? {
        let a = action.action
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE: return .title(String(cString: a.set_title.title))
        case GHOSTTY_ACTION_PWD: return .pwd(String(cString: a.pwd.pwd))
        case GHOSTTY_ACTION_RING_BELL: return .attention(nil)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // Claude Code / Codex use OSC 9 / OSC 777 to say "I need you".
            let text = [String(cString: a.desktop_notification.title),
                        String(cString: a.desktop_notification.body)]
                .filter { !$0.isEmpty }.joined(separator: " — ")
            return .attention(text.isEmpty ? nil : text)
        case GHOSTTY_ACTION_COMMAND_FINISHED: return .commandFinished(a.command_finished.exit_code)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED: return .childExited(Int32(a.child_exited.exit_code))

        case GHOSTTY_ACTION_START_SEARCH:
            let needle = String(cString: a.start_search.needle)
            return .startSearch(needle: needle.isEmpty ? nil : needle)
        case GHOSTTY_ACTION_END_SEARCH: return .endSearch
        case GHOSTTY_ACTION_SEARCH_TOTAL: return .searchTotal(Int(a.search_total.total))
        case GHOSTTY_ACTION_SEARCH_SELECTED: return .searchSelected(Int(a.search_selected.selected))
        case GHOSTTY_ACTION_SCROLLBAR:
            let s = a.scrollbar
            return .scrollbar(total: s.total, offset: s.offset, length: s.len)

        case GHOSTTY_ACTION_PROGRESS_REPORT: return .progress(a.progress_report.state)

        case GHOSTTY_ACTION_NEW_SPLIT: return .newSplit(a.new_split)
        case GHOSTTY_ACTION_GOTO_SPLIT: return .gotoSplit(a.goto_split)
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            return .resizeSplit(a.resize_split.direction, amount: a.resize_split.amount)
        case GHOSTTY_ACTION_EQUALIZE_SPLITS: return .equalizeSplits
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: return .toggleZoom

        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW: return .newSession
        case GHOSTTY_ACTION_GOTO_TAB: return .gotoSession(a.goto_tab.rawValue)
        case GHOSTTY_ACTION_MOVE_TAB: return .moveSession(Int(a.move_tab.amount))
        // cmd+shift+w / cmd+alt+w in Ghostty's defaults close the window/tab;
        // here the closest equivalent is closing the whole session.
        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW: return .closeSession
        case GHOSTTY_ACTION_PROMPT_TITLE: return .renameSession
        default: return nil
        }
    }

    /// Return true when the action was handled. Unhandled actions fall back to
    /// libghostty's defaults (or are ignored).
    private static func handleAction(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = surfaceView(target)

        // Actions that need no session context.
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.setMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            let data = Data(bytes: u.url, count: Int(u.len))
            guard let str = String(data: data, encoding: .utf8) else { return false }
            let url = URL(string: str) ?? URL(fileURLWithPath: str)
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        default:
            break
        }

        guard let event = event(for: action) else { return false }
        DispatchQueue.main.async {
            if let view {
                view.deliver(event)
            } else {
                GhosttyRuntime.shared.onAppEvent?(event)
            }
        }
        return true
    }

    // MARK: - Clipboard

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        default: return nil
        }
    }

    private static func isPlainText(_ mime: String) -> Bool {
        mime == "text/plain" || mime.hasPrefix("text/plain;")
    }

    private static func readClipboard(
        _ ud: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer,
        mimes: UnsafePointer<UnsafePointer<CChar>>,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let view = TerminalSurfaceView.from(userdata: ud),
              let surface = view.surface,
              let pb = pasteboard(location) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        var wanted: String?
        for i in 0..<mimesLen {
            let m = String(cString: mimes[i])
            if isPlainText(m) { wanted = m; break }
        }
        guard let mime = wanted, let text = PasteboardText.read(pb) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        complete(surface, mime: mime, text: text, confirmed: false, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func complete(_ surface: ghostty_surface_t, mime: String, text: String,
                                 confirmed: Bool, state: UnsafeMutableRawPointer) {
        let bytes = Array(text.utf8)
        mime.withCString { mimePtr in
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(bytes.count, 1)) { dataPtr in
                    var content = ghostty_clipboard_content_s(mime: mimePtr, data: dataPtr, len: bytes.count)
                    withUnsafePointer(to: &content) { contentPtr in
                        var done = ghostty_clipboard_complete_s(
                            contents: contentPtr, contents_len: 1,
                            available: nil, available_len: 0,
                            confirmed: confirmed, remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &done, state)
                    }
                }
            }
        }
    }

    private static func confirmReadClipboard(
        _ ud: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
        state: UnsafeMutableRawPointer,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalSurfaceView.from(userdata: ud), let surface = view.surface else { return }

        // Programs reading the clipboard (OSC 52 read) are denied outright.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        // Unsafe paste (e.g. multi-line text that would execute immediately).
        var text = ""
        var mime = "text/plain"
        let c = confirm.pointee
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                let m = String(cString: item.mime)
                if isPlainText(m) {
                    mime = m
                    text = String(decoding: UnsafeRawBufferPointer(start: item.data, count: item.len), as: UTF8.self)
                    break
                }
            }
        }

        let alert = NSAlert()
        alert.messageText = "粘贴的内容可能会直接执行"
        alert.informativeText = String(text.prefix(600))
        alert.addButton(withTitle: "粘贴")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            complete(surface, mime: mime, text: text, confirmed: true, state: state)
        } else {
            ghostty_surface_deny_clipboard_request(surface, state)
        }
    }

    private static func writeClipboard(
        _ ud: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>,
        len: Int,
        confirm: Bool
    ) {
        // Writes that libghostty says need confirmation (OSC 52 from a program)
        // are dropped rather than silently overwriting the user's clipboard.
        guard !confirm, let pb = pasteboard(location) else { return }
        for i in 0..<len {
            let item = content[i]
            guard isPlainText(String(cString: item.mime)) else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: item.data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            return
        }
    }
}
