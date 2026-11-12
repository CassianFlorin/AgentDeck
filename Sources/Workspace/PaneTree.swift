import AppKit
import GhosttyKit

/// A binary split tree. Leaves hold a pane; branches hold two children laid
/// out side by side (`horizontal`) or stacked, with `ratio` for the first child.
final class PaneNode {
    weak var parent: PaneNode?
    private(set) var pane: PaneView?
    private(set) var children: [PaneNode] = []
    var horizontal = true
    var ratio: CGFloat = 0.5
    /// The split view currently rendering this branch (for size-aware resizing).
    weak var splitView: PaneSplitView?

    init(pane: PaneView) { self.pane = pane }
    private init() {}

    var isLeaf: Bool { pane != nil }

    /// Leaves in reading order (left→right, top→bottom).
    var leaves: [PaneView] {
        if let pane { return [pane] }
        return children.flatMap(\.leaves)
    }

    func find(_ pane: PaneView) -> PaneNode? {
        if self.pane === pane { return self }
        for c in children { if let n = c.find(pane) { return n } }
        return nil
    }

    /// Replace this leaf with a branch holding the old pane and `newPane`.
    /// `before` puts the new pane on the left/top.
    func split(with newPane: PaneView, horizontal: Bool, before: Bool) {
        guard let old = pane else { return }
        let a = PaneNode(pane: old), b = PaneNode(pane: newPane)
        pane = nil
        self.horizontal = horizontal
        ratio = 0.5
        children = before ? [b, a] : [a, b]
        a.parent = self
        b.parent = self
    }

    /// Remove a leaf; its sibling takes the parent's place. Returns false if
    /// this was the root (the caller closes the whole session then).
    func removeLeaf(_ leaf: PaneNode) -> Bool {
        guard let parent = leaf.parent, let sibling = parent.children.first(where: { $0 !== leaf }) else { return false }
        parent.pane = sibling.pane
        parent.children = sibling.children
        parent.horizontal = sibling.horizontal
        parent.ratio = sibling.ratio
        parent.children.forEach { $0.parent = parent }
        return true
    }

    /// Split ratios proportional to leaf count, so N panes in a row are equal.
    func equalize() {
        guard children.count == 2 else { return }
        let a = children[0].count(alongHorizontal: horizontal)
        let b = children[1].count(alongHorizontal: horizontal)
        ratio = CGFloat(a) / CGFloat(a + b)
        children.forEach { $0.equalize() }
    }

    private func count(alongHorizontal h: Bool) -> Int {
        if isLeaf { return 1 }
        if horizontal == h { return children.reduce(0) { $0 + $1.count(alongHorizontal: h) } }
        return 1
    }

    /// Structure fingerprint; the host rebuilds views only when this changes.
    var signature: String {
        if let pane { return "L\(ObjectIdentifier(pane).hashValue)" }
        return "\(horizontal ? "H" : "V")(\(children.map(\.signature).joined(separator: ",")))"
    }

    // MARK: Persistence

    struct Layout: Codable {
        var directory: String?
        /// The session's first pane. (Named for when only that pane could run an agent.)
        var isAgent: Bool?
        /// The agent running in this pane, its conversation, and whether it was
        /// started at all, so each pane's agent comes back in its conversation.
        var agentID: String?
        var conversationID: String?
        var hadAgent: Bool?
        var horizontal: Bool?
        var ratio: Double?
        var children: [Layout]?
    }

    var layout: Layout {
        if let pane {
            var leaf = Layout(directory: pane.terminal.currentDirectory, isAgent: pane.isPrimary)
            // An agent we only noticed (typed by hand) is worth restoring only
            // if we know which conversation it was in.
            if let agent = pane.agent, !(agent.adopted && agent.conversationID == nil) {
                leaf.agentID = agent.kind.id
                leaf.conversationID = agent.conversationID
                leaf.hadAgent = true
            }
            return leaf
        }
        return Layout(horizontal: horizontal, ratio: Double(ratio), children: children.map(\.layout))
    }

    /// The saved leaf of the session's first pane.
    static func primaryLeaf(of layout: Layout) -> Layout? {
        if let kids = layout.children, kids.count == 2 {
            return kids.lazy.compactMap(primaryLeaf(of:)).first
        }
        return layout.isAgent == true ? layout : nil
    }

    /// Rebuild a tree from a saved layout, creating panes with `make`.
    static func restore(_ layout: Layout, make: (Layout) -> PaneView) -> PaneNode {
        if let kids = layout.children, kids.count == 2 {
            let node = PaneNode()
            node.horizontal = layout.horizontal ?? true
            node.ratio = CGFloat(layout.ratio ?? 0.5)
            node.children = kids.map { restore($0, make: make) }
            node.children.forEach { $0.parent = node }
            return node
        }
        return PaneNode(pane: make(layout))
    }
}

/// Two views with a draggable divider. Custom rather than NSSplitView so the
/// ratio is exact and the divider is a thin line that still has a fat hit area.
final class PaneSplitView: NSView {
    let horizontal: Bool
    var ratio: CGFloat { didSet { needsLayout = true } }
    var onRatioChange: ((CGFloat) -> Void)?

    private let first: NSView
    private let second: NSView
    private let divider = PassthroughView()
    private let thickness: CGFloat = 1
    private let grab: CGFloat = 6
    private var dragging = false

    init(horizontal: Bool, ratio: CGFloat, first: NSView, second: NSView) {
        self.horizontal = horizontal
        self.ratio = ratio
        self.first = first
        self.second = second
        super.init(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        for v in [first, second] {
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = []
            addSubview(v)
        }
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private var length: CGFloat { horizontal ? bounds.width : bounds.height }

    override func layout() {
        super.layout()
        let avail = max(length - thickness, 0)
        let a = (avail * ratio).rounded()
        if horizontal {
            first.frame = NSRect(x: 0, y: 0, width: a, height: bounds.height)
            divider.frame = NSRect(x: a, y: 0, width: thickness, height: bounds.height)
            second.frame = NSRect(x: a + thickness, y: 0, width: avail - a, height: bounds.height)
        } else {
            // AppKit is bottom-up; the first child goes on top.
            first.frame = NSRect(x: 0, y: bounds.height - a, width: bounds.width, height: a)
            divider.frame = NSRect(x: 0, y: bounds.height - a - thickness, width: bounds.width, height: thickness)
            second.frame = NSRect(x: 0, y: 0, width: bounds.width, height: avail - a)
        }
    }

    private var grabRect: NSRect { divider.frame.insetBy(dx: horizontal ? -grab : 0, dy: horizontal ? 0 : -grab) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if grabRect.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(grabRect, cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) { dragging = true }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, length > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let pos = horizontal ? p.x : bounds.height - p.y
        let minPane: CGFloat = 60
        let clamped = min(max(pos, minPane), length - minPane)
        ratio = clamped / length
        onRatioChange?(ratio)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    /// Move the divider by `delta` points (positive = right/down).
    func nudge(by delta: CGFloat) {
        guard length > 0 else { return }
        let minR = 60 / length, maxR = 1 - minR
        ratio = min(max(ratio + delta / length, minR), maxR)
        onRatioChange?(ratio)
    }
}
