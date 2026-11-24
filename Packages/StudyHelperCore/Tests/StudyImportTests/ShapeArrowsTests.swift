import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
@testable import StudyImport

/// Arrows of the Goodnotes shape tool inside a text row (docs/DECISIONS.md D-025).
@Suite("Formpfeile in Textzeilen")
struct ShapeArrowsTests {
    /// Appearance like Goodnotes writes it: a stroked shaft, then the head as a separate open polyline
    /// (form 0…32 × 0…12, shaft from left to right at mid height).
    static func arrowForm(reversed: Bool = false, bothEnds: Bool = false) -> MiniObject {
        var path = reversed ? "2 6 m 30 6 l S 8 10 m 2 6 l 8 2 l S" : "2 6 m 30 6 l S 24 10 m 30 6 l 24 2 l S"
        if bothEnds { path = "2 6 m 30 6 l S 24 10 m 30 6 l 24 2 l S 8 10 m 2 6 l 8 2 l S" }
        return .stream(
            dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 32 12]",
            data: Data("q 0 0 32 12 re W n 2 w 0 0 0 RG \(path) Q".utf8))
    }

    /// Page 600 × 800: an arrow in a row (x 180…212, y 750…762 → top-left y 38…50), a reversed arrow, a box
    /// (rectangle stamp), a plain line and a tall arrow between rows.
    static let page: Data = MiniPDF.page(
        width: 600, height: 800,
        annotations: [
            "<< /Type /Annot /Subtype /Stamp /Rect [180 750 212 762] /AP << /N 10 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [300 700 332 712] /AP << /N 11 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [60 600 240 628] /AP << /N 12 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [60 500 160 512] /AP << /N 13 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [400 300 432 312] /AP << /N 14 0 R >> >>",
        ],
        extra: [
            arrowForm(),
            arrowForm(reversed: true),
            .stream(dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 180 28]",
                    data: Data("q 0 0 180 28 re W n 0 1 0 rg 0 1 0 RG 1 1 178 26 re B Q".utf8)),
            .stream(dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 100 12]",
                    data: Data("q 2 w 0 6 m 100 6 l S Q".utf8)),
            arrowForm(bothEnds: true),
        ])

    @Test("Pfeil-Stamps werden mit Richtung gelesen; Kästen und einfache Linien sind keine Pfeile")
    func readsArrowStamps() throws {
        let page = try #require(PDFDocument(data: Self.page)?.page(at: 0))
        let arrows = ShapeArrows.arrows(of: page)
        #expect(arrows.map(\.symbol) == ["→", "←", "↔"])
        let first = try #require(arrows.first)
        #expect(abs(first.rect.x - 180.0 / 600) < 0.001 && abs(first.rect.y - 38.0 / 800) < 0.001)
    }

    @Test("Richtung aus dem Vektor: waagerecht, senkrecht, schräg, beidseitig")
    func symbols() {
        #expect(ShapeArrows.symbol(dx: 10, dy: 1, bothEnds: false) == "→")
        #expect(ShapeArrows.symbol(dx: -10, dy: 0, bothEnds: false) == "←")
        #expect(ShapeArrows.symbol(dx: 0, dy: 10, bothEnds: false) == "↓")
        #expect(ShapeArrows.symbol(dx: 1, dy: -10, bothEnds: false) == "↑")
        #expect(ShapeArrows.symbol(dx: 5, dy: 5, bothEnds: false) == "↘")
        #expect(ShapeArrows.symbol(dx: -5, dy: -5, bothEnds: false) == "↖")
        #expect(ShapeArrows.symbol(dx: 10, dy: 0, bothEnds: true) == "↔")
    }

    @Test("Geschweifte Verbindung ohne Spitze (ein einzelner Pfad) ist kein Pfeil")
    func bracketIsNoArrow() {
        let bracket = ShapeArrows.Shape(
            subpaths: [[CGPoint(x: 0, y: 30), CGPoint(x: 0, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 0)]],
            hasRectangle: false, bbox: nil)
        #expect(ShapeArrows.direction(of: bracket) == nil)
    }

    static func line(_ text: String, x: Double, width: Double, y: Double = 0.05, words: [(String, Double, Double)] = []) -> RecognizedLine {
        RecognizedLine(
            text: text, rect: NormalizedRect(x: x, y: y, width: width, height: 0.03),
            words: words.map { RecognizedWord(text: $0.0, rect: NormalizedRect(x: $0.1, y: y, width: $0.2, height: 0.03)) })
    }

    @Test("Pfeil wird an seiner Stelle in die Zeile eingesetzt, nach „(“ ohne Leerzeichen")
    func insertsAtPosition() {
        let kausal = Self.line(
            "Kausalkette ( B.S.35)", x: 0.11, width: 0.35,
            words: [("Kausalkette", 0.11, 0.17), ("B.S.35)", 0.36, 0.1)])
        let arrow = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.30, y: 0.058, width: 0.054, height: 0.014), symbol: "→")
        #expect(ShapeArrows.insert([arrow], into: [kausal]).map(\.text) == ["Kausalkette (→ B.S.35)"])

        let start = Self.line("hier: problematische Entwicklungen", x: 0.12, width: 0.6)
        let before = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.06, y: 0.058, width: 0.04, height: 0.014), symbol: "→")
        #expect(ShapeArrows.insert([before], into: [start]).map(\.text) == ["→ hier: problematische Entwicklungen"])

        let end = Self.line("Hydrosphäre", x: 0.05, width: 0.15)
        let after = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.21, y: 0.058, width: 0.04, height: 0.014), symbol: "→")
        #expect(ShapeArrows.insert([after], into: [end]).map(\.text) == ["Hydrosphäre →"])
    }

    @Test("Pfeile zwischen Zeilen, zu hohe Pfeile, weit entfernte und korrigierte Zeilen bleiben unberührt")
    func leavesOthersAlone() {
        let text = Self.line("Bau von Tiefbrunnen", x: 0.1, width: 0.3)
        let between = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.2, y: 0.09, width: 0.05, height: 0.014), symbol: "↓")
        let tall = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.2, y: 0.03, width: 0.05, height: 0.08), symbol: "↓")
        let far = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.8, y: 0.058, width: 0.05, height: 0.014), symbol: "→")
        #expect(ShapeArrows.insert([between, tall, far], into: [text]).map(\.text) == ["Bau von Tiefbrunnen"])

        var corrected = Self.line("Erde", x: 0.1, width: 0.1)
        corrected.isUserCorrected = true
        let next = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.21, y: 0.058, width: 0.04, height: 0.014), symbol: "→")
        #expect(ShapeArrows.insert([next], into: [corrected]).map(\.text) == ["Erde"])
    }

    @Test("Ein schon vorhandener Pfeil wird nicht doppelt eingesetzt")
    func noDuplicate() {
        let line = Self.line("Erde → Boden", x: 0.1, width: 0.3, words: [("Erde", 0.1, 0.08), ("→", 0.19, 0.03), ("Boden", 0.23, 0.17)])
        let arrow = ShapeArrows.Arrow(rect: NormalizedRect(x: 0.19, y: 0.058, width: 0.03, height: 0.014), symbol: "→")
        #expect(ShapeArrows.insert([arrow], into: [line]).map(\.text) == ["Erde → Boden"])
    }

    @Test("Seitenangabe „B.5.35“ wird zu „B.S.35“; Zahlen nach „z.B.“ und echte Dezimalzahlen bleiben")
    func pageReference() {
        #expect(KnownMisreadings.fix("Kausalkette (B.5.35)") == "Kausalkette (B.S.35)")
        #expect(KnownMisreadings.fix("siehe B.5. 12") == "siehe B.S. 12")
        for kept in ["z.B.5.3 Liter", "Aufgabe 5.3", "ca. 5.000 km", "Kap. 5.2"] {
            #expect(KnownMisreadings.fix(kept) == kept, "\(kept)")
        }
    }
}
