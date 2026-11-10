import AppKit
import ApplicationServices
import ZonesCore

/// Snaps windows into zones: ⇧-drag to drop into a zone (add ⌘ to span several), or use the keyboard.
/// Never moves a window you didn't move.
final class Snapper {
    let store: Store
    let overlay = DragOverlay()
    private var monitors: [Any] = []
    private let systemWide = AXUIElementCreateSystemWide()

    private struct Drag {
        let window: AXUIElement
        let startFrame: CGRect
        var moving = false
        var lastCheck: TimeInterval = 0
        /// Where a ⌘ span started: monitor and zone.
        var anchor: (CGDirectDisplayID, Int)?
        var target: CGRect?
    }

    private var drag: Drag?
    var isDragging: Bool { drag?.moving == true }

    init(store: Store) {
        self.store = store
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
    }

    func start() {
        guard monitors.isEmpty else { return }
        let add = { (mask: NSEvent.EventTypeMask, f: @escaping (NSEvent) -> Void) in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: f) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
        add(.flagsChanged) { [weak self] _ in self?.flagsChanged() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        drag = nil
        overlay.hide()
    }

    // MARK: Dragging

    private func mouseDown() {
        drag = nil
        let p = mouseAX()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, let hit,
              let window = Self.window(of: hit), window.pid != getpid(),
              Self.isSnappable(window), let frame = window.frame
        else { return }
        AXUIElementSetMessagingTimeout(window, 0.2)
        drag = Drag(window: window, startFrame: frame)
    }

    private func mouseDragged() {
        guard var d = drag else { return }
        if !d.moving {
            // Only a moved window snaps: not a resize, a text selection or a drag inside a window.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - d.lastCheck > 0.05 else { return }
            d.lastCheck = now
            guard let f = d.window.frame else { drag = nil; return }
            let moved = abs(f.minX - d.startFrame.minX) + abs(f.minY - d.startFrame.minY) > 3
            let sameSize = abs(f.width - d.startFrame.width) < 2 && abs(f.height - d.startFrame.height) < 2
            if moved && !sameSize { drag = nil; return }
            d.moving = moved
        }
        drag = d
        if d.moving { update() }
    }

    private func flagsChanged() {
        if drag?.moving == true { update() }
    }

    private func mouseUp() {
        defer { drag = nil; overlay.hide() }
        guard let d = drag, d.moving, let target = d.target else { return }
        // Let the app finish its own drag first, then check again in case it (or macOS edge tiling) moved it back.
        let w = d.window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.place(w, in: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let f = w.frame, !Self.close(f, target) { Self.place(w, in: target) }
            }
        }
    }

    private func update() {
        guard var d = drag else { return }
        defer { drag = d }
        let flags = NSEvent.modifierFlags
        let p = mouseAX()
        guard flags.contains(.shift), let s = ZScreen.containing(p) else {
            d.target = nil
            d.anchor = nil
            overlay.hide()
            return
        }
        let layout = store.layout(for: s)
        let rects = store.rects(for: s)
        guard let zone = layout.zone(at: p, in: s.visibleAX) else {
            d.target = nil
            overlay.show(on: s, rects: rects, highlight: nil)
            return
        }
        if flags.contains(.command) {
            if d.anchor?.0 != s.id { d.anchor = (s.id, zone) }
            d.target = layout.span(d.anchor!.1, zone, in: s.visibleAX, gap: store.gap)
        } else {
            d.anchor = nil
            d.target = rects[zone]
        }
        overlay.show(on: s, rects: rects, highlight: d.target)
    }

    // MARK: Keyboard

    /// ⌃⌥1…9: put the focused window in that zone on its monitor.
    func sendFocused(toZone n: Int) {
        guard let w = Self.focusedWindow(), let f = w.frame, let s = ZScreen.best(for: f) else { return }
        let rects = store.rects(for: s)
        guard rects.indices.contains(n) else { NSSound.beep(); return }
        Self.place(w, in: rects[n])
    }

    enum Direction { case left, right, up, down }

    /// ⌃⌥ arrows: the next zone over. Left and right carry on to the next monitor at either end.
    func moveFocused(_ dir: Direction) {
        guard let w = Self.focusedWindow(), let f = w.frame, let s = ZScreen.best(for: f) else { return }
        let layout = store.layout(for: s)
        let rects = store.rects(for: s)
        guard let cur = layout.bestZone(for: f, in: s.visibleAX), let (c, r) = layout.position(of: cur) else { return }
        // A window that isn't sitting in its zone yet goes there first.
        if !Self.close(f, rects[cur]) {
            Self.place(w, in: rects[cur])
            return
        }
        switch dir {
        case .up, .down:
            let nr = r + (dir == .up ? -1 : 1)
            guard layout.columns[c].rows.indices.contains(nr) else { return }
            Self.place(w, in: rects[zoneIndex(layout, c, nr)])
        case .left, .right:
            let nc = c + (dir == .left ? -1 : 1)
            if layout.columns.indices.contains(nc) {
                Self.place(w, in: rects[nearestRow(layout, rects, column: nc, to: rects[cur])])
                return
            }
            // Off the end: the neighbouring monitor's nearest edge column.
            let screens = ZScreen.ordered
            guard let i = screens.firstIndex(where: { $0.id == s.id }) else { return }
            let ni = i + (dir == .left ? -1 : 1)
            guard screens.indices.contains(ni) else { return }
            let ns = screens[ni]
            let nl = store.layout(for: ns)
            let nrects = store.rects(for: ns)
            let col = dir == .left ? nl.columns.count - 1 : 0
            Self.place(w, in: nrects[nearestRow(nl, nrects, column: col, to: rects[cur])])
        }
    }

    /// ⌃⌥↩: fill the monitor's usable area.
    func fillFocused() {
        guard let w = Self.focusedWindow(), let f = w.frame, let s = ZScreen.best(for: f) else { return }
        let g = store.gap
        Self.place(w, in: s.visibleAX.insetBy(dx: g, dy: g))
    }

    private func zoneIndex(_ l: ZoneLayout, _ c: Int, _ r: Int) -> Int {
        l.columns[..<c].reduce(0) { $0 + $1.rows.count } + r
    }

    private func nearestRow(_ l: ZoneLayout, _ rects: [CGRect], column c: Int, to from: CGRect) -> Int {
        let first = zoneIndex(l, c, 0)
        let range = first..<(first + l.columns[c].rows.count)
        return range.min { abs(rects[$0].midY - from.midY) < abs(rects[$1].midY - from.midY) } ?? first
    }

    // MARK: Windows

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.3)
        guard let w = el.element(kAXFocusedWindowAttribute), isSnappable(w) else { return nil }
        return w
    }

    /// The window an element belongs to.
    static func window(of el: AXUIElement) -> AXUIElement? {
        if el.string(kAXRoleAttribute) == kAXWindowRole { return el }
        if let w = el.element(kAXWindowAttribute) { return w }
        var cur = el
        for _ in 0..<12 {
            guard let parent = cur.element(kAXParentAttribute) else { return nil }
            if parent.string(kAXRoleAttribute) == kAXWindowRole { return parent }
            cur = parent
        }
        return nil
    }

    /// Ordinary windows that can be moved and resized. Dialogs and sheets are left alone.
    static func isSnappable(_ w: AXUIElement) -> Bool {
        let sub = w.string(kAXSubroleAttribute)
        guard sub == nil || sub == kAXStandardWindowSubrole else { return false }
        if w.bool("AXFullScreen") == true { return false }
        return w.isSettable(kAXPositionAttribute) && w.isSettable(kAXSizeAttribute)
    }

    static func place(_ w: AXUIElement, in r: CGRect) {
        w.setFrame(r)
        // Some apps only take sizes in steps (terminals): keep the window inside the zone, at its top left.
        if let f = w.frame, f.width > r.width + 1 || f.height > r.height + 1 {
            w.setSize(CGSize(width: min(f.width, r.width), height: min(f.height, r.height)))
            w.setPosition(r.origin)
        }
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 24 && abs(a.height - b.height) < 24
    }
}
