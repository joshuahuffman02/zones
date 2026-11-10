import AppKit
import ApplicationServices
import ZonesCore

/// Handles in the gap between snapped windows. Drag one to resize the windows on both sides together;
/// the zone line moves with it, so later snaps match.
///
/// A handle only exists where snapped windows sit on both sides of a zone line and nothing covers the gap,
/// so it never takes a click meant for something else.
final class GapHandles {
    private let store: Store
    private var panels: [String: HandlePanel] = [:]
    private var timer: Timer?
    private var drag: ActiveDrag?
    private let writer = FrameWriter()

    /// A zone line (column or row), or two windows next to each other with no zone line between them.
    enum Kind: Hashable {
        case column(Int), row(Int, Int)
        case free(vertical: Bool)

        var vertical: Bool {
            switch self {
            case .column: true
            case .row: false
            case .free(let v): v
            }
        }
    }

    struct Win: Hashable {
        let pid: pid_t
        let id: CGWindowID
        let frame: CGRect
        /// Front to back: 0 is the frontmost window.
        let order: Int

        static func == (a: Win, b: Win) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// A zone line with snapped windows on both sides. `a` is left or above, `b` is right or below.
    struct Divider {
        let screen: ZScreen
        let kind: Kind
        let rect: CGRect
        let a: [Win]
        let b: [Win]
        /// The facing edges: right or bottom of `a`, left or top of `b`.
        let edgeA: CGFloat
        let edgeB: CGFloat
        var key: String { "\(screen.key)|\(kind)|\(kind.vertical ? Int(rect.minY) : Int(rect.minX))|\(Int(edgeA))" }
    }

    private struct ActiveDrag {
        let divider: Divider
        let start: ZoneLayout
        let a: [(AXUIElement, CGRect)]
        let b: [(AXUIElement, CGRect)]
        var layout: ZoneLayout
    }

    init(store: Store) { self.store = store }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    /// Hidden while a window is being dragged or the editor is open.
    var paused = false { didSet { if paused { panels.values.forEach { $0.orderOut(nil) } } else { refresh() } } }

    // MARK: Finding gaps

    func refresh() {
        guard drag == nil else { return }
        guard store.gapResize, !paused else {
            panels.values.forEach { $0.orderOut(nil) }
            return
        }
        let wins = Self.onScreenWindows()
        var wanted: [String: Divider] = [:]
        for s in ZScreen.all {
            for d in dividers(on: s, windows: wins) { wanted[d.key] = d }
        }
        for (k, p) in panels where wanted[k] == nil {
            p.close()
            panels[k] = nil
        }
        for (k, d) in wanted {
            let p = panels[k] ?? HandlePanel(owner: self)
            panels[k] = p
            p.divider = d
            let f = Coords.toNS(d.rect)
            if p.frame != f { p.setFrame(f, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
        }
    }

    private func dividers(on s: ZScreen, windows: [Win]) -> [Divider] {
        let l = store.layout(for: s)
        let rects = store.rects(for: s)
        let mine = windows.filter { s.visibleAX.intersects($0.frame) }
        var out: [Divider] = []
        let tol: CGFloat = 6

        func add(_ kind: Kind, a: [Win], b: [Win], edgeA: CGFloat, edgeB: CGFloat, within: (CGFloat, CGFloat)? = nil) {
            let v = kind.vertical
            guard var ra = Self.span(a.map { v ? ($0.frame.minY, $0.frame.maxY) : ($0.frame.minX, $0.frame.maxX) }),
                  let rb = Self.span(b.map { v ? ($0.frame.minY, $0.frame.maxY) : ($0.frame.minX, $0.frame.maxX) }) else { return }
            if let w = within { ra = (max(ra.0, w.0), min(ra.1, w.1)) }
            let lo = max(ra.0, rb.0), hi = min(ra.1, rb.1)
            guard hi - lo > 40 else { return }
            let t = max(edgeB - edgeA, 8)
            let mid = (edgeA + edgeB) / 2
            let rect = v ? CGRect(x: mid - t / 2, y: lo, width: t, height: hi - lo)
                         : CGRect(x: lo, y: mid - t / 2, width: hi - lo, height: t)
            if Self.covered(rect, by: windows, neighbours: a + b) { return }
            out.append(Divider(screen: s, kind: kind, rect: rect, a: a, b: b, edgeA: edgeA, edgeB: edgeB))
        }

        // Zone lines between columns.
        for c in 0..<max(0, l.columns.count - 1) {
            let edgeA = rects[l.zoneIndex(column: c, row: 0)].maxX
            let edgeB = rects[l.zoneIndex(column: c + 1, row: 0)].minX
            add(.column(c), a: mine.filter { abs($0.frame.maxX - edgeA) < tol },
                b: mine.filter { abs($0.frame.minX - edgeB) < tol }, edgeA: edgeA, edgeB: edgeB)
        }
        // Zone lines between rows.
        for (c, col) in l.columns.enumerated() {
            for r in 0..<max(0, col.rows.count - 1) {
                let top = rects[l.zoneIndex(column: c, row: r)]
                let bottom = rects[l.zoneIndex(column: c, row: r + 1)]
                add(.row(c, r),
                    a: mine.filter { abs($0.frame.maxY - top.maxY) < tol && Self.overlap($0.frame, top, vertical: false) > 40 },
                    b: mine.filter { abs($0.frame.minY - bottom.minY) < tol && Self.overlap($0.frame, bottom, vertical: false) > 40 },
                    edgeA: top.maxY, edgeB: bottom.minY, within: (top.minX, top.maxX))
            }
        }

        // Any other two windows that touch or sit a small gap apart, like two stacked in one zone.
        for vertical in [true, false] {
            var pairs: [(Win, Win)] = []
            for a in mine {
                for b in mine where a != b {
                    let gap = vertical ? b.frame.minX - a.frame.maxX : b.frame.minY - a.frame.maxY
                    guard gap >= -2, gap <= 24, Self.overlap(a.frame, b.frame, vertical: vertical) > 40 else { continue }
                    pairs.append((a, b))
                }
            }
            // Group the pairs that share one line.
            var groups: [(CGFloat, [Win], [Win])] = []
            for (a, b) in pairs {
                let e = vertical ? a.frame.maxX : a.frame.maxY
                if let i = groups.firstIndex(where: { abs($0.0 - e) < tol }) {
                    if !groups[i].1.contains(a) { groups[i].1.append(a) }
                    if !groups[i].2.contains(b) { groups[i].2.append(b) }
                } else {
                    groups.append((e, [a], [b]))
                }
            }
            for (edgeA, a, b) in groups {
                let edgeB = b.map { vertical ? $0.frame.minX : $0.frame.minY }.min()!
                // Already handled by a zone line.
                if out.contains(where: { $0.kind.vertical == vertical && abs($0.edgeA - edgeA) < tol && !Set($0.a).isDisjoint(with: a) }) { continue }
                add(.free(vertical: vertical), a: a, b: b, edgeA: edgeA, edgeB: max(edgeB, edgeA))
            }
        }
        return out
    }

    private static func span(_ ranges: [(CGFloat, CGFloat)]) -> (CGFloat, CGFloat)? {
        guard !ranges.isEmpty else { return nil }
        return (ranges.map(\.0).min()!, ranges.map(\.1).max()!)
    }

    /// How much two rects overlap along the line: vertically for a vertical line, horizontally otherwise.
    private static func overlap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat {
        vertical ? min(a.maxY, b.maxY) - max(a.minY, b.minY) : min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    /// Something in front of the neighbours sits over the gap (a floating window, or a window spanning
    /// across the line). Windows behind them don't count.
    private static func covered(_ gap: CGRect, by windows: [Win], neighbours: [Win]) -> Bool {
        let back = neighbours.map(\.order).max() ?? Int.max
        let windows = windows.filter { $0.order < back && !neighbours.contains($0) }
        let probes = [CGPoint(x: gap.midX, y: gap.minY + 20), CGPoint(x: gap.midX, y: gap.midY), CGPoint(x: gap.midX, y: gap.maxY - 20),
                      CGPoint(x: gap.minX + 20, y: gap.midY), CGPoint(x: gap.maxX - 20, y: gap.midY)]
            .filter { gap.contains($0) }
        return windows.contains { w in probes.contains { w.frame.insetBy(dx: 1, dy: 1).contains($0) } }
    }

    /// Ordinary on-screen windows, front to back, from the window server. Cheap enough to poll.
    static func onScreenWindows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        return list.enumerated().compactMap { order, info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b),
                  frame.width > 60, frame.height > 60
            else { return nil }
            return Win(pid: pid, id: id, frame: frame, order: order)
        }
    }

    // MARK: Dragging

    fileprivate func begin(_ d: Divider) {
        drag = ActiveDrag(divider: d, start: store.layout(for: d.screen),
                          a: d.a.compactMap(Self.element), b: d.b.compactMap(Self.element),
                          layout: store.layout(for: d.screen))
    }

    fileprivate func moved(free: Bool) {
        guard var d = drag else { return }
        let div = d.divider
        let s = div.screen
        let p = mouseAX()
        let g = store.gap
        let inner = s.visibleAX.insetBy(dx: g / 2, dy: g / 2)
        let v = div.kind.vertical
        var edgeA: CGFloat, edgeB: CGFloat

        switch div.kind {
        case .column(let c):
            var l = d.start
            let f = (p.x - inner.minX) / inner.width
            l.moveColumnDivider(c, to: free ? f : ZoneLayout.snapFraction(f, length: inner.width))
            let rects = l.rects(in: s.visibleAX, gap: g)
            edgeA = rects[l.zoneIndex(column: c, row: 0)].maxX
            edgeB = rects[l.zoneIndex(column: c + 1, row: 0)].minX
            d.layout = l
        case .row(let c, let r):
            var l = d.start
            let f = (p.y - inner.minY) / inner.height
            l.moveRowDivider(column: c, r, to: free ? f : ZoneLayout.snapFraction(f, length: inner.height))
            let rects = l.rects(in: s.visibleAX, gap: g)
            edgeA = rects[l.zoneIndex(column: c, row: r)].maxY
            edgeB = rects[l.zoneIndex(column: c, row: r + 1)].minY
            d.layout = l
        case .free:
            // No zone line to move: keep the gap as it was, centred on the mouse, and keep both sides usable.
            let t = div.edgeB - div.edgeA
            let len = v ? inner.width : inner.height
            let origin = v ? inner.minX : inner.minY
            var mid = v ? p.x : p.y
            if !free { mid = origin + ZoneLayout.snapFraction((mid - origin) / len, length: len) * len }
            let minA = d.a.map { v ? $0.1.minX : $0.1.minY }.max() ?? origin
            let maxB = d.b.map { v ? $0.1.maxX : $0.1.maxY }.min() ?? (origin + len)
            edgeA = min(max(mid - t / 2, minA + 120), maxB - 120 - t)
            edgeB = edgeA + t
        }
        drag = d

        var frames: [(AXUIElement, CGRect)] = []
        for (w, f) in d.a {
            frames.append((w, v ? CGRect(x: f.minX, y: f.minY, width: edgeA - f.minX, height: f.height)
                                : CGRect(x: f.minX, y: f.minY, width: f.width, height: edgeA - f.minY)))
        }
        for (w, f) in d.b {
            frames.append((w, v ? CGRect(x: edgeB, y: f.minY, width: f.maxX - edgeB, height: f.height)
                                : CGRect(x: f.minX, y: edgeB, width: f.width, height: f.maxY - edgeB)))
        }
        writer.submit(frames)
        var handle = div.rect
        if v { handle.origin.x = (edgeA + edgeB) / 2 - handle.width / 2 } else { handle.origin.y = (edgeA + edgeB) / 2 - handle.height / 2 }
        panels[div.key]?.setFrame(Coords.toNS(handle), display: true)
    }

    fileprivate func ended() {
        guard let d = drag else { return }
        drag = nil
        if d.layout != d.start { store.setLayout(d.layout, for: d.divider.screen) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    private static func element(_ w: Win) -> (AXUIElement, CGRect)? {
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let el = app.elements(kAXWindowsAttribute).first(where: { $0.windowID == w.id }) else { return nil }
        return (el, w.frame)
    }
}

/// Writes window frames off the main thread, newest set wins, so a slow app never makes the drag stutter.
final class FrameWriter {
    private let queue = DispatchQueue(label: "zones.frames", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [(AXUIElement, CGRect)]?
    private var busy = false

    func submit(_ frames: [(AXUIElement, CGRect)]) {
        lock.lock()
        pending = frames
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending else { busy = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                for (w, r) in next {
                    AXUIElementSetMessagingTimeout(w, 0.1)
                    w.setFrame(r)
                }
            }
        }
    }
}

/// An invisible strip over one gap. Shows a grip on hover.
final class HandlePanel: NSPanel {
    var divider: GapHandles.Divider? {
        didSet { (contentView as? HandleView)?.vertical = divider?.kind.vertical ?? true }
    }

    init(owner: GapHandles) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        let v = HandleView(frame: .zero)
        v.owner = owner
        v.panel = self
        contentView = v
    }

    override var canBecomeKey: Bool { false }
}

final class HandleView: NSView {
    weak var owner: GapHandles?
    weak var panel: HandlePanel?
    var vertical = true { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    private var cursor: NSCursor { vertical ? .resizeLeftRight : .resizeUpDown }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { hovered = true; cursor.set() }
    override func mouseMoved(with e: NSEvent) { cursor.set() }
    override func cursorUpdate(with e: NSEvent) { cursor.set() }
    override func mouseExited(with e: NSEvent) {
        hovered = false
        if !dragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with e: NSEvent) {
        guard let d = panel?.divider else { return }
        dragging = true
        cursor.set()
        owner?.begin(d)
    }

    override func mouseDragged(with e: NSEvent) {
        cursor.set()
        owner?.moved(free: e.modifierFlags.contains(.option))
    }

    override func mouseUp(with e: NSEvent) {
        dragging = false
        owner?.ended()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Nearly clear, but present everywhere so every click lands here.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        guard hovered || dragging else { return }
        let len: CGFloat = min(64, (vertical ? bounds.height : bounds.width) - 8)
        let thick: CGFloat = 4
        let grip = vertical
            ? CGRect(x: bounds.midX - thick / 2, y: bounds.midY - len / 2, width: thick, height: len)
            : CGRect(x: bounds.midX - len / 2, y: bounds.midY - thick / 2, width: len, height: thick)
        (dragging ? ZoneDrawing.accent : NSColor.white.withAlphaComponent(0.9)).setFill()
        NSBezierPath(roundedRect: grip, xRadius: thick / 2, yRadius: thick / 2).fill()
    }
}
