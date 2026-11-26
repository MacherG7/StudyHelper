import CoreGraphics
import CoreText
import Foundation
import StudyCore
import Testing
@testable import StudyImport

/// Text mode with dense handwriting (overlapping line boxes) and printed text next to handwriting: the drawn text never
/// overlaps neighboring rows or fixed text.
@Suite("Digitale Seite: dichte Handschrift und feste Zeilen")
struct DigitalPageDenseTests {
    static let page = PageSize(width: 600, height: 800)

    /// (x, y, width, height) normalized, origin top-left, as in the recognized lines.
    typealias Box = (Double, Double, Double, Double)

    /// The dense page of the developer's file: row pitch about 0.018, boxes about 0.033 high; the middle row is
    /// split into two fragments.
    static let denseBoxes: [(String, Box)] = [
        ("Eine Landschaft setzt sich aus verschiedenen Teilbereichen, des sog.", (0.059, 0.149, 0.901, 0.033)),
        ("\"Geosphären\"", (0.065, 0.167, 0.187, 0.034)),
        ("zusammen. Diese beeinflussen sich gegenseitig und bilden", (0.25, 0.171, 0.701, 0.031)),
        ("eine Einheit, die als System Erde bezeichnet wird.", (0.057, 0.185, 0.712, 0.036)),
    ]

    static func lines(_ boxes: [(String, Box)], paragraph: UUID? = nil) -> [RecognizedLine] {
        boxes.enumerated().map { index, item in
            let (text, b) = item
            return RecognizedLine(
                text: text, rect: NormalizedRect(x: b.0, y: b.1, width: b.2, height: b.3), order: index, paragraphID: paragraph)
        }
    }

    static func runs(_ lines: [RecognizedLine]) -> [DigitalTextRun] {
        DigitalPageText.runs(for: lines, highlights: [], arrows: [], size: page)
    }

    /// The area the drawn text of a run covers vertically: baseline - descent … baseline + ascent.
    static func band(_ layout: VisibleRunLayout) -> ClosedRange<Double> {
        let font = CTFontCreateWithName(DigitalPageText.regularFont as CFString, layout.fontSize, nil)
        return (layout.origin.y - Double(CTFontGetDescent(font)))...(layout.origin.y + Double(CTFontGetAscent(font)))
    }

    static func rect(_ b: Box) -> CGRect {
        let l = NormalizedRect(x: b.0, y: b.1, width: b.2, height: b.3).toBottomLeft(spaceWidth: page.width, spaceHeight: page.height)
        return CGRect(x: l.x, y: l.y, width: l.width, height: l.height)
    }

    /// Drawn boxes (x range from the layout, y range from ascent/descent) per run.
    static func drawnBoxes(_ runs: [DigitalTextRun], _ layouts: [VisibleRunLayout?]) -> [(lineID: UUID, box: CGRect)] {
        zip(runs, layouts).compactMap { run, layout in
            layout.map { layout in
                let y = band(layout)
                return (run.lineID, CGRect(x: layout.origin.x, y: y.lowerBound, width: layout.width, height: y.upperBound - y.lowerBound))
            }
        }
    }

    @Test("Dichte Zeilen: überlappende Zeilenboxen geben keine überlappende Schrift")
    func denseRowsDoNotOverlap() throws {
        let lines = Self.lines(Self.denseBoxes)
        let runs = Self.runs(lines)
        let layouts = DigitalPageText.visibleLayouts(runs)
        let drawn = Self.drawnBoxes(runs, layouts)
        #expect(drawn.count == runs.count)
        for (i, a) in drawn.enumerated() {
            for b in drawn[(i + 1)...] where a.lineID != b.lineID {
                // Rows may touch at the sides, but boxes of different rows never intersect.
                #expect(!a.box.intersects(b.box), "\(a.box) und \(b.box)")
            }
        }
        // Font size from the pitch (0.018 × 800 ≈ 14.4 points), clearly below the one from the box height.
        let heightSize = DigitalPageText.fontSize(forHeight: 0.033 * 800)
        for layout in layouts.compactMap({ $0 }) {
            let band = Self.band(layout)
            #expect(band.upperBound - band.lowerBound <= 0.9 * 0.0198 * 800, "\(layout.fontSize)")
            #expect(layout.fontSize < 0.7 * heightSize)
        }
    }

    @Test("Dichte Zeilen: Fragmente einer Zeile haben Größe und Grundlinie gemeinsam, auch ohne Zusammenführen")
    func sameRowFragmentsShareSizeAndBaseline() throws {
        let lines = Self.lines(Self.denseBoxes)
        let runs = Self.runs(lines)
        let layouts = DigitalPageText.visibleLayouts(runs)
        let byLine = Dictionary(grouping: zip(runs, layouts).compactMap { run, layout in layout.map { (run.lineID, $0) } }, by: \.0)
        let fragments = [lines[1].id, lines[2].id].compactMap { byLine[$0]?.first?.1 }
        #expect(fragments.count == 2)
        #expect(abs(fragments[0].fontSize - fragments[1].fontSize) < 1e-9)
        #expect(abs(fragments[0].origin.y - fragments[1].origin.y) < 1e-9)
        // The first row and the last row are different rows with their own baselines, in reading order.
        let first = try #require(byLine[lines[0].id]?.first?.1), last = try #require(byLine[lines[3].id]?.first?.1)
        #expect(first.origin.y > fragments[0].origin.y && fragments[0].origin.y > last.origin.y)
    }

    @Test("Dichte Zeilen: ein Absatz hat eine Schriftgröße")
    func paragraphUsesOneSize() throws {
        // Different heights and pitches: the lines of the paragraph still share (nearly) one size.
        let boxes: [(String, Box)] = [
            ("Erste Zeile des Absatzes mit etwas Text", (0.1, 0.10, 0.6, 0.030)),
            ("Zweite Zeile des Absatzes mit etwas Text", (0.1, 0.13, 0.6, 0.040)),
            ("Dritte Zeile des Absatzes mit etwas Text", (0.1, 0.16, 0.6, 0.032)),
        ]
        let paragraph = UUID()
        let runs = Self.runs(Self.lines(boxes, paragraph: paragraph))
        let sizes = DigitalPageText.visibleLayouts(runs).compactMap { $0?.fontSize }
        #expect(sizes.count == 3)
        #expect(Set(sizes.map { ($0 * 1000).rounded() }).count == 1, "\(sizes)")
        // Without a paragraph the sizes follow their own lines.
        let single = DigitalPageText.visibleLayouts(Self.runs(Self.lines(boxes))).compactMap { $0?.fontSize }
        #expect(Set(single.map { ($0 * 1000).rounded() }).count > 1, "\(single)")
        #expect(abs(single.min()! - sizes[0]) < 1e-9)
    }

    @Test("Lockere Seite: Schriftgröße weiter aus der Zeilenhöhe, Grundlinie in der Boxmitte")
    func sparsePageUnchanged() throws {
        let lines = DigitalPageLayoutTests.seedLines()
        for line in lines {
            let runs = DigitalPageText.runs(for: [line], highlights: [], arrows: [], size: DigitalPageLayoutTests.seedPage)
            let layouts = DigitalPageText.visibleLayouts(runs).compactMap { $0 }
            let height = line.rect.height * DigitalPageLayoutTests.seedPage.height
            // Words forced smaller keep the baseline of the line, which is centered for the line's own size.
            let lineSize = layouts.map(\.fontSize).max() ?? 0
            let box = line.rect.toBottomLeft(spaceWidth: 600, spaceHeight: 800)
            for layout in layouts {
                #expect(layout.fontSize <= DigitalPageText.fontSize(forHeight: height) + 1e-9)
                let band = Self.band(VisibleRunLayout(origin: layout.origin, fontSize: lineSize, horizontalScale: 1, width: 0))
                #expect(abs((band.lowerBound + band.upperBound) / 2 - (box.y + box.height / 2)) < 1e-6)
            }
        }
        // All lines together: the seed rows are far apart, so each line keeps the size from its height.
        let all = DigitalPageText.runs(for: lines, highlights: [], arrows: [], size: DigitalPageLayoutTests.seedPage)
        let together = DigitalPageText.visibleLayouts(all)
        for line in lines {
            let alone = DigitalPageText.visibleLayouts(
                DigitalPageText.runs(for: [line], highlights: [], arrows: [], size: DigitalPageLayoutTests.seedPage))
            let a = zip(all, together).filter { $0.0.lineID == line.id }.compactMap { $0.1 }
            #expect(a.map(\.fontSize) == alone.compactMap { $0 }.map(\.fontSize))
            #expect(a.map(\.origin.y) == alone.compactMap { $0 }.map(\.origin.y))
        }
    }

    // MARK: Fixed text (printed lines, text in pictures)

    /// Page 3 of the developer's worksheet: a printed question, directly below it handwriting whose box reaches into
    /// the printed line, and more handwriting below.
    static let worksheet: (printed: [(String, Box)], written: [(String, Box)]) = (
        [
            ("1. Notiere die Geosphären, die zusammen das System Erde bilden.", (0.191, 0.426, 0.41, 0.014)),
            ("2. Beschreibe, wo du ...", (0.191, 0.526, 0.475, 0.013)),
        ],
        [
            ("Atmosphäre, Lithosphäre, Hydrosphäre, Biosphäre,", (0.218, 0.43, 0.581, 0.038)),
            ("Antroposphäre, Pedosphäre", (0.219, 0.455, 0.344, 0.042)),
            ("Antrhoposphäre befindet sich dort, Wo Menschen", (0.218, 0.535, 0.642, 0.038)),
        ])

    @Test("Feste Zeile über Handschrift: die Schrift reicht nicht in die gedruckte Zeile")
    func textKeepsClearOfPrintedLineAbove() throws {
        let written = Self.lines(Self.worksheet.written)
        let printed = Self.lines(Self.worksheet.printed)
        let obstacles = DigitalPageText.obstacleRects(of: printed + written, excluding: written, size: Self.page)
        #expect(obstacles.count == 2)
        let runs = Self.runs(written)
        let layouts = DigitalPageText.visibleLayouts(runs, obstacles: obstacles)
        let drawn = Self.drawnBoxes(runs, layouts)
        #expect(drawn.count == 3)
        for (_, box) in drawn {
            for obstacle in obstacles {
                #expect(!box.intersects(obstacle), "Schrift \(box) über gedruckter Zeile \(obstacle)")
            }
        }
        for (i, a) in drawn.enumerated() {
            for b in drawn[(i + 1)...] { #expect(!a.box.intersects(b.box), "\(a.box) und \(b.box)") }
        }
        // Without the obstacle the text of the first row would run into the printed line (the case this test guards).
        let without = Self.drawnBoxes(runs, DigitalPageText.visibleLayouts(runs))
        #expect(obstacles.contains { without[0].box.intersects($0) })
        // The text sits in the lower part of its box, where the ink is, and is still readable (not tiny).
        let box = Self.rect(Self.worksheet.written[0].1)
        #expect(drawn[0].box.midY < box.midY)
        #expect(drawn[0].box.height > 0.45 * Double(box.height) * 0.95)
    }

    @Test("Feste Zeile: Hindernisse auf gleicher Zeile oder ohne Überlappung ändern nichts")
    func irrelevantObstaclesChangeNothing() throws {
        let written = Self.lines(Self.worksheet.written)
        let runs = Self.runs(written)
        let plain = DigitalPageText.visibleLayouts(runs)
        let farAway = [Self.rect((0.2, 0.9, 0.5, 0.02)), Self.rect((0.8, 0.43, 0.1, 0.014))]
        #expect(DigitalPageText.visibleLayouts(runs, obstacles: farAway) == plain)
    }
}
