import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

@Suite("Eingebetteter PDF-Text: Extraktor")
struct EmbeddedTextExtractorTests {
    let document: PDFDocument
    let truth: GoodnotesGroundTruth

    init() throws {
        document = try #require(PDFDocument(url: DigitalWorksheetFixture.url))
        truth = try DigitalWorksheetFixture.loadTruth()
    }

    func extract(page index: Int) throws -> EmbeddedTextPage {
        let page = try #require(document.page(at: index))
        return try #require(EmbeddedTextExtractor.extract(from: page))
    }

    @Test("Sichtbarer Text wird erkannt, die Seitengröße stimmt")
    func visibleText() throws {
        for index in 0..<2 {
            #expect(EmbeddedTextExtractor.hasVisibleText(in: try #require(document.page(at: index))))
        }
        let page = try extract(page: 0)
        #expect(abs(page.pageSize.width - 595.28) < 0.01)
        #expect(abs(page.pageSize.height - 841.89) < 0.01)
        #expect(page.lines.allSatisfy { $0.status == .confident && $0.confidence == 1 })
        #expect(page.highlights.allSatisfy { $0.source == .embeddedPDF && $0.status == .confident })
    }

    @Test("Jeder Textlauf der Wahrheit steht mit Wortlaut, Farbe und Position im Ergebnis")
    func wordsMatchTruth() throws {
        for pageNumber in 1...2 {
            let page = try extract(page: pageNumber - 1)
            let words = page.lines.flatMap(\.words)
            for item in truth.items(ofKind: .worksheetText, onPage: pageNumber) {
                let rect = normalizedRect(of: item, in: truth)
                let center = { (w: RecognizedWord) in rect.insetBy(dx: -0.01, dy: -0.004).contains(x: w.rect.midX, y: w.rect.midY) }
                let found = words.filter(center).sorted { $0.rect.minX < $1.rect.minX }
                let expected = WordTokenizer.tokens(in: try #require(item.text)).map(\.normalized)
                #expect(found.map { WordTokenizer.normalize($0.text) } == expected, "\(item.id) \(item.text ?? "")")
                for word in found {
                    #expect(word.color?.hex == item.colorHex, "\(item.id): Farbe von \(word.text)")
                }
            }
        }
    }

    @Test("Unsichtbarer Text (Render-Modus 3) wird ignoriert: nur die sichtbaren Wörter der reduzierten Seite")
    func invisibleTextIgnored() throws {
        let reduced = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        let reducedTruth = try GoodnotesFixture.fotosyntheseReduced.loadTruth()
        // Page 3 has only the invisible recognized handwriting: nothing visible, nothing extracted.
        let page3 = try #require(reduced.page(at: 2))
        #expect(!EmbeddedTextExtractor.hasVisibleText(in: page3))
        #expect(EmbeddedTextExtractor.extract(from: page3) == nil)
        #expect(reducedTruth.items(ofKind: .ocrWord, onPage: 3).count >= 5, "die Textebene ist vorhanden")

        // Page 2: visible worksheet text plus the invisible handwriting layer (with deliberate recognition errors).
        let page2 = try #require(reduced.page(at: 1))
        let extracted = try #require(EmbeddedTextExtractor.extract(from: page2))
        let words = extracted.lines.flatMap(\.words).map { WordTokenizer.normalize($0.text) }.sorted()
        let visible = reducedTruth.items(ofKind: .worksheetText, onPage: 2)
            .flatMap { WordTokenizer.tokens(in: $0.text ?? "").map(\.normalized) }.sorted()
        #expect(words == visible)
        #expect(!words.contains("mitochondnen"), "Wort der unsichtbaren Erkennungsebene")
        #expect(!words.contains("zellmembran"))
    }

    @Test("Eine Seite mit sichtbarem Text und unsichtbarer Ebene zählt als Seite mit Text")
    func mixedPage() throws {
        let reduced = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        let page2 = try #require(reduced.page(at: 1))
        #expect(EmbeddedTextExtractor.hasVisibleText(in: page2))
    }

    @Test("Fett, farbig und unterstrichen entsprechen genau den Textläufen der Wahrheit")
    func emphasisMatchesTruth() throws {
        for pageNumber in 1...2 {
            let page = try extract(page: pageNumber - 1)
            let result = DigitizationResult(
                lines: page.lines, highlights: page.highlights,
                metadata: RecognitionMetadata(method: .embeddedPDFText, osVersion: "x", deviceModel: "y"),
                originalMarkdown: "", pageSize: page.pageSize)
            func expectedWords(_ tag: String) -> [String] {
                truth.items(ofKind: .worksheetText, onPage: pageNumber)
                    .filter { ($0.emphasis ?? "").split(separator: ",").contains(Substring(tag)) }
                    .flatMap { WordTokenizer.tokens(in: $0.text ?? "").map(\.normalized) }
            }
            #expect(highlightedWords(result, kind: .bold).sorted() == expectedWords("bold").sorted(), "fett, Seite \(pageNumber)")
            #expect(highlightedWords(result, kind: .coloredPen).sorted() == expectedWords("colored").sorted(), "farbig, Seite \(pageNumber)")
            #expect(highlightedWords(result, kind: .underline).sorted() == expectedWords("underline").sorted(), "unterstrichen, Seite \(pageNumber)")
            #expect(highlightedWords(result, kind: .doubleUnderline).sorted() == expectedWords("doubleUnderline").sorted(), "doppelt, Seite \(pageNumber)")
        }
    }

    @Test("Farbe des Stifts steht am Hervorhebungseintrag")
    func coloredPenColors() throws {
        let page = try extract(page: 0)
        let colors = Set(page.highlights.filter { $0.kind == .coloredPen }.compactMap { $0.color?.hex })
        #expect(colors == ["#D32F2F", "#1565C0", "#2E7D32"])
    }

    @Test("Linie unter dem Titel und Tabellenränder sind keine Unterstreichungen")
    func rulesAndGridAreNotUnderlines() throws {
        let page = try extract(page: 0)
        let underlined = page.highlights.filter { $0.kind == .underline || $0.kind == .doubleUnderline }
        #expect(underlined.count == 3, "Chlorophyll, Sauerstoff (doppelt), Traubenzucker")
        #expect(!underlined.contains { $0.text.contains("Arbeitsblatt") })
        #expect(!underlined.contains { ["Stoff", "Rolle", "Wasser", "Glucose"].contains($0.text) })
    }

    @Test("Aufzählungen, Titel und Tabellenzellen")
    func structure() throws {
        let page = try extract(page: 0)
        let items = page.lines.filter { $0.blockKind == .listItem }
        #expect(items.map(\.text) == ["Kohlenstoffdioxid aus der Luft", "Wasser aus dem Boden", "Licht von der Sonne"])
        #expect(page.lines.first?.blockKind == .title)
        #expect(page.lines.first?.text == "Arbeitsblatt: Fotosynthese")
        // Table cells in one row are separate lines, in reading order.
        let texts = page.lines.map(\.text)
        let table = ["Stoff", "Rolle", "Beispiel", "Wasser", "Ausgangsstoff", "H2O", "Glucose", "Produkt", "C6H12O6"]
        let start = try #require(texts.firstIndex(of: "Stoff"))
        #expect(Array(texts[start..<(start + table.count)]) == table)
    }

    @Test("Zeilen stehen von oben nach unten, Rechtecke liegen auf der Seite")
    func geometry() throws {
        let page = try extract(page: 0)
        let ordered = page.lines.sorted { $0.order < $1.order }
        for (a, b) in zip(ordered, ordered.dropFirst()) where a.rect.minX < b.rect.minX || a.rect.midY <= b.rect.midY {
            #expect(a.rect.midY <= b.rect.midY + 0.01)
        }
        for line in page.lines {
            #expect(line.rect.minX >= 0 && line.rect.maxX <= 1 && line.rect.minY >= 0 && line.rect.maxY <= 1)
        }
        // The title is near the top of an A4 page (baseline 770 of 841.89 pt).
        let title = try #require(page.lines.first)
        #expect(title.rect.minY < 0.1)
    }

    @Test("Seite ohne Text liefert nil")
    func pageWithoutText() throws {
        let editable = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseEditable.url))
        let page1 = try #require(editable.page(at: 0))
        #expect(!EmbeddedTextExtractor.hasVisibleText(in: page1))
        #expect(EmbeddedTextExtractor.extract(from: page1) == nil)
    }

    @Test("Der Text des Arbeitsblatts der bearbeitbaren Fixture-Seite 2 ist sichtbarer Text mit Hervorhebungen")
    func editableWorksheetPage() throws {
        let editable = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseEditable.url))
        let page2 = try #require(editable.page(at: 1))
        let extracted = try #require(EmbeddedTextExtractor.extract(from: page2))
        let kinds = Set(extracted.highlights.map(\.kind))
        #expect(kinds.isSuperset(of: [.bold, .coloredPen, .underline]))
        let underlined = extracted.highlights.first { $0.kind == .underline }
        #expect(underlined?.text.hasPrefix("Erbinformation") == true)
    }
}
