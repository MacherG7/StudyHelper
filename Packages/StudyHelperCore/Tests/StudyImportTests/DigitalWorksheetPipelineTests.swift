import CoreGraphics
import Foundation
import ImageIO
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

@Suite("Digitales Arbeitsblatt: eingebetteter Text ohne Erkennung")
struct DigitalWorksheetPipelineTests {
    let recognizer = CountingRecognizer()
    let truth: GoodnotesGroundTruth
    let pages: [PageDigitization]

    init() async throws {
        truth = try DigitalWorksheetFixture.loadTruth()
        let data = try fixtureData(DigitalWorksheetFixture.url)
        let pipeline = DigitizationPipeline(
            recognizer: recognizer, environment: testEnvironment,
            settings: PipelineSettings(multiPass: true, customWords: ["Thylakoid"]))
        pages = try await pipeline.digitizePDF(data: data).pages
    }

    @Test("Der Erkenner wird nie aufgerufen, auch nicht bei eingeschalteter Mehrfacherkennung")
    func recognizerNotCalled() {
        #expect(recognizer.callCount == 0)
        #expect(pages.count == 2)
        #expect(pages.map(\.pageIndex) == [0, 1])
    }

    @Test("Metadaten: Methode eingebetteter PDF-Text, kein Durchlauf, alles sicher")
    func metadata() {
        for page in pages {
            let meta = page.result.metadata
            #expect(meta.method == .embeddedPDFText)
            #expect(meta.passes == 0)
            #expect(meta.engineVersion == nil)
            #expect(meta.customWordsCount == 0)
            #expect(meta.osVersion == "macOS 27.0")
            #expect(page.result.openReviewCount == 0)
            #expect(page.result.warnings.isEmpty)
            #expect(page.result.pageSize.matches(PageSize(width: 595.28, height: 841.89)))
        }
    }

    @Test("Zeilen und Wörter entsprechen der Wahrheit")
    func linesMatchTruth() throws {
        for page in pages {
            let words = allWords(page.result).map(\.word)
            let truthItems = truth.items(ofKind: .worksheetText, onPage: page.pageIndex + 1)
            let expected = truthItems.flatMap { WordTokenizer.tokens(in: $0.text ?? "").map(\.normalized) }.sorted()
            // Compound words such as "Fotosynthese." keep their punctuation in the text, so compare normalized.
            #expect(words.map { WordTokenizer.normalize($0.text) }.sorted() == expected, "Seite \(page.pageIndex + 1)")
            // A lone "." belongs to the preceding word in the PDF text; items without a word are skipped.
            for item in truthItems where !WordTokenizer.tokens(in: item.text ?? "").isEmpty {
                let rect = normalizedRect(of: item, in: truth)
                let found = words.filter { rect.insetBy(dx: -0.01, dy: -0.004).contains(x: $0.rect.midX, y: $0.rect.midY) }
                #expect(!found.isEmpty, "\(item.id)")
                #expect(found.allSatisfy { $0.color?.hex == item.colorHex })
            }
        }
    }

    @Test("Herkunft: jede Zeile ist PDF-Text und wird nie markiert, auch nach dem Speichern als JSON")
    func origin() throws {
        for page in pages {
            #expect(page.result.lines.allSatisfy { $0.origin == .pdfText && WordReview.isEmbedded($0) })
            let decoded = try JSONDecoder().decode(DigitizationResult.self, from: JSONEncoder().encode(page.result))
            #expect(decoded.lines.allSatisfy { $0.origin == .pdfText })
        }
    }

    @Test("Lesereihenfolge von oben nach unten")
    func readingOrder() throws {
        let lines = pages[0].result.lines
        #expect(lines.map(\.order) == Array(0..<lines.count))
        #expect(lines.first?.text == "Arbeitsblatt: Fotosynthese")
        let texts = lines.map(\.text)
        let first = try #require(texts.firstIndex(of: "Das braucht die Pflanze:"))
        let last = try #require(texts.firstIndex(of: "2. Markiere die wichtigsten Begriffe."))
        #expect(first < last)
    }

    @Test("Fett, farbig und unterstrichen sind als Hervorhebungen erfasst")
    func highlights() {
        let result = pages[0].result
        #expect(highlightedWords(result, kind: .bold).contains("chloroplast"))
        #expect(highlightedWords(result, kind: .coloredPen).contains("rotes"))
        #expect(highlightedWords(result, kind: .underline).contains("chlorophyll"))
        #expect(highlightedWords(result, kind: .doubleUnderline) == ["sauerstoff"])
        #expect(result.highlights.allSatisfy { $0.source == .embeddedPDF && $0.status == .confident && $0.confidence == 1 })
        #expect(result.highlights.filter { $0.kind == .coloredPen }.allSatisfy { $0.color != nil })
    }

    @Test("Markdown enthält die Auszeichnungen für fett, unterstrichen und Überschrift")
    func markdown() throws {
        let markdown = pages[0].result.originalMarkdown
        #expect(!markdown.isEmpty)
        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("Arbeitsblatt: Fotosynthese"))
        #expect(markdown.contains("**Chloroplast**"))
        #expect(markdown.contains("<u>Chlorophyll</u>"))
        #expect(markdown.contains("<u>Sauerstoff</u>"))
        #expect(markdown.contains("- Kohlenstoffdioxid aus der Luft"))
        #expect(markdown.contains("Stoff") && markdown.contains("C6H12O6"))
        // Words of the original are all present, in order.
        let page2 = pages[1].result.originalMarkdown
        #expect(page2.contains("**Zellwand**"))
        #expect(!page2.contains("Verborgener"), "unsichtbarer Text bleibt draußen")
    }

    @Test("Seitenbild: JPEG mit Seitenverhältnis A4 bei etwa zweifacher Auflösung")
    func pageImage() throws {
        for page in pages {
            let data = try #require(page.imageData)
            #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 1191 && image.height == 1684)
        }
    }

    @Test("Ergebnis lässt sich als JSON speichern und wieder laden")
    func codable() throws {
        let result = pages[0].result
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(DigitizationResult.self, from: data) == result)
    }
}
