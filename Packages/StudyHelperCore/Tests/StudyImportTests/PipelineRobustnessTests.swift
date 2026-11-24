import CoreGraphics
import Foundation
import ImageIO
import StudyCore
import Testing
import TestFixtures
import UniformTypeIdentifiers
@testable import StudyImport

private let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }

/// Throws on selected calls.
final class FlakyRecognizer: TextRecognizing, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var count = 0
    private let failingCalls: Set<Int>
    private let delay: Duration?

    init(failingCalls: Set<Int> = [], delay: Duration? = nil) {
        self.failingCalls = failingCalls
        self.delay = delay
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionOutput {
        let number = next()
        // Swallows cancellation on purpose: the pipeline itself has to notice it between pages.
        if let delay { try? await Task.sleep(for: delay) }
        if failingCalls.contains(number) { throw Failure() }
        return mockOutput(mockLine("Seite \(number)"))
    }

    private func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count - 1
    }
}

// MARK: - Photo orientation (finding 2)

@Suite("Fotos: Ausrichtung wird einmal vor Erkennung und Speicherung hergestellt")
struct PhotoOrientationTests {
    /// 200 × 100 raw pixels, white, with a red block in the top-left corner (40 × 20).
    func markedImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 80, width: 40, height: 20))
        return context.makeImage()!
    }

    func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        let width = image.width, height = image.height
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * width + x) * 4  // row 0 = top
        return pixels[offset] > 200 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80
    }

    @Test("Die acht EXIF-Ausrichtungen drehen und spiegeln den roten Block an die richtige Ecke")
    func uprightPixels() {
        // (orientation, expected size, expected block corner in the upright image)
        let cases: [(CGImagePropertyOrientation, Int, Int, Int, Int)] = [
            (.up, 200, 100, 5, 5), (.upMirrored, 200, 100, 195, 5),
            (.down, 200, 100, 195, 95), (.downMirrored, 200, 100, 5, 95),
            (.leftMirrored, 100, 200, 5, 5), (.right, 100, 200, 95, 5),
            (.rightMirrored, 100, 200, 95, 195), (.left, 100, 200, 5, 195),
        ]
        for (orientation, width, height, x, y) in cases {
            let image = PageRenderer.upright(markedImage(), orientation: orientation)
            #expect(image.width == width && image.height == height, "\(orientation.rawValue): \(image.width)x\(image.height)")
            #expect(isRed(image, x: x, y: y), "Block fehlt an der Ecke (\(x), \(y)) bei Ausrichtung \(orientation.rawValue)")
            // The opposite corner is white.
            #expect(!isRed(image, x: width - 1 - x, y: height - 1 - y))
        }
    }

    @Test("digitizeImage mit Ausrichtung: Erkenner, Seitengröße und gespeichertes JPEG sehen das aufrechte Bild")
    func pipelineUsesUprightImage() async throws {
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("Text")) }
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment, now: now)
        let page = try await pipeline.digitizeImage(markedImage(), orientation: .right)
        #expect(recognizer.calls.map { [$0.imageWidth, $0.imageHeight] } == [[100, 200]])
        #expect(page.result.pageSize == PageSize(width: 100, height: 200))
        let jpeg = try #require(page.imageData)
        let stored = try #require(PageRenderer.decodeImage(data: jpeg))
        #expect(stored.image.width == 100 && stored.image.height == 200)
        #expect(stored.orientation == .up, "gespeichert sind die gedrehten Pixel ohne Ausrichtungsmarke")
        #expect(isRed(stored.image, x: 95, y: 5))
    }

    @Test("digitizeImage(data:) liest die EXIF-Ausrichtung des Kamerafotos")
    func pipelineReadsExifOrientation() async throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, markedImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try #require(PageRenderer.decodeImage(data: data as Data))
        #expect(decoded.orientation == .right && decoded.image.width == 200)

        let recognizer = CountingRecognizer()
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment, now: now)
        let page = try await pipeline.digitizeImage(data: data as Data)
        #expect(recognizer.calls.map { [$0.imageWidth, $0.imageHeight] } == [[100, 200]])
        #expect(page.result.pageSize == PageSize(width: 100, height: 200))
    }

    @Test("Daten, die kein Bild sind, ergeben unreadableImage")
    func notAnImage() async throws {
        let pipeline = DigitizationPipeline(recognizer: CountingRecognizer(), environment: testEnvironment)
        await #expect(throws: DigitizationError.unreadableImage) {
            _ = try await pipeline.digitizeImage(data: Data("kein Bild".utf8))
        }
    }

    @Test("Zeilen mit Konfidenz unter 0,2 sind unleserlich (Grund unreadable), das Markdown zeigt die Marke")
    func lowConfidenceIsIllegible() async throws {
        let recognizer = CountingRecognizer { _, _, _ in
            var weak = mockLine("kryptisch", y: 0.3)
            weak.confidence = 0.1
            var fine = mockLine("lesbar", y: 0.1)
            fine.confidence = 0.8
            var borderline = mockLine("halb", y: 0.5)
            borderline.confidence = 0.3
            borderline.status = .uncertain
            return mockOutput(fine, weak, borderline)
        }
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment, now: now)
        let result = try await pipeline.digitizeImage(blankImage()).result
        let weak = try #require(result.lines.first { $0.text == "kryptisch" })
        #expect(weak.status == .illegible && weak.reviewReasons.contains(.unreadable))
        #expect(weak.words.allSatisfy { $0.status == .illegible })
        #expect(result.lines.first { $0.text == "lesbar" }?.status == .confident)
        #expect(result.lines.first { $0.text == "halb" }?.status == .uncertain)
        #expect(result.originalMarkdown == "lesbar\n\n[unleserlich]\n\nhalb")
        #expect(result.warnings.contains { $0.contains("unleserlich") })
    }
}

// MARK: - Robustness of PDFs (finding 5)

@Suite("PDF-Pipeline: Fehler je Seite, Skalierung, Abbruch")
struct PipelineRobustnessTests {
    func pipeline(_ recognizer: any TextRecognizing, settings: PipelineSettings = PipelineSettings()) -> DigitizationPipeline {
        DigitizationPipeline(recognizer: recognizer, environment: testEnvironment, settings: settings, now: now)
    }

    @Test("Überlange Seite: Skalierung wird begrenzt statt die Seite scheitern zu lassen")
    func oversizedPageIsClamped() async throws {
        let pdf = MiniPDF.page(width: 14_000, height: 300)
        let recognizer = CountingRecognizer { _, _, _ in mockOutput(mockLine("breit")) }
        let results = try await pipeline(recognizer).digitizePDF(data: pdf)
        #expect(results.failures.isEmpty && results.pages.count == 1)
        let call = try #require(recognizer.calls.first)
        #expect(Double(max(call.imageWidth, call.imageHeight)) <= PageRenderer.maxSide, "\(call.imageWidth) x \(call.imageHeight)")
        #expect(call.imageWidth > 1000)
        let page = try #require(results.pages.first)
        #expect(page.imageData != nil)
        #expect(page.result.pageSize.matches(PageSize(width: 14_000, height: 300)))
    }

    @Test("Eine fehlschlagende Seite verliert die anderen nicht")
    func failingPageKeepsOthers() async throws {
        let data = try fixtureData(GoodnotesFixture.fotosyntheseReduced.url)
        let recognizer = FlakyRecognizer(failingCalls: [1])
        let results = try await pipeline(recognizer).digitizePDF(data: data)
        #expect(results.count == 3)
        #expect(results.pages.map(\.pageIndex) == [0, 2])
        let failure = try #require(results.failures.first)
        #expect(results.failures.count == 1 && failure.pageIndex == 1)
        #expect(failure.message.contains("Seite 2"), "Meldung auf Deutsch mit Seitennummer: \(failure.message)")
        if case .failure(let second) = results[1] { #expect(second == failure) } else { Issue.record("Seite 2 müsste fehlgeschlagen sein") }
    }

    @Test("digitizePDFPages liefert die Seiten einzeln mit Fortschritt, auch Fehler")
    func pagesOneByOne() async throws {
        let data = try fixtureData(GoodnotesFixture.fotosyntheseReduced.url)
        var seen: [(Int, Int, Int, Bool)] = []
        try await pipeline(FlakyRecognizer(failingCalls: [2])).digitizePDFPages(data: data) { result, done, total in
            switch result {
            case .success(let page): seen.append((page.pageIndex, done, total, true))
            case .failure(let failure): seen.append((failure.pageIndex, done, total, false))
            }
        }
        #expect(seen.map(\.0) == [0, 1, 2] && seen.map(\.1) == [1, 2, 3] && seen.allSatisfy { $0.2 == 3 })
        #expect(seen.map(\.3) == [true, true, false])
        #expect(DigitizationPipeline.pageCount(ofPDF: data) == 3)
    }

    @Test("pageIndices: nur die gewünschten Seiten werden verarbeitet, Fortschritt zählt nur sie")
    func onlyRequestedPagesAreProcessed() async throws {
        let data = try fixtureData(GoodnotesFixture.fotosyntheseReduced.url)
        let recognizer = CountingRecognizer { number, _, _ in mockOutput(mockLine("Seite \(number)")) }
        var seen: [(page: Int, done: Int, total: Int)] = []
        try await pipeline(recognizer).digitizePDFPages(data: data, pageIndices: [1, 7]) { result, done, total in
            if case .success(let page) = result { seen.append((page.pageIndex, done, total)) }
        }
        #expect(recognizer.callCount == 1, "nur Seite 2 wurde erkannt, die Seiten davor nicht")
        #expect(seen.count == 1 && seen[0].page == 1 && seen[0].done == 1 && seen[0].total == 1)

        let all = CountingRecognizer()
        var count = 0
        try await pipeline(all).digitizePDFPages(data: data, pageIndices: nil) { _, _, total in
            count += 1
            #expect(total == 3)
        }
        #expect(count == 3 && all.callCount == 3, "ohne pageIndices werden alle Seiten verarbeitet")
    }

    @Test("Abbruch stoppt zwischen den Seiten")
    func cancellationStopsEarly() async throws {
        let data = try fixtureData(GoodnotesFixture.fotosyntheseReduced.url)
        let recognizer = FlakyRecognizer(delay: .milliseconds(300))
        let pipeline = pipeline(recognizer)
        let task = Task { try await pipeline.digitizePDF(data: data) }
        while recognizer.callCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(recognizer.callCount == 1, "nach der ersten Seite wurde nicht weitergemacht")
    }

    @Test("Seite mit eingebettetem Text ohne Bild: keine Erkennung, keine Warnung")
    func embeddedTextWithoutImage() async throws {
        let resources = "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>"
        let textOnly = MiniPDF.page(
            width: 612, height: 792, content: "BT /F1 24 Tf 50 700 Td (Hallo Welt) Tj ET", resources: resources)
        let recognizer = CountingRecognizer()
        let page = try #require(try await pipeline(recognizer).digitizePDF(data: textOnly).pages.first)
        #expect(recognizer.callCount == 0)
        #expect(page.result.metadata.method == .embeddedPDFText)
        #expect(page.result.lines.first?.text == "Hallo Welt")
        #expect(page.result.warnings.isEmpty)
    }
}
