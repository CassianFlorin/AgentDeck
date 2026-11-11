import AppKit
import GhosttyKit

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

    /// Asked to open a new session "like this one" (Ghostty's new_tab / new_window
    /// bindings, cmd+t / cmd+n by default).
    var onNewSessionRequested: ((TerminalSurfaceView?) -> Void)?

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

        // Reuse the user's existing Ghostty config (~/.config/ghostty/config etc.),
        // so fonts/themes/keybinds carry over for free.
        guard let cfg = ghostty_config_new() else { return false }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
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
                DispatchQueue.main.async { view.onCloseRequested?(processAlive) }
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

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: - Actions

    private static func surfaceView(_ target: ghostty_target_s) -> TerminalSurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return TerminalSurfaceView.from(userdata: ghostty_surface_userdata(surface))
    }

    /// Return true when the action was handled. Unhandled actions fall back to
    /// libghostty's defaults (or are ignored).
    private static func handleAction(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = surfaceView(target)

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view else { return false }
            let title = String(cString: action.action.set_title.title)
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view else { return false }
            let pwd = String(cString: action.action.pwd.pwd)
            DispatchQueue.main.async { view.onPwdChange?(pwd) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            guard let view else { return false }
            DispatchQueue.main.async { view.onAttention?(nil) }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // Claude Code / Codex use OSC 9 / OSC 777 to say "I need you".
            guard let view else { return false }
            let n = action.action.desktop_notification
            let title = String(cString: n.title)
            let body = String(cString: n.body)
            let text = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
            DispatchQueue.main.async { view.onAttention?(text.isEmpty ? nil : text) }
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let view else { return false }
            let code = action.action.command_finished.exit_code
            DispatchQueue.main.async { view.onCommandFinished?(code) }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let view else { return false }
            let code = action.action.child_exited.exit_code
            DispatchQueue.main.async { view.onChildExited?(Int32(code)) }
            return true

        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_NEW_SPLIT:
            DispatchQueue.main.async { GhosttyRuntime.shared.onNewSessionRequested?(view) }
            return true

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
            return false
        }
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

        // Text only for now. Image paste (for agents that accept screenshots)
        // is a natural next step.
        var wanted: String?
        for i in 0..<mimesLen {
            let m = String(cString: mimes[i])
            if isPlainText(m) { wanted = m; break }
        }
        guard let mime = wanted, let text = pb.string(forType: .string) else {
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
