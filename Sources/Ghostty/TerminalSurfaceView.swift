import AppKit
import GhosttyKit

/// An NSView backed by one libghostty surface (one pty + renderer).
///
/// libghostty attaches its own CAMetalLayer to this view and renders on its
/// own thread; this class only forwards input, size, focus and IME state.
/// Key and IME handling is adapted from Ghostty's SurfaceView_AppKit.swift (MIT).
final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?

    // Events for the owning session. Always delivered on the main thread.
    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var onAttention: ((String?) -> Void)?
    var onCommandFinished: ((Int16) -> Void)?
    var onChildExited: ((Int32) -> Void)?
    var onCloseRequested: ((Bool) -> Void)?
    var onFocus: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    /// Non-nil only while inside keyDown; collects text committed by the IME.
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?
    private var contentSize: CGSize = .zero

    static func from(userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// - Parameters:
    ///   - workingDirectory: where the shell starts.
    ///   - initialInput: typed into the shell once it is up (e.g. "claude\n").
    ///     We start the user's login shell and *type* the agent command rather
    ///     than exec'ing the agent directly, so that when the agent exits you
    ///     land back in a normal shell with shell integration intact.
    init(workingDirectory: String?, initialInput: String?, env: [String: String] = [:]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        createSurface(workingDirectory: workingDirectory, initialInput: initialInput, env: env)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    private func createSurface(workingDirectory: String?, initialInput: String?, env: [String: String]) {
        guard let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // C strings must outlive ghostty_surface_new; free them right after.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafeMutablePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return p
        }
        defer { owned.forEach { free($0) } }

        if let workingDirectory { cfg.working_directory = UnsafePointer(c(workingDirectory)) }
        if let initialInput { cfg.initial_input = UnsafePointer(c(initialInput)) }

        var envVars = env.map { ghostty_env_var_s(key: UnsafePointer(c($0.key)), value: UnsafePointer(c($0.value))) }
        envVars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            surface = ghostty_surface_new(app, &cfg)
        }
        if surface == nil { NSLog("AgentDeck: ghostty_surface_new failed") }
    }

    // MARK: - Lifecycle / layout

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, true)
            onFocus?()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        if let window {
            ghostty_surface_set_occlusion(surface, true)
            if let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                ghostty_surface_set_display_id(surface, id.uint32Value)
            }
            updateScale()
            sizeDidChange(frame.size)
        } else {
            // Not on screen (another session is selected): let the renderer idle.
            ghostty_surface_set_occlusion(surface, false)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateScale()
        sizeDidChange(contentSize)
    }

    private func updateScale() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
    }

    private func sizeDidChange(_ size: CGSize) {
        contentSize = size
        guard let surface, size.width > 0, size.height > 0 else { return }
        let px = convertToBacking(size)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    private var cellSize: CGSize {
        guard let surface else { return CGSize(width: 8, height: 16) }
        let s = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(s.cell_width_px) / scale, height: CGFloat(s.cell_height_px) / scale)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        cursor.set()
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, Self.mods(event.modifierFlags))
    }

    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) {
        mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE) }
    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func mouseExited(with event: NSEvent) {
        // Tell Ghostty the cursor left so hover links reset.
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }

        // Packed struct, see src/input/mouse.zig: bit 0 precision, bits 1-3 momentum.
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        let mods: ghostty_input_scroll_mods_t = (precise ? 1 : 0) | (momentum << 1)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Keyboard

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    private func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                          translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.text = nil
        k.composing = false
        k.mods = Self.mods(event.modifierFlags)
        // Heuristic from Ghostty: ctrl and cmd never contribute to text translation.
        k.consumed_mods = Self.mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        k.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            k.unshifted_codepoint = cp.value
        }
        return k
    }

    /// Text for a key event, minus control chars / function-key PUA codepoints
    /// (libghostty encodes those itself).
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    @discardableResult
    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent,
                           translationEvent: NSEvent? = nil, text: String? = nil,
                           composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var k = keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        k.composing = composing
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                k.text = ptr
                return ghostty_surface_key(surface, k)
            }
        }
        return ghostty_surface_key(surface, k)
    }

    /// Text committed by an IME, sent as a key event (never as a paste).
    @discardableResult
    private func committedText(_ text: String) -> Bool {
        guard let surface else { return false }
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS
        k.mods = GHOSTTY_MODS_NONE
        k.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            k.text = ptr
            return ghostty_surface_key(surface, k)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Respect option-as-alt etc. from the user's Ghostty config.
        let translated = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for f in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(f) { translationMods.insert(f) } else { translationMods.remove(f) }
        }
        // Must reuse the original event when unchanged, or Korean IME breaks.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let hadMarkedText = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: hadMarkedText)
        let composing = markedText.length > 0 || hadMarkedText

        if let list = keyTextAccumulator, !list.isEmpty {
            // IME committed text (e.g. pinyin candidate chosen).
            for text in list {
                if hadMarkedText {
                    committedText(text)
                } else {
                    keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            // While composing, keys belong to the IME, not the terminal.
            if composing { return }
            keyAction(action, event: event, translationEvent: translationEvent,
                      text: Self.ghosttyCharacters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let pressed = Self.mods(event.modifierFlags).rawValue & mod != 0
        keyAction(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// AppKit offers cmd/ctrl combos here before keyDown. If the combo is a
    /// Ghostty keybinding (cmd+c, cmd+v, cmd+t, ...) we take it; otherwise it
    /// falls through to the menu bar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface, window?.firstResponder === self else { return false }

        var k = keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            k.text = ptr
            return ghostty_surface_key_is_binding(surface, k, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        // ctrl+<key> (without cmd) should reach the terminal, e.g. ctrl+/ ctrl+enter.
        if event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command) {
            keyDown(with: event)
            return true
        }
        return false
    }

    override func doCommand(by selector: Selector) {
        // Swallow so unhandled selectors don't NSBeep.
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: - NSTextInputClient (IME: 中文 / 日本語 / 한국어)

extension TerminalSurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. layout switch mid-composition) sync right away.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window goes: at the terminal cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0
        var w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(x: x, y: frame.height - y, width: range.length == 0 ? 0 : w,
                              height: max(h, Double(cellSize.height)))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        if !chars.isEmpty { committedText(chars) }
    }
}
