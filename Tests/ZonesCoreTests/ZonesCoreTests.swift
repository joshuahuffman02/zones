import Foundation
import CoreGraphics
import Testing
@testable import ZonesCore

let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)

@Test func fourColumnsSplitTheUltrawideEvenly() {
    let r = ZoneLayout.columns(4).rects(in: ultrawide)
    #expect(r.map(\.width) == [1280, 1280, 1280, 1280])
    #expect(r.map(\.minX) == [0, 1280, 2560, 3840])
    #expect(r.allSatisfy { $0.height == 1440 && $0.minY == 0 })
}

@Test func gapsAreEvenBetweenZonesAndAtTheEdges() {
    let r = ZoneLayout.columns(2).rects(in: CGRect(x: 0, y: 0, width: 1000, height: 500), gap: 10)
    #expect(r[0] == CGRect(x: 10, y: 10, width: 485, height: 480))
    #expect(r[1] == CGRect(x: 505, y: 10, width: 485, height: 480))
}

@Test func rectsFollowTheAreaOrigin() {
    let area = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
    let r = ZoneLayout.columns(2).rects(in: area)
    #expect(r[0].minX == -1920 && r[0].minY == 25)
    #expect(r[1].maxX == 0 && r[1].maxY == 1080)
}

@Test func zonesAreNumberedColumnByColumnTopToBottom() {
    let l = ZoneLayout.focusStacked
    #expect(l.zoneCount == 5)
    let r = l.rects(in: ultrawide)
    #expect(r[0].minX == 0 && r[0].minY == 0)
    #expect(r[1].minX == 0 && r[1].minY == 720)
    #expect(r[2].width == 2560)
    #expect(r[3].minY == 0 && r[4].minY == 720)
    #expect(l.position(of: 4)! == (2, 1))
}

@Test func zoneUnderPoint() {
    let l = ZoneLayout.grid(columns: 2, rows: 2)
    let a = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    #expect(l.zone(at: CGPoint(x: 10, y: 10), in: a) == 0)
    #expect(l.zone(at: CGPoint(x: 10, y: 990), in: a) == 1)
    #expect(l.zone(at: CGPoint(x: 990, y: 10), in: a) == 2)
    #expect(l.zone(at: CGPoint(x: 500, y: 500), in: a) != nil)
    #expect(l.zone(at: CGPoint(x: 1001, y: 10), in: a) == nil)
}

@Test func spanCoversEverythingBetween() {
    let l = ZoneLayout.columns(4)
    #expect(l.span(0, 2, in: ultrawide) == CGRect(x: 0, y: 0, width: 3840, height: 1440))
    #expect(l.span(3, 1, in: ultrawide) == CGRect(x: 1280, y: 0, width: 3840, height: 1440))
}

@Test func bestZoneByOverlap() {
    let l = ZoneLayout.columns(4)
    #expect(l.bestZone(for: CGRect(x: 1200, y: 0, width: 1000, height: 800), in: ultrawide) == 1)
    #expect(l.bestZone(for: CGRect(x: 9000, y: 0, width: 10, height: 10), in: ultrawide) == nil)
}

@Test func dividersMoveAndClamp() {
    var l = ZoneLayout.columns(2)
    l.moveColumnDivider(0, to: 0.7)
    #expect(abs(l.columns[0].width - 0.7) < 1e-9)
    #expect(abs(l.columns[1].width - 0.3) < 1e-9)
    l.moveColumnDivider(0, to: 0.999)
    #expect(abs(l.columns[1].width - ZoneLayout.minFraction) < 1e-9)
    l.moveColumnDivider(1, to: 0.5)  // no divider right of the last column
    #expect(abs(l.columns[1].width - ZoneLayout.minFraction) < 1e-9)

    var g = ZoneLayout.grid(columns: 1, rows: 3)
    g.moveRowDivider(column: 0, 1, to: 0.9)
    #expect(abs(g.columns[0].rows[1] - (0.9 - 1.0 / 3)) < 1e-9)
    #expect(abs(g.columns[0].rows.reduce(0, +) - 1) < 1e-9)
}

@Test func splitAndMerge() {
    var l = ZoneLayout.columns(2)
    l.splitColumn(1)
    #expect(l.columns.map(\.width) == [0.5, 0.25, 0.25])
    l.splitRow(column: 0, 0)
    #expect(l.zoneCount == 4)
    l.merge(zone: 1)  // bottom half of column 0
    #expect(l.columns[0].rows == [1])
    l.merge(zone: 2)  // last column
    #expect(l.columns.map(\.width) == [0.5, 0.5])
    var one = ZoneLayout.columns(1)
    one.merge(zone: 0)
    #expect(one.zoneCount == 1)
}

@Test func evenOutAndCodableRoundTrip() throws {
    var l = ZoneLayout.focus
    l.evenOut()
    #expect(l.columns.allSatisfy { abs($0.width - 1.0 / 3) < 1e-9 })
    let data = try JSONEncoder().encode(l)
    #expect(try JSONDecoder().decode(ZoneLayout.self, from: data) == l)
}

@Test func defaultLayoutByAspect() {
    #expect(ZoneLayout.defaultLayout(for: CGSize(width: 5120, height: 1440)).zoneCount == 4)
    #expect(ZoneLayout.defaultLayout(for: CGSize(width: 1512, height: 982)).zoneCount == 2)
}
