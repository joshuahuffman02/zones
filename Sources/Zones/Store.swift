import AppKit
import ZonesCore

/// One connected monitor.
struct ZScreen {
    let screen: NSScreen
    var id: CGDirectDisplayID { screen.displayID }
    var name: String { screen.localizedName }
    /// Layouts are saved per monitor name and resolution, so a laptop lid or a resolution change
    /// doesn't overwrite another setup.
    var key: String { "\(name) \(Int(screen.frame.width))x\(Int(screen.frame.height))" }
    /// Usable area without the menu bar and Dock: AppKit coordinates (y up) and Accessibility (y down).
    var visibleNS: CGRect { screen.visibleFrame }
    var visibleAX: CGRect { Coords.toAX(screen.visibleFrame) }
    var fullAX: CGRect { Coords.toAX(screen.frame) }

    static var all: [ZScreen] { NSScreen.screens.map(ZScreen.init) }

    /// Left to right, for moving a window across monitors.
    static var ordered: [ZScreen] { all.sorted { $0.fullAX.minX < $1.fullAX.minX } }

    static func containing(_ p: CGPoint) -> ZScreen? {
        all.first { $0.fullAX.contains(p) }
    }

    /// The monitor holding most of a window.
    static func best(for frame: CGRect) -> ZScreen? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return containing(c) ?? all.max { a, b in
            area(a.fullAX.intersection(frame)) < area(b.fullAX.intersection(frame))
        }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

/// The mouse in Accessibility coordinates.
func mouseAX() -> CGPoint {
    let p = NSEvent.mouseLocation
    return CGPoint(x: p.x, y: Coords.primaryHeight - p.y)
}

/// Saved zone layouts and settings, in ~/Library/Application Support/Zones/zones.json.
final class Store {
    struct Saved: Codable {
        var gap: Double = 8
        var layouts: [String: ZoneLayout] = [:]
        /// Drag the gap between two snapped windows to resize both.
        var gapResize = true

        init() {}

        // Missing keys keep their defaults, so older files still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 8
            layouts = try c.decodeIfPresent([String: ZoneLayout].self, forKey: .layouts) ?? [:]
            gapResize = try c.decodeIfPresent(Bool.self, forKey: .gapResize) ?? true
        }
    }

    var gapResize: Bool {
        get { saved.gapResize }
        set { saved.gapResize = newValue; save() }
    }

    private(set) var saved = Saved()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zones/zones.json")
    }

    init() {
        if let data = try? Data(contentsOf: Store.fileURL),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        }
    }

    var gap: Double {
        get { saved.gap }
        set { saved.gap = max(0, min(40, newValue)); save() }
    }

    func layout(for s: ZScreen) -> ZoneLayout {
        saved.layouts[s.key] ?? ZoneLayout.defaultLayout(for: s.screen.frame.size)
    }

    func setLayout(_ l: ZoneLayout, for s: ZScreen) {
        saved.layouts[s.key] = l
        save()
    }

    /// Zone rects for a monitor, in Accessibility coordinates, with the gap applied.
    func rects(for s: ZScreen) -> [CGRect] {
        layout(for: s).rects(in: s.visibleAX, gap: gap)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(saved) { try? data.write(to: Store.fileURL) }
    }
}
