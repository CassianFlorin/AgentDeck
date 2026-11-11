import AppKit
import GhosttyKit

/// One leaf of a session's split tree: a terminal plus the chrome that
/// belongs to it (search bar, scrollbar, unfocused dimming).
final class PaneView: NSView {
    let terminal: TerminalSurfaceView
    /// True for the pane that runs the session's agent (vs. extra shells).
    let isAgentPane: Bool

    /// Events the pane doesn't handle itself go up to the session.
    var onEvent: ((PaneView, TerminalEvent) -> Void)?

    private let searchBar = SearchBar()
    private let scroller = ScrollIndicator()
    private let dim = PassthroughView()
    private var scrollState: (total: UInt64, offset: UInt64, length: UInt64) = (0, 0, 0)

    var isDimmed = false {
        didSet { dim.isHidden = !isDimmed }
    }

    init(terminal: TerminalSurfaceView, isAgentPane: Bool) {
        self.terminal = terminal
        self.isAgentPane = isAgentPane
        super.init(frame: terminal.frame)

        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = [.width, .height]
        terminal.frame = bounds
        addSubview(terminal)

        dim.wantsLayer = true
        dim.layer?.backgroundColor = GhosttyRuntime.shared.unfocusedSplitOverlay.cgColor
        dim.frame = bounds
        dim.autoresizingMask = [.width, .height]
        dim.isHidden = true
        addSubview(dim)

        scroller.onScrollToRow = { [weak self] row in
            self?.terminal.performBindingAction("scroll_to_row:\(row)")
        }
        addSubview(scroller)

        searchBar.isHidden = true
        searchBar.onChange = { [weak self] text in
            // Empty needle cancels highlighting but keeps the bar open.
            self?.terminal.performBindingAction("search:\(text)")
        }
        searchBar.onNavigate = { [weak self] forward in
            self?.terminal.performBindingAction("navigate_search:\(forward ? "next" : "previous")")
        }
        searchBar.onClose = { [weak self] in
            self?.terminal.performBindingAction("end_search")
        }
        addSubview(searchBar)

        terminal.onEvent = { [weak self] event in self?.handle(event) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let w: CGFloat = 12
        scroller.frame = NSRect(x: bounds.maxX - w, y: 2, width: w, height: bounds.height - 4)
        let barSize = searchBar.fittingSize
        let barW = min(max(barSize.width, 320), bounds.width - 16)
        searchBar.frame = NSRect(x: bounds.maxX - barW - 12, y: bounds.maxY - barSize.height - 8,
                                 width: barW, height: barSize.height)
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .startSearch(let needle):
            showSearch(needle: needle)
        case .endSearch:
            searchBar.isHidden = true
            searchBar.reset()
            terminal.focus()
        case .searchTotal(let total):
            searchBar.total = total
        case .searchSelected(let selected):
            searchBar.selected = selected
        case .scrollbar(let total, let offset, let length):
            scrollState = (total, offset, length)
            updateScroller()
        default:
            onEvent?(self, event)
        }
    }

    // MARK: Search

    func showSearch(needle: String? = nil) {
        searchBar.isHidden = false
        needsLayout = true
        searchBar.begin(needle: needle)
    }

    // MARK: Scrollbar

    private func updateScroller() {
        let (total, offset, length) = scrollState
        scroller.update(total: total, offset: offset, length: length)
    }
}

/// Overlay scroll indicator: a capsule that appears while scrolling, fades
/// out, and can be dragged. Hidden = fully transparent to the mouse.
final class ScrollIndicator: NSView {
    var onScrollToRow: ((Int) -> Void)?

    private var total: UInt64 = 0, offset: UInt64 = 0, length: UInt64 = 0
    private var hideWork: DispatchWorkItem?
    private var dragAnchor: (y: CGFloat, offset: UInt64)?
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private var scrollable: Bool { total > length && length > 0 }

    func update(total: UInt64, offset: UInt64, length: UInt64) {
        let moved = offset != self.offset || total != self.total
        (self.total, self.offset, self.length) = (total, offset, length)
        needsDisplay = true
        if !scrollable { hide(now: true); return }
        // New output at the bottom shouldn't flash the bar; scrolling should.
        if moved && offset + length < total { flash() }
    }

    private var knobRect: NSRect {
        guard scrollable else { return .zero }
        let h = max(bounds.height * CGFloat(length) / CGFloat(total), 24)
        let travel = bounds.height - h
        let frac = CGFloat(offset) / CGFloat(total - length)   // 0 = top
        let w: CGFloat = hovering || dragAnchor != nil ? 8 : 6
        return NSRect(x: bounds.maxX - w - 2, y: travel * (1 - frac), width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard scrollable else { return }
        let r = knobRect
        NSColor.white.withAlphaComponent(hovering || dragAnchor != nil ? 0.55 : 0.4).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }

    func flash() {
        hideWork?.cancel()
        alphaValue = 1
        let work = DispatchWorkItem { [weak self] in self?.hide(now: false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func hide(now: Bool) {
        guard dragAnchor == nil, !hovering || !scrollable else { return }
        if now { alphaValue = 0; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }
    }

    // Only intercept the mouse while visible.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 && scrollable ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard scrollable else { return }
        hovering = true
        hideWork?.cancel()
        alphaValue = 1
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        flash()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if knobRect.insetBy(dx: -4, dy: 0).contains(p) {
            dragAnchor = (p.y, offset)
        } else {
            // Click in the track: page toward the click.
            let up = p.y > knobRect.midY
            let row = up ? Int(offset) - Int(length) : Int(offset) + Int(length)
            onScrollToRow?(min(max(row, 0), Int(total - length)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor, scrollable else { return }
        let p = convert(event.locationInWindow, from: nil)
        let travel = bounds.height - knobRect.height
        guard travel > 0 else { return }
        let rowsPerPoint = CGFloat(total - length) / travel
        let row = Int((CGFloat(anchor.offset) + (anchor.y - p.y) * rowsPerPoint).rounded())
        onScrollToRow?(min(max(row, 0), Int(total - length)))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        needsDisplay = true
        flash()
    }
}

/// A view that draws but never takes mouse events.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Find-in-terminal bar: ⌘F to open, Enter / ⇧Enter (or ⌘G / ⇧⌘G) to step, Esc to close.
final class SearchBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    var total: Int = -1 { didSet { updateCount() } }
    var selected: Int = -1 { didSet { updateCount() } }

    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let prev = NSButton()
    private let next = NSButton()
    private let close = NSButton()
    private var debounce: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        field.placeholderString = "搜索"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(fieldChanged)
        field.focusRingType = .none

        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        for (b, symbol, tip, sel) in [(prev, "chevron.up", "上一个 (⇧↩)", #selector(goPrev)),
                                      (next, "chevron.down", "下一个 (↩)", #selector(goNext)),
                                      (close, "xmark", "关闭 (Esc)", #selector(doClose))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            b.target = self
            b.action = sel
        }

        let stack = NSStackView(views: [field, count, prev, next, close])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func begin(needle: String?) {
        if let needle { field.stringValue = needle }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { onChange?(field.stringValue) }
    }

    func reset() {
        field.stringValue = ""
        total = -1
        selected = -1
    }

    private func updateCount() {
        if total < 0 { count.stringValue = ""; return }
        if total == 0 { count.stringValue = "无结果"; return }
        count.stringValue = selected >= 0 ? "\(selected + 1)/\(total)" : "\(total)"
    }

    @objc private func fieldChanged() {
        // Debounce a little so huge scrollbacks aren't searched per keystroke.
        debounce?.cancel()
        let text = field.stringValue
        let work = DispatchWorkItem { [weak self] in self?.onChange?(text) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let back = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onNavigate?(!back)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘G / ⇧⌘G while typing in the field.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "g",
           window?.firstResponder === field.currentEditor() {
            onNavigate?(!event.modifierFlags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func goPrev() { onNavigate?(false) }
    @objc private func goNext() { onNavigate?(true) }
    @objc private func doClose() { onClose?() }
}

