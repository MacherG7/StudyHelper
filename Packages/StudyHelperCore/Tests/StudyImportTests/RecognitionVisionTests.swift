import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
import TestFixtures
import Vision
@testable import StudyImport

@Suite("Erkennung: Vision")
struct RecognitionVisionTests {
    @Test("customWords, Sprachen und Sprachkorrektur werden an die Vision-Anfrage übergeben")
    func requestConfiguration() {
        let options = TextRecognitionOptions(
            languages: ["de-DE", "en-US"], usesLanguageCorrection: false,
            customWords: ["Thylakoidmembran", "Chlorophyllmolekül"])
        let request = VisionTextRecognizer.makeRequest(options: options)
        #expect(request.customWords == ["Thylakoidmembran", "Chlorophyllmolekül"])
        #expect(request.recognitionLanguages == ["de-DE", "en-US"])
        #expect(!request.usesLanguageCorrection)
        #expect(request.recognitionLevel == .accurate)
        #expect(request.revision == VisionTextRecognizer.latestRevision)
    }

    @Test("Standardoptionen: Deutsch, Sprachkorrektur an, keine eigenen Wörter")
    func defaultRequest() {
        let request = VisionTextRecognizer.makeRequest(options: TextRecognitionOptions())
        #expect(request.customWords.isEmpty)
        #expect(request.recognitionLanguages == ["de-DE"])
        #expect(request.usesLanguageCorrection)
    }

    @Test("Die verwendete Revision ist die neueste unterstützte und steht im Versionstext")
    func engineVersion() {
        #expect(VisionTextRecognizer.latestRevision == VNRecognizeTextRequest.supportedRevisions.max())
        #expect(VisionTextRecognizer.engineVersion == "VNRecognizeTextRequest rev \(VisionTextRecognizer.latestRevision)")
    }

    @Test("Zuordnung der Konfidenz: unter 0,5 ist unsicher mit Grund lowConfidence")
    func confidenceStatus() {
        #expect(VisionLineBuilder.status(for: 0.49).0 == .uncertain)
        #expect(VisionLineBuilder.status(for: 0.49).1 == [.lowConfidence])
        #expect(VisionLineBuilder.status(for: 0.5).0 == .confident)
        #expect(VisionLineBuilder.status(for: 1).1.isEmpty)
    }

    @Test("Vision-Koordinaten (unten links) werden in Seitenanteile mit Ursprung oben links umgerechnet")
    func coordinateConversion() {
        let rect = NormalizedRect.fromVision(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))
        #expect(abs(rect.x - 0.1) < 1e-9 && abs(rect.y - 0.2) < 1e-9)
        #expect(abs(rect.width - 0.2) < 1e-9 && abs(rect.height - 0.1) < 1e-9)
    }

    @Test("Zeilen werden von oben nach unten und links nach rechts nummeriert")
    func numbering() {
        let a = mockLine("unten", x: 0.1, y: 0.5)
        let b = mockLine("links", x: 0.1, y: 0.2)
        let c = mockLine("rechts", x: 0.6, y: 0.2)
        let sorted = VisionLineBuilder.sortAndNumber([a, c, b])
        #expect(sorted.map(\.text) == ["links", "rechts", "unten"])
        #expect(sorted.map(\.order) == [0, 1, 2])
    }

    @Test("Zeile aus Vision-Text: Satzzeichen-Token und Wörter ohne Box fehlen in den Wörtern, aber nicht im Markdown")
    func lineWithMissingWordBoxes() {
        let text = "Preis a – b ≈ 3 × 4 ? ok"
        let line = VisionLineBuilder.makeLine(
            text: text, confidence: 0.9, alternatives: [], lineRect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.03),
            blockKind: nil,
            wordRect: { range in
                text[range] == "ok" ? nil : NormalizedRect(x: 0.1, y: 0.1, width: 0.05, height: 0.03)
            })
        #expect(line.text == text)
        #expect(line.words.map(\.text) == ["Preis", "a", "b", "3", "4"], "kein „–“, „≈“, „×“, „?“, „ok“")
        #expect(OriginalTextMarkdown.build(lines: [line], highlights: []) == text)
    }

    // MARK: Real Vision on the synthetic handwriting

    func inkLayerImage(pageIndex: Int, color: StudyColor, scale: Double = 3) throws -> CGImage {
        let data = try Data(contentsOf: GoodnotesFixture.fotosyntheseEditable.url)
        let document = try GoodnotesParser.parse(data: data)
        let page = document.pages[pageIndex]
        return try #require(InkLayerRenderer.renderLayer(of: page, color: color, scale: scale))
    }

    @Test("Vision liest auf der schwarzen Tintenebene von Seite 1 „Fotosynthese“", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func visionFindsFotosynthese() async throws {
        let image = try inkLayerImage(pageIndex: 0, color: .black)
        let output = try await VisionTextRecognizer().recognize(image, options: TextRecognitionOptions(prefersDocumentRecognition: false))
        let text = output.lines.map(\.text).joined(separator: "\n").lowercased()
        #expect(text.contains("fotosynthese"), "erkannt: \(text)")
        #expect(output.method == .vision)
        #expect(output.engineVersion == VisionTextRecognizer.engineVersion)
        for line in output.lines {
            #expect(line.rect.minX >= 0 && line.rect.maxX <= 1.001 && line.rect.minY >= 0 && line.rect.maxY <= 1.001)
            #expect(!line.words.isEmpty)
            #expect(line.candidates.allSatisfy { $0 != line.text })
        }
    }

    @Test("Vision liest auf Seite 3 „Ökosystem“ mit Umlaut", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func visionFindsOekosystem() async throws {
        let image = try inkLayerImage(pageIndex: 2, color: .black)
        let output = try await VisionTextRecognizer().recognize(image, options: TextRecognitionOptions(prefersDocumentRecognition: false))
        let text = output.lines.map(\.text).joined(separator: "\n").lowercased()
        #expect(text.contains("ökosystem"), "erkannt: \(text)")
    }

    @Test("Wortrechtecke liegen im Zeilenrechteck und tragen die Konfidenz der Zeile", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func wordBoxes() async throws {
        let image = try inkLayerImage(pageIndex: 0, color: .black)
        let output = try await VisionTextRecognizer().recognize(image, options: TextRecognitionOptions(prefersDocumentRecognition: false))
        let line = try #require(output.lines.first { $0.text.lowercased().contains("fotosynthese") })
        let word = try #require(line.words.first { $0.text.lowercased().contains("fotosynthese") })
        #expect(word.rect.coverage(by: line.rect) > 0.8)
        #expect(word.confidence == line.confidence)
        // The heading is on rule 1 of the page: near the top, left margin at x = 80 pt of 595 pt.
        #expect(line.rect.minY < 0.2)
        #expect(abs(line.rect.minX - 80.0 / 595.28) < 0.06)
    }

    @Test("Dokumenterkennung ergänzt die Zeilenart; Text und Wortrechtecke bleiben die der klassischen Anfrage", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func documentStructure() async throws {
        guard #available(iOS 26, macOS 26, *) else { return }
        let document = try #require(PDFDocument(url: DigitalWorksheetFixture.url))
        let page = try #require(document.page(at: 0))
        let image = try #require(PageRenderer.render(page: page, scale: 3))
        let classic = try await VisionTextRecognizer().recognize(image, options: TextRecognitionOptions(prefersDocumentRecognition: false))
        let structured = try await VisionTextRecognizer().recognize(image, options: TextRecognitionOptions(prefersDocumentRecognition: true))
        #expect(classic.method == .vision)
        #expect(structured.lines.count == classic.lines.count)
        #expect(structured.lines.map(\.confidence) == classic.lines.map(\.confidence))
        // Bullet markers are dropped from list items (the Markdown prefix replaces them).
        #expect(!structured.lines.filter { $0.blockKind == .listItem }.contains { $0.text.hasPrefix("\u{2022}") })
        // Printed lists and tables are what the structure request is good at.
        #expect(structured.method == .visionDocument)
        #expect(structured.engineVersion.contains("RecognizeDocumentsRequest"))
        #expect(structured.lines.filter { $0.blockKind == .listItem }.count >= 3)
        #expect(structured.lines.filter { $0.blockKind == .tableCell }.count >= 6)
        #expect(classic.lines.allSatisfy { $0.blockKind == nil })
    }

    @Test("Gedruckter Text des Arbeitsblatts wird von Vision korrekt gelesen (Vergleich mit dem eingebetteten Text)", .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func visionOnPrintedWorksheet() async throws {
        let document = try #require(PDFDocument(url: DigitalWorksheetFixture.url))
        let page = try #require(document.page(at: 0))
        let image = try #require(PageRenderer.render(page: page, scale: 3))
        let output = try await VisionTextRecognizer().recognize(image, options: TextRecognitionOptions(prefersDocumentRecognition: false))
        let recognized = Set(output.lines.flatMap { WordTokenizer.tokens(in: $0.text).map(\.folded) })
        let embedded = try #require(EmbeddedTextExtractor.extract(from: page))
        let truth = Set(embedded.lines.flatMap { WordTokenizer.tokens(in: $0.text).map(\.folded) })
        let found = truth.intersection(recognized).count
        #expect(Double(found) / Double(truth.count) > 0.8, "\(found) von \(truth.count) Wörtern")
    }
}
