import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
@testable import StudyImport

/// Text inside images of the page content (pasted or scanned worksheets, maps): SPEC §1 "Eingefügte Bilder und
/// Arbeitsblätter sind Seiteninhalt, teils mit eigenem Text".
@Suite("Text in eingefügten Bildern")
struct ImageTextTests {
    static let grayPixel = MiniObject.stream(
        dictionary: "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8",
        data: Data([128]))

    /// A recognizer that reads "Text im Bild" in the upper part of every document-recognition call.
    static func imageReader() -> CountingRecognizer {
        CountingRecognizer { _, _, options in
            guard options.prefersDocumentRecognition else {
                return TextRecognitionOutput(lines: [], engineVersion: "mock", method: .vision)
            }
            let rect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1)
            let words = [
                RecognizedWord(text: "Text", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), confidence: 1),
                RecognizedWord(text: "im", rect: NormalizedRect(x: 0.35, y: 0.1, width: 0.1, height: 0.1), confidence: 1),
                RecognizedWord(text: "Bild", rect: NormalizedRect(x: 0.5, y: 0.1, width: 0.4, height: 0.1), confidence: 1),
            ]
            return TextRecognitionOutput(
                lines: [RecognizedLine(text: "Text im Bild", rect: rect, confidence: 1, words: words)],
                engineVersion: "mock-image", method: .vision)
        }
    }

    /// Normalized area (top-left origin) of a PDF rect on a 612 × 792 page.
    static func normalized(x: Double, y: Double, width: Double, height: Double) -> NormalizedRect {
        NormalizedRect(x: x / 612, y: (792 - y - height) / 792, width: width / 612, height: height / 792)
    }

    static let textAndImage: Data = {
        let resources = "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> /XObject << /Im1 5 0 R >> >>"
        return MiniPDF.page(
            width: 612, height: 792,
            content: "BT /F1 24 Tf 50 700 Td (Hallo Welt) Tj ET q 300 0 0 300 50 200 cm /Im1 Do Q",
            resources: resources, extra: [grayPixel])
    }()

    @Test("PDF mit Textebene und Bild: der Text im Bild wird einmal als Drucktext erkannt und ins Bild zurückgerechnet")
    func embeddedPageWithImage() async throws {
        let recognizer = Self.imageReader()
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment)
        let page = try #require(try await pipeline.digitizePDF(data: Self.textAndImage).pages.first)
        #expect(recognizer.callCount == 1)
        #expect(recognizer.calls.allSatisfy { $0.options.prefersDocumentRecognition })
        #expect(page.result.metadata.method == .embeddedPDFText)
        #expect(page.result.lines.map(\.text) == ["Hallo Welt", "Text im Bild"])
        let line = try #require(page.result.lines.last)
        let image = Self.normalized(x: 50, y: 200, width: 300, height: 300)
        #expect(line.rect.coverage(by: image.insetBy(dx: -0.02, dy: -0.02)) > 0.99, "\(line.rect) liegt nicht im Bild \(image)")
        #expect(line.words.allSatisfy { $0.rect.coverage(by: line.rect.insetBy(dx: -0.001, dy: -0.001)) > 0.99 })
        #expect(page.result.warnings.isEmpty)
    }

    @Test("Bilderkennung ausgeschaltet: kein Erkennungsaufruf, Warnung „Text im Bild nicht erkannt“")
    func switchedOff() async throws {
        let recognizer = Self.imageReader()
        let pipeline = DigitizationPipeline(
            recognizer: recognizer, environment: testEnvironment, settings: PipelineSettings(recognizesImageText: false))
        let page = try #require(try await pipeline.digitizePDF(data: Self.textAndImage).pages.first)
        #expect(recognizer.callCount == 0)
        #expect(page.result.lines.map(\.text) == ["Hallo Welt"])
        #expect(page.result.warnings == [DigitizationPipeline.imagesWarning])
    }

    @Test("Bildtext, der schon in der Textebene steht, wird nicht doppelt übernommen")
    func duplicatesOfEmbeddedText() {
        let embedded = RecognizedLine(text: "Hallo", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05))
        let same = RecognizedLine(text: "Hallo", rect: NormalizedRect(x: 0.11, y: 0.1, width: 0.28, height: 0.05))
        let other = RecognizedLine(text: "Welt", rect: NormalizedRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))
        #expect(ImageText.withoutDuplicates([same, other], of: [embedded]).map(\.text) == ["Welt"])
    }

    // MARK: Stamps (Goodnotes stores pasted pictures as stamp annotations)

    /// Page with an image stamp (picture) at 100…400 × 300…600, a vector stamp (arrow) and one ink stroke.
    static let stampPage: Data = MiniPDF.page(
        width: 612, height: 792,
        annotations: [
            "<< /Type /Annot /Subtype /Stamp /Rect [100 300 400 600] /AP << /N 8 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [100 650 200 670] /AP << /N 10 0 R >> >>",
            MiniPDF.ink([(60, 100), (90, 110), (120, 100)]),
        ],
        extra: [
            .stream(
                dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 300 300] /Resources << /XObject << /F1 9 0 R >> >>",
                data: Data("/F1 Do".utf8)),
            .stream(
                dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 300 300] /Resources << /XObject << /Im1 11 0 R >> >>",
                data: Data("q 300 0 0 300 0 0 cm /Im1 Do Q".utf8)),
            .stream(dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 100 20]", data: Data("2 w 0 10 m 100 10 l S".utf8)),
            grayPixel,
        ])

    @Test("Nur Stamps, deren Erscheinungsbild ein Rasterbild zeichnet (auch über verschachtelte Formen), gelten als Bild")
    func imageStampsOnly() throws {
        let page = try #require(PDFDocument(data: Self.stampPage)?.page(at: 0)?.pageRef)
        #expect(ImageText.imageStampRects(of: page) == [CGRect(x: 100, y: 300, width: 300, height: 300)])
    }

    @Test("Goodnotes-Seite: das als Stamp eingefügte Bild wird erkannt, der Pfeil-Stamp nicht")
    func goodnotesStampImage() async throws {
        let recognizer = Self.imageReader()
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment)
        let page = try #require(try await pipeline.digitizePDF(data: Self.stampPage).pages.first)
        #expect(page.result.metadata.method == .goodnotesInkLayers)
        let documentCalls = recognizer.calls.filter { $0.options.prefersDocumentRecognition }
        #expect(documentCalls.count == 1, "genau ein Bild")
        let line = try #require(page.result.lines.first { $0.text == "Text im Bild" })
        let stamp = Self.normalized(x: 100, y: 300, width: 300, height: 300)
        #expect(line.rect.coverage(by: stamp.insetBy(dx: -0.02, dy: -0.02)) > 0.99, "\(line.rect) liegt nicht im Stamp \(stamp)")
        #expect(page.result.warnings.allSatisfy { !$0.contains("Bilder") })
    }

    @Test("Kleine Bilder (Symbole unter 1 % der Seite) werden nicht erkannt; überlappende Bilder werden ein Ausschnitt")
    func regionsFilterAndMerge() {
        let merged = ImageText.merged([
            CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 50, y: 50, width: 100, height: 100),
            CGRect(x: 300, y: 300, width: 10, height: 10),
        ])
        #expect(merged.count == 2)
        #expect(merged.contains(CGRect(x: 0, y: 0, width: 150, height: 150)))
        let icon = MiniPDF.page(
            width: 612, height: 792, content: "q 20 0 0 20 50 200 cm /Im1 Do Q",
            resources: "<< /XObject << /Im1 5 0 R >> >>", extra: [Self.grayPixel])
        let page = PDFDocument(data: icon)?.page(at: 0)
        #expect(page.map { ImageText.regions(of: $0, imageStamps: []) } == [])
    }
}
