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
}
