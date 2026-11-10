import CoreGraphics

/// A monitor's zones: columns left to right, each split into rows top to bottom.
/// Widths and heights are fractions that sum to 1. Coordinates are y-down (Accessibility style).
public struct ZoneLayout: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable {
        public var width: Double
        public var rows: [Double]

        public init(width: Double, rows: [Double] = [1]) {
            self.width = width
            self.rows = rows
        }
    }

    public var columns: [Column]

    public init(columns: [Column]) {
        self.columns = columns
        normalize()
    }

    public static let minFraction = 0.05

    // MARK: Templates

    public static func columns(_ n: Int) -> ZoneLayout {
        ZoneLayout(columns: Array(repeating: Column(width: 1), count: max(1, n)))
    }

    public static func grid(columns c: Int, rows r: Int) -> ZoneLayout {
        ZoneLayout(columns: Array(repeating: Column(width: 1, rows: Array(repeating: 1, count: max(1, r))), count: max(1, c)))
    }

    /// Wide center with a narrow column each side.
    public static let focus = ZoneLayout(columns: [Column(width: 1), Column(width: 2), Column(width: 1)])

    /// Wide center, with each side column split top and bottom.
    public static let focusStacked = ZoneLayout(columns: [
        Column(width: 1, rows: [1, 1]), Column(width: 2), Column(width: 1, rows: [1, 1]),
    ])

    public struct Template: Sendable {
        public let name: String
        public let layout: ZoneLayout
    }

    public static let templates: [Template] = [
        Template(name: "2 columns", layout: .columns(2)),
        Template(name: "3 columns", layout: .columns(3)),
        Template(name: "4 columns", layout: .columns(4)),
        Template(name: "5 columns", layout: .columns(5)),
        Template(name: "2 × 2 grid", layout: .grid(columns: 2, rows: 2)),
        Template(name: "3 × 2 grid", layout: .grid(columns: 3, rows: 2)),
        Template(name: "4 × 2 grid", layout: .grid(columns: 4, rows: 2)),
        Template(name: "Wide center", layout: .focus),
        Template(name: "Wide center, split sides", layout: .focusStacked),
    ]

    /// Four columns on an ultrawide (wider than 2.3:1), two on anything else.
    public static func defaultLayout(for size: CGSize) -> ZoneLayout {
        size.width / max(1, size.height) >= 2.3 ? .columns(4) : .columns(2)
    }

    // MARK: Geometry

    public var zoneCount: Int { columns.reduce(0) { $0 + $1.rows.count } }

    /// One rect per zone, numbered column by column, top to bottom. `gap` is the space between zones and
    /// around the edge.
    public func rects(in area: CGRect, gap: Double = 0) -> [CGRect] {
        var out: [CGRect] = []
        let inner = area.insetBy(dx: gap / 2, dy: gap / 2)
        var x = inner.minX
        for (ci, col) in columns.enumerated() {
            let w = ci == columns.count - 1 ? inner.maxX - x : inner.width * col.width
            var y = inner.minY
            for (ri, row) in col.rows.enumerated() {
                let h = ri == col.rows.count - 1 ? inner.maxY - y : inner.height * row
                out.append(CGRect(x: x, y: y, width: w, height: h).insetBy(dx: gap / 2, dy: gap / 2).integral)
                y += h
            }
            x += w
        }
        return out
    }

    /// The zone under a point, or nil if the point is outside the area.
    public func zone(at p: CGPoint, in area: CGRect) -> Int? {
        guard area.contains(p) else { return nil }
        // Gapless rects so the space between zones still belongs to one of them.
        let r = rects(in: area)
        return r.firstIndex { $0.insetBy(dx: -0.5, dy: -0.5).contains(p) }
    }

    /// The zone a window mostly sits in, by overlapping area.
    public func bestZone(for frame: CGRect, in area: CGRect) -> Int? {
        let r = rects(in: area)
        var best: (Int, CGFloat)?
        for (i, z) in r.enumerated() {
            let o = z.intersection(frame)
            guard !o.isNull else { continue }
            let a = o.width * o.height
            if a > (best?.1 ?? 0) { best = (i, a) }
        }
        return best?.0
    }

    /// The smallest rect covering zones `a` and `b`, used when a drop spans several zones.
    public func span(_ a: Int, _ b: Int, in area: CGRect, gap: Double = 0) -> CGRect? {
        let r = rects(in: area, gap: gap)
        guard r.indices.contains(a), r.indices.contains(b) else { return nil }
        return r[a].union(r[b])
    }

    /// (column, row) for a zone number.
    public func position(of zone: Int) -> (Int, Int)? {
        var i = zone
        for (c, col) in columns.enumerated() {
            if i < col.rows.count { return (c, i) }
            i -= col.rows.count
        }
        return nil
    }

    // MARK: Editing

    /// Moves the divider to the right of column `i` to `x`, a fraction of the full width.
    public mutating func moveColumnDivider(_ i: Int, to x: Double) {
        guard i >= 0, i + 1 < columns.count else { return }
        let left = columns[..<i].reduce(0) { $0 + $1.width }
        let pair = columns[i].width + columns[i + 1].width
        let w = min(max(x - left, Self.minFraction), pair - Self.minFraction)
        columns[i].width = w
        columns[i + 1].width = pair - w
    }

    /// Moves the divider below row `r` in column `c` to `y`, a fraction of the full height.
    public mutating func moveRowDivider(column c: Int, _ r: Int, to y: Double) {
        guard columns.indices.contains(c), r >= 0, r + 1 < columns[c].rows.count else { return }
        let top = columns[c].rows[..<r].reduce(0, +)
        let pair = columns[c].rows[r] + columns[c].rows[r + 1]
        let h = min(max(y - top, Self.minFraction), pair - Self.minFraction)
        columns[c].rows[r] = h
        columns[c].rows[r + 1] = pair - h
    }

    /// Splits column `c` in two, keeping its rows on both halves.
    public mutating func splitColumn(_ c: Int) {
        guard columns.indices.contains(c), columns[c].width / 2 >= Self.minFraction else { return }
        columns[c].width /= 2
        columns.insert(columns[c], at: c + 1)
    }

    /// Splits row `r` of column `c` in two.
    public mutating func splitRow(column c: Int, _ r: Int) {
        guard columns.indices.contains(c), columns[c].rows.indices.contains(r),
              columns[c].rows[r] / 2 >= Self.minFraction else { return }
        columns[c].rows[r] /= 2
        columns[c].rows.insert(columns[c].rows[r], at: r + 1)
    }

    /// Removes the zone and gives its space to its neighbour. Removing a column's last row removes the column.
    public mutating func merge(zone: Int) {
        guard let (c, r) = position(of: zone) else { return }
        if columns[c].rows.count > 1 {
            let h = columns[c].rows.remove(at: r)
            columns[c].rows[r > 0 ? r - 1 : 0] += h
        } else if columns.count > 1 {
            let w = columns.remove(at: c).width
            columns[c > 0 ? c - 1 : 0].width += w
        }
    }

    /// Makes every column (and every row within a column) equal.
    public mutating func evenOut() {
        for c in columns.indices {
            columns[c].width = 1
            columns[c].rows = Array(repeating: 1, count: columns[c].rows.count)
        }
        normalize()
    }

    /// Scales widths and heights to sum to 1 and drops empty entries.
    public mutating func normalize() {
        columns = columns.filter { $0.width > 0 }
        if columns.isEmpty { columns = [Column(width: 1)] }
        let total = columns.reduce(0) { $0 + $1.width }
        for c in columns.indices {
            columns[c].width /= total
            var rows = columns[c].rows.filter { $0 > 0 }
            if rows.isEmpty { rows = [1] }
            let t = rows.reduce(0, +)
            columns[c].rows = rows.map { $0 / t }
        }
    }

    /// Divider positions stick to twelfths (so halves, thirds and quarters) within `within` points.
    public static func snapFraction(_ f: Double, length: Double, within: Double = 12) -> Double {
        let s = (f * 12).rounded() / 12
        return abs(s - f) * length < within ? s : f
    }

    /// The zone number for a column and row.
    public func zoneIndex(column c: Int, row r: Int) -> Int {
        columns[..<c].reduce(0) { $0 + $1.rows.count } + r
    }
}
