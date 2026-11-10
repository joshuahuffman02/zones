import AppKit
import Combine
import SwiftUI
import ZonesCore

final class EditorModel: ObservableObject {
    @Published var layout: ZoneLayout
    @Published var gap: Double
    let screenName: String

    init(layout: ZoneLayout, gap: Double, screenName: String) {
        self.layout = layout
        self.gap = gap
        self.screenName = screenName
    }
}

/// A full-monitor editor: drag the lines between zones, split or remove a zone from its hover buttons,
/// or start from a template in the toolbar.
final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ZoneEditor {
    private let panel: EditorPanel
    private let model: EditorModel
    private let onDone: (ZoneLayout?, Double) -> Void

    init(screen s: ZScreen, layout: ZoneLayout, gap: Double, onDone: @escaping (ZoneLayout?, Double) -> Void) {
        self.onDone = onDone
        model = EditorModel(layout: layout, gap: gap, screenName: s.name)
        panel = EditorPanel(contentRect: s.visibleNS, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: s.visibleNS.size))
        let canvas = EditorCanvas(frame: root.bounds, model: model)
        canvas.autoresizingMask = [.width, .height]
        canvas.onCancel = { [weak self] in self?.finish(save: false) }
        canvas.onSave = { [weak self] in self?.finish(save: true) }
        root.addSubview(canvas)

        let bar = NSHostingView(rootView: EditorToolbar(model: model,
                                                        cancel: { [weak self] in self?.finish(save: false) },
                                                        save: { [weak self] in self?.finish(save: true) }))
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        ])
        panel.contentView = root
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    private var finished = false

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        onDone(save ? model.layout : nil, model.gap)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: {
            self.panel.close()
        })
    }
}

struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(model.screenName).font(.headline)
            Divider().frame(height: 18)
            Menu("Start from") {
                ForEach(ZoneLayout.templates, id: \.name) { t in
                    Button(t.name) { model.layout = t.layout }
                }
            }
            .fixedSize()
            Button("Even out") { model.layout.evenOut() }
            Divider().frame(height: 18)
            Text("Gap")
            Stepper(value: $model.gap, in: 0...40, step: 2) {
                Text("\(Int(model.gap)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .fixedSize()
            Divider().frame(height: 18)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .fixedSize()
    }
}

/// Draws the zones and handles dividers and the per-zone buttons.
final class EditorCanvas: NSView {
    private let model: EditorModel
    private var bag: Set<AnyCancellable> = []
    var onCancel: () -> Void = {}
    var onSave: () -> Void = {}

    private enum Handle: Equatable { case column(Int), row(Int, Int) }
    private var dragging: Handle?
    private var hoverZone: Int?
    private let buttons = NSStackView()
    private var tracking: NSTrackingArea?

    init(frame: CGRect, model: EditorModel) {
        self.model = model
        super.init(frame: frame)
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.changed() }
        }.store(in: &bag)

        buttons.orientation = .horizontal
        buttons.spacing = 6
        for (title, sel, tip) in [
            ("Split ↔︎", #selector(splitColumn), "Split this zone's column into two side by side"),
            ("Split ↕︎", #selector(splitRow), "Split this zone into top and bottom"),
            ("Remove", #selector(removeZone), "Merge this zone into its neighbour"),
        ] {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.toolTip = tip
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = true
        addSubview(buttons)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        placeButtons()
    }

    // MARK: Geometry

    private var area: CGRect { bounds }
    private var rects: [CGRect] { model.layout.rects(in: area, gap: model.gap) }

    /// Each divider and the strip of screen that grabs it.
    private var handles: [(Handle, CGRect)] {
        var out: [(Handle, CGRect)] = []
        let l = model.layout
        var x = area.minX
        for (c, col) in l.columns.enumerated() {
            let w = area.width * col.width
            var y = area.minY
            for r in 0..<(col.rows.count - 1) {
                y += area.height * col.rows[r]
                out.append((.row(c, r), CGRect(x: x + 10, y: y - 7, width: w - 20, height: 14)))
            }
            x += w
            if c < l.columns.count - 1 {
                out.append((.column(c), CGRect(x: x - 7, y: area.minY, width: 14, height: area.height)))
            }
        }
        return out
    }

    override func resetCursorRects() {
        for (h, r) in handles {
            if case .column = h { addCursorRect(r, cursor: .resizeLeftRight) } else { addCursorRect(r, cursor: .resizeUpDown) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        let rs = rects
        ZoneDrawing.draw(rects: rs, highlight: hoverZone.flatMap { rs.indices.contains($0) ? rs[$0] : nil }, labels: false, numberSize: 0)
        for (i, r) in rs.enumerated() {
            ZoneDrawing.drawNumber(i + 1, in: r.offsetBy(dx: 0, dy: -24), size: 56, below: "\(Int(r.width)) × \(Int(r.height))")
        }
        // Divider grips.
        for (h, r) in handles {
            let active = h == dragging
            let grip: CGRect
            if case .column = h {
                grip = CGRect(x: r.midX - 3, y: r.midY - 28, width: 6, height: 56)
            } else {
                grip = CGRect(x: r.midX - 28, y: r.midY - 3, width: 56, height: 6)
            }
            (active ? ZoneDrawing.accent : NSColor.white.withAlphaComponent(0.85)).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
        }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        dragging = handles.first { $0.1.contains(p) }?.0
        buttons.isHidden = dragging != nil || buttons.isHidden
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let h = dragging else { return }
        let p = convert(e.locationInWindow, from: nil)
        let free = e.modifierFlags.contains(.option)
        switch h {
        case .column(let c):
            model.layout.moveColumnDivider(c, to: snap((p.x - area.minX) / area.width, length: area.width, free: free))
        case .row(let c, let r):
            model.layout.moveRowDivider(column: c, r, to: snap((p.y - area.minY) / area.height, length: area.height, free: free))
        }
    }

    override func mouseUp(with e: NSEvent) {
        dragging = nil
        changed()
        updateHover(convert(e.locationInWindow, from: nil))
    }

    override func mouseMoved(with e: NSEvent) {
        updateHover(convert(e.locationInWindow, from: nil))
    }

    /// Dividers stick to twelfths (and so halves, thirds and quarters) within 12 points. Hold ⌥ to place freely.
    private func snap(_ f: Double, length: Double, free: Bool) -> Double {
        free ? f : ZoneLayout.snapFraction(f, length: length)
    }

    private func updateHover(_ p: CGPoint) {
        guard dragging == nil else { return }
        if !buttons.isHidden, buttons.frame.insetBy(dx: -8, dy: -8).contains(p) { return }
        let onHandle = handles.contains { $0.1.contains(p) }
        let z = onHandle ? nil : model.layout.zone(at: p, in: area)
        if z != hoverZone {
            hoverZone = z
            needsDisplay = true
            placeButtons()
        }
    }

    private func placeButtons() {
        guard let z = hoverZone, rects.indices.contains(z) else { buttons.isHidden = true; return }
        let r = rects[z]
        let size = buttons.fittingSize
        guard r.width > size.width + 16 else { buttons.isHidden = true; return }
        buttons.frame = CGRect(x: r.midX - size.width / 2, y: r.midY + 36, width: size.width, height: size.height)
        buttons.isHidden = false
        // Removing the only zone does nothing.
        (buttons.arrangedSubviews.last as? NSButton)?.isEnabled = model.layout.zoneCount > 1
    }

    @objc private func splitColumn() {
        guard let z = hoverZone, let (c, _) = model.layout.position(of: z) else { return }
        model.layout.splitColumn(c)
    }

    @objc private func splitRow() {
        guard let z = hoverZone, let (c, r) = model.layout.position(of: z) else { return }
        model.layout.splitRow(column: c, r)
    }

    @objc private func removeZone() {
        guard let z = hoverZone else { return }
        model.layout.merge(zone: z)
        hoverZone = nil
        changed()
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onCancel()  // Esc
        case 36, 76: onSave()  // Return, Enter
        default: super.keyDown(with: e)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}
