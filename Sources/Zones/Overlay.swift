import AppKit
import QuartzCore
import ZonesCore

/// Draws a monitor's zones. Shared by the drag overlay and the editor.
enum ZoneDrawing {
    static var accent: NSColor { .controlAccentColor }

    static func draw(rects: [CGRect], highlight: CGRect?, labels: Bool, numberSize: CGFloat) {
        let a = accent
        for r in rects {
            let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            a.withAlphaComponent(0.16).setFill()
            path.fill()
            a.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        if let h = highlight {
            let path = NSBezierPath(roundedRect: h, xRadius: 12, yRadius: 12)
            a.withAlphaComponent(0.42).setFill()
            path.fill()
            a.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
        if labels {
            for (i, r) in rects.enumerated() { drawNumber(i + 1, in: r, size: numberSize) }
        }
    }

    static func drawNumber(_ n: Int, in r: CGRect, size: CGFloat, below: String? = nil) {
        let num = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        let ns = num.size()
        var y = r.midY - ns.height / 2
        if let below {
            let sub = NSAttributedString(string: below, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ])
            let ss = sub.size()
            y -= ss.height / 2
            sub.draw(at: CGPoint(x: r.midX - ss.width / 2, y: y + ns.height + 2))
        }
        num.draw(at: CGPoint(x: r.midX - ns.width / 2, y: y))
    }
}

/// A click-through panel covering one monitor's usable area.
final class OverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        alphaValue = 0
    }

    func fade(in show: Bool, duration: TimeInterval = 0.12, then: (() -> Void)? = nil) {
        if show { orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            animator().alphaValue = show ? 1 : 0
        }, completionHandler: {
            // A fade-in may have started since; only hide if still faded out.
            if !show, self.alphaValue < 0.01 { self.orderOut(nil) }
            then?()
        })
    }
}

/// What you see while dragging with ⇧ held: every zone, with the drop target lit.
final class DragOverlayView: NSView {
    var rects: [CGRect] = [] { didSet { needsDisplay = true } }
    var highlight: CGRect? { didSet { if oldValue != highlight { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        ZoneDrawing.draw(rects: rects, highlight: highlight, labels: true, numberSize: 34)
    }
}

/// One overlay per monitor, shown on whichever monitor the mouse is over.
final class DragOverlay {
    private var panels: [CGDirectDisplayID: (OverlayPanel, DragOverlayView)] = [:]
    private var shown: CGDirectDisplayID?

    /// `rects` and `highlight` are in Accessibility coordinates.
    func show(on s: ZScreen, rects: [CGRect], highlight: CGRect?) {
        let (panel, view) = panel(for: s)
        let o = s.visibleAX.origin
        view.rects = rects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
        view.highlight = highlight?.offsetBy(dx: -o.x, dy: -o.y)
        if shown != s.id {
            hide()
            shown = s.id
            panel.fade(in: true)
        }
    }

    func hide() {
        guard let id = shown else { return }
        shown = nil
        panels[id]?.0.fade(in: false)
    }

    /// Shows a monitor's zones for a moment, after picking a layout from the menu.
    func flash(on s: ZScreen, rects: [CGRect]) {
        show(on: s, rects: rects, highlight: nil)
        let id = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.shown == id { self?.hide() }
        }
    }

    private func panel(for s: ZScreen) -> (OverlayPanel, DragOverlayView) {
        if let p = panels[s.id], p.0.frame == s.visibleNS { return p }
        panels[s.id]?.0.close()
        let panel = OverlayPanel(frame: s.visibleNS)
        let view = DragOverlayView(frame: CGRect(origin: .zero, size: s.visibleNS.size))
        panel.contentView = view
        panels[s.id] = (panel, view)
        return (panel, view)
    }
}
