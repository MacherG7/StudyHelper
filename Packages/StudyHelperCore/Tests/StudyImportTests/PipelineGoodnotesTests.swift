import CoreGraphics
import Foundation
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

/// End to end with the real Vision framework on the synthetic Goodnotes fixtures.
@Suite("Pipeline: Goodnotes bearbeitbar mit echter Vision-Erkennung", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
struct PipelineGoodnotesTests {
    let truth: GoodnotesGroundTruth

    init() throws { truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth() }

    func editable() async throws -> PipelineFixtureCache.Run {
        try await PipelineFixtureCache.shared.run(reduced: nil)
    }

    /// Recognized words that sit on the truth item's box.
    func words(on item: GoodnotesTruthItem, in page: PageDigitization) -> [RecognizedWord] {
        let rect = normalizedRect(of: item, in: truth)
        return allWords(page.result).map(\.word).filter {
            $0.rect.coverage(by: rect) > 0.5 || rect.coverage(by: $0.rect) > 0.5
        }
    }

    @Test("Jede Seite: Methode Goodnotes-Ebenen, Version, kein reduziertes PDF, ein Durchlauf")
    func metadata() async throws {
        let run = try await editable()
        #expect(run.pages.count == 3)
        for page in run.pages {
            let meta = page.result.metadata
            #expect(meta.method == .goodnotesInkLayers)
            #expect(meta.engineVersion == VisionTextRecognizer.engineVersion)
            #expect(meta.passes == 1)
            #expect(!meta.usedReducedPDF)
            #expect(meta.osVersion == "macOS 27.0")
            #expect(page.result.pageSize.matches(PageSize(width: 595.28, height: 841.89)))
            let image = try #require(page.imageData)
            #expect(Array(image.prefix(2)) == [0xFF, 0xD8])
        }
    }

    @Test("Je Stiftfarbe genau ein Erkennungsaufruf der ganzen Seite ohne Dokumenterkennung, dazu einer für das eingefügte Arbeitsblatt-Bild")
    func oneCallPerLayer() async throws {
        let run = try await editable()
        let document = try GoodnotesParser.parse(data: try Data(contentsOf: GoodnotesFixture.fotosyntheseEditable.url))
        let layers = document.pages.reduce(0) { $0 + InkLayerRenderer.penColors(on: $1).count }
        let calls = zip(run.recognizerOptions, run.imageWidths).map { (options: $0, width: $1) }
        let fullPage = Int((595.28 * PipelineSettings().recognitionScale).rounded())
        let layerCalls = calls.filter { $0.width == fullPage }
        #expect(layerCalls.count == layers)
        #expect(layers >= 9)
        #expect(layerCalls.allSatisfy { !$0.options.prefersDocumentRecognition && $0.options.languages == ["de-DE"] && $0.options.usesLanguageCorrection })
        // The pasted worksheet image (page 1) is read once, as printed text.
        let imageCalls = calls.filter { $0.options.prefersDocumentRecognition }
        #expect(imageCalls.count == 1)
        // Everything else is a crop of handwriting read again ("Nachlesen", e.g. underlined lines), never document recognition.
        #expect(calls.filter { $0.width != fullPage && !$0.options.prefersDocumentRecognition }.allSatisfy { $0.width < fullPage })
    }

    @Test("Jedes erkannte Handschriftwort hat die Farbe der Wahrheit, und fast alle Wörter werden erkannt")
    func colorsMatchTruth() async throws {
        let run = try await editable()
        var recognized = 0, total = 0
        for page in run.pages {
            for item in truth.items(ofKind: .inkWord, onPage: page.pageIndex + 1) {
                total += 1
                let found = words(on: item, in: page)
                guard !found.isEmpty else { continue }
                recognized += 1
                for word in found {
                    #expect(word.color?.hex == item.colorHex, "\(item.id) \(item.text ?? ""): Farbe \(word.color?.hex ?? "-") statt \(item.colorHex ?? "-")")
                }
            }
        }
        #expect(total == 46)
        #expect(recognized >= 42, "\(recognized) von \(total) Wörtern gefunden")
    }

    @Test("Wortlaut: fast alle Wörter stimmen mit der Wahrheit überein (Vision kann Umlaute in dieser Handschrift verfehlen)")
    func wordsMostlyCorrect() async throws {
        let run = try await editable()
        var correct = 0, total = 0
        var wrong: [String] = []
        for page in run.pages {
            for item in truth.items(ofKind: .inkWord, onPage: page.pageIndex + 1) {
                total += 1
                let expected = WordTokenizer.normalize(item.text ?? "")
                if words(on: item, in: page).contains(where: { WordTokenizer.normalize($0.text) == expected }) {
                    correct += 1
                } else {
                    wrong.append(item.text ?? "")
                }
            }
        }
        #expect(correct >= 40, "falsch: \(wrong)")
    }

    @Test("FreeText wird als Zeile mit dem exakten Text übernommen")
    func freeTextExact() async throws {
        let run = try await editable()
        let item = try #require(truth.items(ofKind: .freeText, onPage: 1).first)
        let line = try #require(run.pages[0].result.lines.first { $0.text == item.text })
        #expect(line.status == .confident && line.confidence == 1)
        #expect(line.origin == .freeText)
        // Handwriting is recognized (even where Vision reports confidence 1), the worksheet text is embedded.
        let ink = run.pages.flatMap(\.result.lines).filter { $0.color != nil && $0.origin != .pdfText && $0.origin != .freeText }
        #expect(!ink.isEmpty && ink.allSatisfy { $0.origin == .recognizer })
        #expect(run.pages[1].result.lines.first { $0.text == "Arbeitsblatt: Die Zelle" }?.origin == .pdfText)
        #expect(run.pages.flatMap(\.result.lines).allSatisfy { $0.origin != nil })
        #expect(line.text == "Formel: 6 CO\u{2082} + 6 H\u{2082}O \u{2192} C\u{2086}H\u{2081}\u{2082}O\u{2086} + 6 O\u{2082}")
        let rect = normalizedRect(of: item, in: truth)
        #expect(line.rect.iou(rect) > 0.8)
        #expect(run.pages[0].result.originalMarkdown.contains(item.text ?? "?"))
    }

    @Test("Stempel (Pfeile, Linien) und Tabellenlinien ergeben keinen Text")
    func stampsProduceNoText() async throws {
        let run = try await editable()
        for page in run.pages {
            let textItems = truth.items(ofKind: .inkWord, onPage: page.pageIndex + 1)
                + truth.items(ofKind: .freeText, onPage: page.pageIndex + 1)
                + truth.items(ofKind: .worksheetText, onPage: page.pageIndex + 1)
            let textRects = textItems.map { normalizedRect(of: $0, in: truth).insetBy(dx: -0.004, dy: -0.004) }
            for (line, index, word) in allWords(page.result) {
                let onText = textRects.contains { word.rect.coverage(by: $0) > 0.4 }
                #expect(onText, "Seite \(page.pageIndex + 1): „\(word.text)“ (Zeile „\(line.text)“, Wort \(index)) liegt auf keinem Text")
            }
        }
    }

    @Test("Handschrift, Arbeitsblatt-Text und FreeText stehen gemeinsam in Lesereihenfolge")
    func readingOrder() async throws {
        let run = try await editable()
        let page1 = run.pages[0].result.lines
        #expect(page1.map(\.order) == Array(0..<page1.count))
        #expect(page1.first?.text.lowercased().hasPrefix("fotosynthese") == true)
        #expect(page1.last?.text.hasPrefix("Formel:") == true)
        let page2 = run.pages[1].result.lines
        // Worksheet text and handwriting are merged: the printed title first, the sentence about the nucleus before the note.
        #expect(page2.first?.text == "Arbeitsblatt: Die Zelle")
        let texts = page2.map(\.text)
        #expect(try #require(texts.firstIndex { $0.hasPrefix("Der Zellkern") }) < (try #require(texts.firstIndex { $0.hasPrefix("Merke:") })))
        for page in run.pages {
            for (a, b) in zip(page.result.lines, page.result.lines.dropFirst()) {
                #expect(a.rect.midY <= b.rect.midY + 0.5 * max(a.rect.height, b.rect.height), "Seite \(page.pageIndex + 1): \(a.text) vor \(b.text)")
            }
        }
    }

    @Test("Seite 2: Text des Arbeitsblatts ist übernommen und seine Formatierung als Hervorhebung erfasst")
    func worksheetTextOnEditablePage() async throws {
        let run = try await editable()
        let result = run.pages[1].result
        let sentence = try #require(result.lines.first { $0.text.hasPrefix("Der Zellkern") })
        #expect(sentence.text == "Der Zellkern enthält die Erbinformation.")
        #expect(sentence.words[1].color?.hex == "#D32F2F")
        #expect(highlightedWords(result, kind: .underline).contains("erbinformation"))
        #expect(highlightedWords(result, kind: .bold).contains("merke"))
        #expect(result.originalMarkdown.contains("<u>Erbinformation.</u>"))
        #expect(result.originalMarkdown.contains("**Merke:**"))
    }

    @Test("Die drei Textmarker sind als Hervorhebung vorhanden und stehen im Markdown")
    func highlighters() async throws {
        let run = try await editable()
        let result = run.pages[0].result
        let highlighters = result.highlights.filter { $0.kind == .highlighter }
        #expect(highlighters.count == 3)
        #expect(highlighters.allSatisfy { $0.source == .goodnotesAnnotation && $0.status == .confident })
        #expect(highlightedWords(result, kind: .highlighter).sorted() == ["chloroplasten", "gespeichert", "sauerstoff", "traubenzucker"])
        #expect(result.originalMarkdown.contains("==Chloroplasten=="))
        #expect(result.originalMarkdown.contains("==Sauerstoff=="))
        #expect(result.highlights.contains { $0.kind == .underline && $0.text.lowercased() == "fotosynthese" })
    }

    @Test("Markdown jeder Seite ist nicht leer und enthält die erkannten Wörter")
    func markdown() async throws {
        let run = try await editable()
        for page in run.pages {
            #expect(!page.result.originalMarkdown.isEmpty)
            #expect(page.result.originalMarkdown.contains(page.result.lines.last?.words.first?.text ?? "?"))
        }
    }
}

@Suite("Pipeline: Abgleich mit dem reduzierten Goodnotes-PDF")
struct PipelineReducedPDFTests {
    let truth = try! GoodnotesFixture.fotosyntheseEditable.loadTruth()
    let reducedTruth = try! GoodnotesFixture.fotosyntheseReduced.loadTruth()

    @Test("Mit passendem reduziertem PDF: Wörter, die vom Goodnotes-Text abweichen, sind unsicher mit Grund mismatchWithReducedPDF", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func mismatchesFlagged() async throws {
        let run = try await PipelineFixtureCache.shared.run(reduced: .fotosyntheseReduced)
        var flaggedByOCRError = 0
        for page in run.pages {
            #expect(page.result.metadata.usedReducedPDF)
            for error in reducedTruth.ocrErrors where error.page == page.pageIndex + 1 {
                let item = try #require(truth.item(withID: error.inkWordID))
                let rect = normalizedRect(of: item, in: truth)
                let found = allWords(page.result).map(\.word).filter { $0.rect.coverage(by: rect) > 0.5 || rect.coverage(by: $0.rect) > 0.5 }
                let word = try #require(found.first, "\(error.truth) nicht erkannt")
                let sameAsGoodnotes = WordTokenizer.normalize(word.text) == WordTokenizer.normalize(error.recognized)
                if sameAsGoodnotes {
                    // Vision made the very same mistake: nothing to flag (and nothing to confirm either).
                    #expect(!word.reviewReasons.contains(.mismatchWithReducedPDF), "\(error.truth)")
                } else {
                    #expect(word.status == .uncertain, "\(error.truth) → \(word.text)")
                    #expect(word.reviewReasons.contains(.mismatchWithReducedPDF), "\(error.truth) → \(word.text)")
                    flaggedByOCRError += 1
                }
            }
        }
        // Vision reads Chlorophyll, Mitochondrien and Ökosystem correctly where Goodnotes did not.
        #expect(flaggedByOCRError >= 3)
        let mismatches = run.pages.flatMap { allWords($0.result) }.filter { $0.word.reviewReasons.contains(.mismatchWithReducedPDF) }
        #expect(mismatches.map { WordTokenizer.normalize($0.word.text) }.contains("mitochondrien"))
        #expect(mismatches.map { WordTokenizer.normalize($0.word.text) }.contains("ökosystem"))
        #expect(mismatches.map { WordTokenizer.normalize($0.word.text) }.contains("chlorophyll"))
    }

    @Test("Übereinstimmende Wörter sind als bestätigt vermerkt und bleiben sicher", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func matchesConfirmed() async throws {
        let run = try await PipelineFixtureCache.shared.run(reduced: .fotosyntheseReduced)
        let words = run.pages.flatMap { allWords($0.result) }.map(\.word)
        let confirmed = words.filter { $0.reviewReasons.contains(.confirmedByReducedPDF) }
        #expect(confirmed.count > 30)
        #expect(confirmed.allSatisfy { $0.status == .confident })
    }

    @Test("Ohne reduziertes PDF gibt es keine Abgleich-Markierungen", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func noReducedNoFlags() async throws {
        let run = try await PipelineFixtureCache.shared.run(reduced: nil)
        let reasons = Set(run.pages.flatMap { allWords($0.result) }.flatMap(\.word.reviewReasons))
        #expect(!reasons.contains(.mismatchWithReducedPDF) && !reasons.contains(.confirmedByReducedPDF))
    }

    @Test("Reduziertes PDF einer anderen Notiz wird nicht verwendet und mit Hinweis gemeldet", arguments: [GoodnotesFixture.andereNotizReduced, .andereGroesseReduced])
    func incompatibleReducedPDF(other: GoodnotesFixture) async throws {
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Wort")) }
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment)
        let pages = try await pipeline.digitizePDF(
            data: try Data(contentsOf: GoodnotesFixture.fotosyntheseEditable.url), reducedPDF: try Data(contentsOf: other.url)).pages
        for page in pages {
            #expect(!page.result.metadata.usedReducedPDF)
            #expect(page.result.warnings.contains { $0.contains("reduzierte PDF gehört nicht zu dieser Notiz") })
        }
    }
}
