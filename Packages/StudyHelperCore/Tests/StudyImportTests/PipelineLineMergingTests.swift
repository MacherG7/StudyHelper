import Foundation
import StudyCore
import Testing
@testable import StudyImport

@Suite("Pipeline: Zeilen zusammenführen und ordnen")
struct PipelineLineMergingTests {
    func line(_ text: String, x: Double, y: Double, height: Double = 0.03, wordWidth: Double = 0.08,
              color: StudyColor? = nil, status: ConfidenceStatus = .confident) -> RecognizedLine {
        var line = mockLine(text, x: x, y: y, wordWidth: wordWidth, height: height)
        line.color = color
        for i in line.words.indices { line.words[i].color = color }
        line.status = status
        return line
    }

    @Test("Bruchstücke einer Zeile aus verschiedenen Farbebenen werden zu einer Zeile")
    func interleavedFragmentsMerge() {
        let red = StudyColor(hex: "#D32F2F")!
        // Black layer: "Das ist" and "weil" with a gap, red layer: "wichtig" in the gap.
        let black = line("Das ist", x: 0.1, y: 0.2, color: .black)
        let black2 = line("weil", x: 0.40, y: 0.2, color: .black)
        let colored = line("wichtig", x: 0.30, y: 0.2, color: red)
        let merged = LineMerging.mergeLayerFragments([
            .init(line: black, layer: 0), .init(line: black2, layer: 0), .init(line: colored, layer: 1),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].text == "Das ist wichtig weil")
        #expect(merged[0].words.map(\.color) == [.black, .black, red, .black])
        #expect(merged[0].color == nil, "gemischte Farben")
    }

    @Test("Klar getrennte Spalten derselben Bandbreite bleiben getrennte Zeilen")
    func columnsStaySeparate() {
        let left = line("Produzenten", x: 0.1, y: 0.4, color: .black)
        let right = line("Konsumenten", x: 0.7, y: 0.4, color: StudyColor(hex: "#D32F2F"))
        let merged = LineMerging.mergeLayerFragments([.init(line: left, layer: 0), .init(line: right, layer: 1)])
        #expect(merged.count == 2)
    }

    @Test("Untereinander stehende Zeilen werden nicht zusammengeführt")
    func stackedLinesStaySeparate() {
        let a = line("erste", x: 0.1, y: 0.2)
        let b = line("zweite", x: 0.1, y: 0.26)
        #expect(LineMerging.mergeLayerFragments([.init(line: a, layer: 0), .init(line: b, layer: 1)]).count == 2)
    }

    @Test("Zeilen derselben Ebene werden nie zusammengeführt")
    func sameLayerNeverMerges() {
        let a = line("links", x: 0.1, y: 0.2)
        let b = line("rechts", x: 0.25, y: 0.2)
        #expect(LineMerging.mergeLayerFragments([.init(line: a, layer: 0), .init(line: b, layer: 0)]).count == 2)
    }

    @Test("Zusammengeführte Zeile übernimmt den schlechtesten Status")
    func mergedStatus() {
        let a = line("sicher", x: 0.1, y: 0.2)
        let b = line("unsicher", x: 0.2, y: 0.2, status: .uncertain)
        let merged = LineMerging.mergeLayerFragments([.init(line: a, layer: 0), .init(line: b, layer: 1)])
        #expect(merged.count == 1 && merged[0].status == .uncertain)
    }

    @Test("Lesereihenfolge: Bänder von oben nach unten, innerhalb links nach rechts")
    func readingOrder() {
        let lines = [
            line("C", x: 0.1, y: 0.6), line("B", x: 0.6, y: 0.31), line("A", x: 0.1, y: 0.3),
            line("D", x: 0.5, y: 0.6),
        ]
        let ordered = LineMerging.assignReadingOrder(lines)
        #expect(ordered.map(\.text) == ["A", "B", "C", "D"])
        #expect(ordered.map(\.order) == [0, 1, 2, 3])
    }

    @Test("FreeText: exakter Text, Wörter über die Box verteilt")
    func freeText() {
        let box = FreeTextBox(text: "Formel: 6 CO\u{2082} + 6 H\u{2082}O", rect: NormalizedRect(x: 0.1, y: 0.8, width: 0.6, height: 0.04))
        let lines = LineMerging.freeTextLines([box, FreeTextBox(text: "  ", rect: .zero)])
        #expect(lines.count == 1)
        #expect(lines[0].text == "Formel: 6 CO\u{2082} + 6 H\u{2082}O")
        #expect(lines[0].rect == box.rect)
        #expect(lines[0].words.count == 6)
        #expect(lines[0].words.allSatisfy { $0.rect.minX >= 0.1 - 1e-9 && $0.rect.maxX <= 0.7 + 1e-9 })
        #expect(lines[0].words.map(\.rect.minX) == lines[0].words.map(\.rect.minX).sorted())
        #expect(lines[0].status == .confident)
    }

    @Test("Variation: gleiches Wort an anderer Stelle gilt nicht als stabil")
    func variationNeedsSamePlace() {
        let first = [mockLine("Wort", x: 0.1, y: 0.1)]
        let moved = [mockLine("Wort", x: 0.6, y: 0.5)]
        let result = LineMerging.markVariation(first: first, second: moved)
        #expect(result.variedWords == 1)
        let same = LineMerging.markVariation(first: first, second: [mockLine("wort", x: 0.1, y: 0.1)])
        #expect(same.variedWords == 0, "Groß-/Kleinschreibung ist egal")
    }

    // MARK: Verbatim text when merging

    @Test("Zusammengeführte Zeile behält Satzzeichen-Token und Wörter ohne Rechteck (Text aus den Textstücken)")
    func mergedTextIsVerbatim() {
        var left = line("Das ist – wirklich", x: 0.1, y: 0.2, color: .black)
        left.words.removeLast()  // "wirklich": box could not be found
        // The tokenizer drops "?": words are "so" and "ja" only.
        let right = line("so ? ja", x: 0.40, y: 0.2, color: StudyColor(hex: "#D32F2F"))
        #expect(right.words.map(\.text) == ["so", "ja"])
        let merged = LineMerging.mergeLayerFragments([.init(line: left, layer: 0), .init(line: right, layer: 1)])
        #expect(merged.count == 1)
        #expect(merged[0].text == "Das ist – wirklich so ? ja")
        let markdown = OriginalTextMarkdown.build(lines: merged, highlights: [])
        #expect(markdown == "Das ist – wirklich so ? ja")
    }

    @Test("Fragmente ohne Wörter werden nach ihrer Lage im Text eingeordnet")
    func mergedFragmentWithoutWords() {
        let a = line("links", x: 0.1, y: 0.2)
        var b = line("rechts", x: 0.2, y: 0.2)
        b.words = []
        let merged = LineMerging.mergeLayerFragments([.init(line: b, layer: 1), .init(line: a, layer: 0)])
        #expect(merged.count == 1)
        #expect(merged[0].text == "links rechts")
    }

    // MARK: FreeText

    @Test("FreeText mit mehreren Zeilen: eine Zeile je Absatz, Boxhöhe verteilt")
    func freeTextMultiLine() {
        let box = FreeTextBox(text: "Erste Zeile\nZweite – Zeile\r\n\nVierte", rect: NormalizedRect(x: 0.1, y: 0.4, width: 0.5, height: 0.08))
        let lines = LineMerging.freeTextLines([box])
        #expect(lines.map(\.text) == ["Erste Zeile", "Zweite – Zeile", "Vierte"])
        #expect(lines.allSatisfy { !$0.text.contains("\n") })
        // Four rows (the blank one keeps its place): 0.02 each.
        #expect(abs(lines[0].rect.height - 0.02) < 1e-9)
        #expect(abs(lines[0].rect.minY - 0.4) < 1e-9 && abs(lines[1].rect.minY - 0.42) < 1e-9 && abs(lines[2].rect.minY - 0.46) < 1e-9)
        for line in lines {
            #expect(line.words.allSatisfy { $0.rect.minX >= 0.1 - 1e-9 && $0.rect.maxX <= 0.6 + 1e-9 })
            #expect(line.words.allSatisfy { abs($0.rect.minY - line.rect.minY) < 1e-9 })
        }
        #expect(lines[1].words.map(\.text) == ["Zweite", "Zeile"], "Satzzeichen-Token ist kein Wort, steht aber im Text")
        let markdown = OriginalTextMarkdown.build(lines: LineMerging.assignReadingOrder(lines), highlights: [])
        #expect(markdown.contains("Zweite – Zeile"))
    }

    // MARK: Reading order with embedded text

    @Test("Zweispaltiger eingebetteter Text wird nicht verschränkt; Handschrift kommt hinter die Zeile darüber in ihrer Spalte")
    func embeddedColumnOrderIsKept() {
        func embedded(_ text: String, x: Double, y: Double, order: Int) -> RecognizedLine {
            var l = line(text, x: x, y: y, wordWidth: 0.1)
            l.order = order
            return l
        }
        // The extractor delivered the left column first, then the right one.
        let embeddedLines = [
            embedded("L1", x: 0.08, y: 0.20, order: 0), embedded("L2", x: 0.08, y: 0.30, order: 1),
            embedded("L3", x: 0.08, y: 0.40, order: 2),
            embedded("R1", x: 0.55, y: 0.20, order: 3), embedded("R2", x: 0.55, y: 0.30, order: 4),
            embedded("R3", x: 0.55, y: 0.40, order: 5),
        ]
        let note = line("Notiz", x: 0.60, y: 0.35, wordWidth: 0.1)
        let note2 = line("links", x: 0.08, y: 0.45, wordWidth: 0.1)
        let ordered = LineMerging.assignReadingOrder(embedded: embeddedLines, others: [note2, note])
        #expect(ordered.map(\.text) == ["L1", "L2", "L3", "links", "R1", "R2", "Notiz", "R3"])
        #expect(ordered.map(\.order) == Array(0..<8))
        // Without embedded text it is the plain row order.
        #expect(LineMerging.assignReadingOrder(embedded: [], others: [note2, note]).map(\.text) == ["Notiz", "links"])
    }

    // MARK: Fragments of one row (D-041)

    let a4 = PageSize(width: 595.28, height: 841.89)

    @Test("Zwei Bruchstücke einer Reihe (nachgelesenes Wort neben dem Rest) werden eine Zeile")
    func rowFragmentsMerge() {
        // Page 2 of the real note: the re-read word next to the Vision line of the same row.
        var reRead = line("Geosphären", x: 0.065, y: 0.167, height: 0.034, wordWidth: 0.18, status: .uncertain)
        reRead.reviewReasons = [.reReadSeparately]
        reRead.confidence = 0.6
        let rest = line("zusammen. Diese beeinflussen", x: 0.25, y: 0.171, height: 0.031, wordWidth: 0.2)
        let merged = LineMerging.mergeRowFragments([rest, reRead], pageSize: a4)
        #expect(merged.count == 1)
        #expect(merged[0].text == "Geosphären zusammen. Diese beeinflussen")
        #expect(merged[0].words.map(\.text) == (reRead.words + rest.words).map(\.text))
        #expect(merged[0].rect == reRead.rect.union(rest.rect))
        #expect(merged[0].status == .uncertain)
        #expect(merged[0].reviewReasons == [.reReadSeparately])
        #expect(merged[0].confidence == 0.6)
    }

    @Test("Eng gestapelte Reihen dichter Handschrift werden nicht zusammengeführt")
    func denseStackedRowsStaySeparate() {
        // Row pitch 0.018 with boxes 0.033 high: the boxes overlap vertically; the short line of the upper row
        // ends just before the next row begins.
        let upper = line("Eine Landschaft", x: 0.06, y: 0.149, height: 0.033, wordWidth: 0.09)
        let lower = line("zusammen. Diese", x: 0.27, y: 0.167, height: 0.033, wordWidth: 0.1)
        let third = line("eine Einheit", x: 0.06, y: 0.185, height: 0.036, wordWidth: 0.1)
        let lines = LineMerging.mergeRowFragments([upper, lower, third], pageSize: a4)
        #expect(lines.count == 3)
        // List entries of consecutive rows.
        let first = line("- erste", x: 0.03, y: 0.50, height: 0.022, wordWidth: 0.1)
        let second = line("- zweite", x: 0.30, y: 0.522, height: 0.022, wordWidth: 0.1)
        #expect(LineMerging.mergeRowFragments([first, second], pageSize: a4).count == 2)
    }

    @Test("Getrennte Spalte mit großer Lücke bleibt eine eigene Zeile; ein Pfeil verbindet über die Lücke")
    func separateColumnStaysSeparate() {
        let left = line("deutlich schneller", x: 0.08, y: 0.72, height: 0.03, wordWidth: 0.15)
        let column = line("Syndrom", x: 0.45, y: 0.722, height: 0.028, wordWidth: 0.1)
        #expect(LineMerging.mergeRowFragments([left, column], pageSize: a4).count == 2)
        let far = line("Konsumenten", x: 0.7, y: 0.72, height: 0.03, wordWidth: 0.15)
        #expect(LineMerging.mergeRowFragments([left, far], pageSize: a4).count == 2)
        // Page 2: a shape-tool arrow (no ink) between the pieces leaves a gap of two line heights.
        let start = line("- unterer Teil: klimatische Prozesse", x: 0.029, y: 0.514, height: 0.019, wordWidth: 0.115)
        #expect(abs(start.rect.maxX - 0.548) < 0.01)
        var arrowed = line("für Klima verantwortlich", x: 0.626, y: 0.513, height: 0.026, wordWidth: 0.09)
        arrowed.text = "→ für Klima verantwortlich"
        let merged = LineMerging.mergeRowFragments([arrowed, start], pageSize: a4)
        #expect(merged.count == 1)
        #expect(merged.first?.text == "- unterer Teil: klimatische Prozesse → für Klima verantwortlich")
        // The same gap without an arrow: two columns.
        let plain = line("für Klima verantwortlich", x: 0.626, y: 0.513, height: 0.026, wordWidth: 0.09)
        #expect(LineMerging.mergeRowFragments([plain, start], pageSize: a4).count == 2)
    }

    @Test("Bruchstücke verschiedener Farbe, unleserliche und korrigierte Zeilen werden nicht zusammengeführt")
    func differentColorsStaySeparate() {
        let black = line("schwarz", x: 0.1, y: 0.3, color: .black)
        let red = line("rot", x: 0.2, y: 0.3, color: StudyColor(hex: "#D32F2F"))
        #expect(LineMerging.mergeRowFragments([black, red], pageSize: a4).count == 2)
        let blackToo = line("auch", x: 0.2, y: 0.3, color: .black)
        #expect(LineMerging.mergeRowFragments([black, blackToo], pageSize: a4).count == 1)
        var corrected = blackToo
        corrected.isUserCorrected = true
        #expect(LineMerging.mergeRowFragments([black, corrected], pageSize: a4).count == 2)
        let illegible = line("", x: 0.2, y: 0.3, color: .black, status: .illegible)
        #expect(LineMerging.mergeRowFragments([black, illegible], pageSize: a4).count == 2)
    }

    @Test("Kleines Bruchstück vertikal innerhalb einer höheren Zeile gehört zu ihrer Reihe")
    func nestedFragmentMerges() {
        // Page 4: a flat first piece with an arrow inside the band of a taller second piece.
        let small = line("- übertretende Flüsse →", x: 0.055, y: 0.193, height: 0.019, wordWidth: 0.1)
        let tall = line("zerstörerische Kraft, Gefahr für", x: 0.456, y: 0.193, height: 0.034, wordWidth: 0.1)
        #expect(LineMerging.mergeRowFragments([small, tall], pageSize: a4).count == 1)
        #expect(LineMerging.rowFragmentGap(small, tall, pageSize: a4) != nil)
        // The same center offset (0.4 heights) between boxes of equal height: they overlap by only 0.6 – another row.
        let lower = line("nächste Reihe", x: 0.456, y: 0.2006, height: 0.019, wordWidth: 0.1)
        #expect(LineMerging.mergeRowFragments([small, lower], pageSize: a4).count == 2)
    }

    @Test("Mehrere Bruchstücke einer Reihe werden von links nach rechts zu einer Zeile")
    func threeFragmentsMerge() {
        let a = line("weltweit zu", x: 0.055, y: 0.081, height: 0.018, wordWidth: 0.08)
        let b = line("Schädigungen. Diese", x: 0.259, y: 0.080, height: 0.027, wordWidth: 0.11)
        let c = line("fasst man", x: 0.515, y: 0.080, height: 0.026, wordWidth: 0.1)
        let merged = LineMerging.mergeRowFragments([c, a, b], pageSize: a4)
        #expect(merged.map(\.text) == ["weltweit zu Schädigungen. Diese fasst man"])
    }
}
