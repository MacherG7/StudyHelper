import CoreGraphics
import Foundation
import StudyCore
import Testing
@testable import StudyImport

@Suite("Handschriftzeilen: Gruppierung von Strichen")
struct InkRowsTests {
    let lineHeight = 20.0

    /// Boxes of `count` word strokes (18 wide, 12 high) starting at x on a row centered at `y`.
    func word(x: Double, y: Double, width: Double = 18, height: Double = 12) -> CGRect {
        CGRect(x: x, y: y - height / 2, width: width, height: height)
    }

    func row(y: Double, from x: Double = 40, count: Int = 8) -> [CGRect] {
        (0..<count).map { word(x: x + Double($0) * 22, y: y) }
    }

    @Test("Drei Zeilen mit Abstand werden zu drei Zeilen, oben nach unten")
    func threeRows() {
        let boxes = row(y: 300) + row(y: 100) + row(y: 200)
        let rows = InkRows.rows(of: boxes, lineHeight: lineHeight)
        #expect(rows.count == 3)
        #expect(rows.map { Set($0.map { Int(boxes[$0].midY) }) } == [[100], [200], [300]])
        #expect(rows.allSatisfy { $0.count == 8 })
    }

    @Test("Dicht gepackte Zeilen (Abstand 1,1 Zeilenhöhen) mit Ober- und Unterlängen bleiben getrennt")
    func denseRowsStaySeparate() {
        // Boxes 24 high at a pitch of 22: they overlap in height, the middles do not.
        let boxes = (0..<10).map { word(x: 40 + Double($0) * 22, y: 100, height: 24) }
            + (0..<10).map { word(x: 40 + Double($0) * 22, y: 122, height: 24) }
        let rows = InkRows.rows(of: boxes, lineHeight: lineHeight)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.count == 10 })
    }

    @Test("Ein i-Punkt über der Zeile und ein Akzent gehören zur Zeile")
    func dotsJoinTheRow() {
        var boxes = row(y: 100)
        boxes.append(CGRect(x: 80, y: 89, width: 2, height: 2))  // i-dot about 0.5 line heights above the middle
        let rows = InkRows.rows(of: boxes, lineHeight: lineHeight)
        #expect(rows.count == 1)
        #expect(rows[0].count == boxes.count)
    }

    @Test("Eine hohe Projektion aus zwei eng gepackten Zeilen wird am Tal des Tintenprofils geteilt")
    func tightRowsAreSplitAtTheValley() {
        // Small writing: pitch 15 = 0.75 line heights; strokes 11 high. Centers 100 and 115.
        let boxes = (0..<8).map { word(x: 40 + Double($0) * 20, y: 100, height: 11) }
            + (0..<8).map { word(x: 40 + Double($0) * 20, y: 115, height: 11) }
        let rows = InkRows.rows(of: boxes, lineHeight: lineHeight)
        #expect(rows.count == 2, "Zeilen: \(rows.map(\.count))")
        #expect(rows.map { Set($0.map { Int(boxes[$0].midY) }) } == [[100], [115]])
    }

    @Test("Eine einzelne breite Zeile mit unterschiedlich hohen Strichen wird nicht zerschnitten")
    func oneRowStaysOne() {
        let boxes = (0..<12).map { word(x: 40 + Double($0) * 20, y: 100 + Double($0 % 3) * 3, height: 8 + Double($0 % 4) * 5) }
        #expect(InkRows.rows(of: boxes, lineHeight: lineHeight).count == 1)
    }

    @Test("Segmente: Lücken über zwei Zeilenhöhen trennen, kleinere nicht; links nach rechts")
    func segments() {
        let boxes = row(y: 100, from: 300, count: 4) + row(y: 100, from: 40, count: 4)  // gap 300 - (40 + 3*22 + 18) = 176
        let all = Array(boxes.indices)
        let segments = InkRows.segments(of: all, boxes: boxes, lineHeight: lineHeight)
        #expect(segments.count == 2)
        #expect(segments[0].allSatisfy { boxes[$0].minX < 200 } && segments[1].allSatisfy { boxes[$0].minX >= 300 })
        let close = row(y: 100, from: 40, count: 3) + row(y: 100, from: 40 + 3 * 22 + 30, count: 3)  // gap 30 < 40
        #expect(InkRows.segments(of: Array(close.indices), boxes: close, lineHeight: lineHeight).count == 1)
    }

    @Test("Zeilen zählen nur mit echter Schrift: Punkt und kurzer Strich zählen nicht")
    func substantialRows() {
        let two = row(y: 100) + row(y: 160)
        #expect(InkRows.substantialRowCount(of: two, lineHeight: lineHeight) == 2)
        let withSpeck = row(y: 100) + [CGRect(x: 100, y: 200, width: 3, height: 3)]
        #expect(InkRows.substantialRowCount(of: withSpeck, lineHeight: lineHeight) == 1)
        #expect(InkRows.substantialRowCount(of: [], lineHeight: lineHeight) == 0)
    }

    @Test("Ausschnitt: Polster 0,5 Zeilenhöhen oben/unten, eine Zeilenhöhe seitlich, an der Seite begrenzt")
    func cropRegion() {
        let page = PageSize(width: 600, height: 800)
        let region = HandwritingRetry.cropRegion(of: CGRect(x: 100, y: 200, width: 200, height: 20), lineHeight: 20, pageSize: page)
        #expect(abs(region.minX - 80 / 600) < 1e-9 && abs(region.maxX - 320 / 600) < 1e-9)
        #expect(abs(region.minY - 190 / 800) < 1e-9 && abs(region.maxY - 230 / 800) < 1e-9)
        let edge = HandwritingRetry.cropRegion(of: CGRect(x: 5, y: 2, width: 600, height: 20), lineHeight: 20, pageSize: page)
        #expect(edge.minX == 0 && edge.minY == 0 && edge.maxX == 1)
    }

    @Test("Ausschnitt-Bild: Auf die Seite zurückgerechnet liegt ein Strich exakt dort, wo er auf der Seite liegt")
    func renderedCropMapsBack() throws {
        let stroke = InkStroke(points: [PDFPoint(x: 100, y: 500), PDFPoint(x: 160, y: 520)], color: .black, width: 2)
        let page = GoodnotesPage(index: 0, size: PageSize(width: 600, height: 800), strokes: [stroke])
        let region = NormalizedRect(x: 80 / 600, y: (800 - 540) / 800, width: 100 / 600, height: 60 / 800)
        let crop = try #require(InkLayerRendering.renderStrokes(page: page, indices: [0], crop: region, scale: 4))
        let pixels = GoodnotesTestSupport.grayPixels(crop.image)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<crop.image.height {
            for x in 0..<crop.image.width where pixels[y * crop.image.width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        #expect(maxX > minX)
        // Pixel box -> page points (origin top-left).
        let left = (crop.rect.x + Double(minX) / Double(crop.image.width) * crop.rect.width) * 600
        let right = (crop.rect.x + Double(maxX + 1) / Double(crop.image.width) * crop.rect.width) * 600
        let top = (crop.rect.y + Double(minY) / Double(crop.image.height) * crop.rect.height) * 800
        let bottom = (crop.rect.y + Double(maxY + 1) / Double(crop.image.height) * crop.rect.height) * 800
        #expect(abs(left - 99) < 1.5 && abs(right - 161) < 1.5, "x \(left)...\(right)")
        // The stroke runs from y 500 to 520 in PDF space = 280 to 300 from the top.
        #expect(abs(top - 279) < 1.5 && abs(bottom - 301) < 1.5, "y \(top)...\(bottom)")
        #expect(abs(crop.rect.width * 600 * 4 - Double(crop.image.width)) < 1e-6)
    }
}
