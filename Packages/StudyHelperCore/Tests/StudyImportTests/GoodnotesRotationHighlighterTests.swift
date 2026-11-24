import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

@Suite("Goodnotes: gedrehte Seiten")
struct GoodnotesRotationTests {
    /// A page 400 × 600 pt, rotated, with a black line in the page content and an ink stroke over the same
    /// line (same center), a scribble and a text box.
    func rotatedPDF(_ rotation: Int) -> Data {
        MiniPDF.page(
            width: 400, height: 600, rotate: rotation, content: "0 G 9 w 110 125 m 140 125 l S",
            annotations: [
                MiniPDF.ink([(110, 125), (140, 125)], width: 9),
                MiniPDF.ink([(50, 300), (60, 330), (70, 300), (80, 330), (90, 300), (100, 330)], width: 2),
                MiniPDF.freeText("Hallo Welt", rect: (50, 500, 250, 560)),
            ])
    }

    /// Where the unrotated point (x, y) (bottom-left origin, 400 × 600) lies on the page displayed rotated.
    func displayed(_ x: Double, _ y: Double, rotation: Int) -> (x: Double, y: Double) {
        switch rotation {
        case 90: return (y, 400 - x)
        case 180: return (400 - x, 600 - y)
        case 270: return (600 - y, x)
        default: return (x, y)
        }
    }

    func centroid(_ image: CGImage) -> (x: Double, y: Double, count: Int) {
        let pixels = GoodnotesTestSupport.grayPixels(image)
        var sx = 0.0, sy = 0.0, n = 0
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[y * image.width + x] < 128 {
                sx += Double(x); sy += Double(y); n += 1
            }
        }
        return n == 0 ? (0, 0, 0) : (sx / Double(n), sy / Double(n), n)
    }

    @Test("Seitengröße, Striche, Textfeld und Rechtecke liegen im gedrehten Seitenraum", arguments: [0, 90, 180, 270])
    func parserRotates(rotation: Int) throws {
        let document = try GoodnotesParser.parse(data: rotatedPDF(rotation))
        #expect(document.variant == .editable)
        let page = try #require(document.pages.first)
        #expect(page.rotation == rotation)
        let swapped = rotation % 180 != 0
        #expect(page.size == PageSize(width: swapped ? 600 : 400, height: swapped ? 400 : 600))

        let scribble = try #require(page.strokes.first { $0.width == 2 })
        let expected = [(50.0, 300.0), (60, 330), (100, 330)].map { displayed($0.0, $0.1, rotation: rotation) }
        let actual = [scribble.points[0], scribble.points[1], scribble.points[5]]
        for (a, e) in zip(actual, expected) { #expect(abs(a.x - e.x) < 0.01 && abs(a.y - e.y) < 0.01, "\(a) statt \(e)") }

        // Text box: unrotated rect (50, 500)-(250, 560) -> normalized top-left origin, then rotated.
        let box = try #require(page.freeTexts.first)
        let corners = [displayed(50, 500, rotation: rotation), displayed(250, 560, rotation: rotation)]
        let size = page.size
        let x0 = min(corners[0].x, corners[1].x) / size.width, x1 = max(corners[0].x, corners[1].x) / size.width
        let top = 1 - max(corners[0].y, corners[1].y) / size.height
        let bottom = 1 - min(corners[0].y, corners[1].y) / size.height
        #expect(abs(box.rect.minX - x0) < 1e-6 && abs(box.rect.maxX - x1) < 1e-6)
        #expect(abs(box.rect.minY - top) < 1e-6 && abs(box.rect.maxY - bottom) < 1e-6)
    }

    @Test("Tintenebene und gerenderte Seite stimmen überein: Schwerpunkt der Linie im Seitenbild und im Strich", arguments: [0, 90, 180, 270])
    func inkLayerMatchesRenderedPage(rotation: Int) throws {
        let data = rotatedPDF(rotation)
        let page = try #require(try GoodnotesParser.parse(data: data).pages.first)
        let pdf = try #require(PDFDocument(data: data)?.page(at: 0))
        let rendered = try #require(PageRenderer.render(page: pdf, scale: 1, includeAnnotations: false))
        #expect(rendered.width == Int(page.size.width) && rendered.height == Int(page.size.height))

        // Only the line stroke counts here: render the black layer without the scribble.
        var onlyLine = page
        onlyLine.strokes = page.strokes.filter { $0.width == 9 }
        let layer = try #require(InkLayerRenderer.renderLayer(of: onlyLine, color: .black, scale: 1))
        #expect(layer.width == rendered.width && layer.height == rendered.height)
        let a = centroid(rendered), b = centroid(layer)
        #expect(a.count > 100 && b.count > 100)
        #expect(abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3, "Seite \(a) / Strich \(b)")
    }

    @Test("Pipeline bei gedrehter Seite: Seitengröße, Bild und unleserliche Tintenfläche im gedrehten Raum")
    func pipelineOnRotatedPage() async throws {
        let recognizer = CountingRecognizer()  // reads nothing
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment)
        let results = try await pipeline.digitizePDF(data: rotatedPDF(90))
        let page = try #require(results.pages.first)
        #expect(results.failures.isEmpty)
        #expect(page.result.pageSize == PageSize(width: 600, height: 400))
        let imageData = try #require(page.imageData)
        let jpeg = try #require(PageRenderer.decodeImage(data: imageData))
        #expect(jpeg.image.width == 1200 && jpeg.image.height == 800, "Seitenbild ist gedreht")
        // The layer is recognized as a whole page; the second chance only reads smaller crops of unread ink.
        #expect(recognizer.calls.contains { $0.imageWidth == 1800 && $0.imageHeight == 1200 })
        #expect(recognizer.calls.allSatisfy { $0.imageWidth <= 1800 && $0.imageHeight <= 1200 })
        // The scribble (unrotated x 50...100, y 300...330) is unread ink: one illegible line at its rotated place.
        let scribble = try #require(page.result.lines.first { $0.status == .illegible })
        let center = displayed(75, 315, rotation: 90)
        #expect(abs(scribble.rect.midX - center.x / 600) < 0.03 && abs(scribble.rect.midY - (1 - center.y / 400)) < 0.03)
        // The text box keeps its exact text, also rotated.
        let box = try #require(page.result.lines.first { $0.text == "Hallo Welt" })
        #expect(box.rect.height > box.rect.width * 0.2)
    }
}

@Suite("Goodnotes: Textmarker in beliebigen Farben")
struct GoodnotesHighlighterTests {
    let size = PageSize(width: 300, height: 300)
    func stroke(_ color: StudyColor, width: Double, opacity: Double = 1, multiply: Bool = false) -> InkStroke {
        InkStroke(
            points: [PDFPoint(x: 20, y: 100), PDFPoint(x: 200, y: 100)], color: color, width: width,
            opacity: opacity, blendsMultiply: multiply)
    }
    let pen = { (w: Double) in
        InkStroke(points: [PDFPoint(x: 20, y: 50), PDFPoint(x: 60, y: 60)], color: .black, width: w)
    }

    @Test("Gelb, Grün und Rosa mit 18 pt sind Textmarker und keine Stiftebene")
    func anyColorWideStrokes() {
        let yellow = StudyColor(red: 1, green: 0.9, blue: 0), green = StudyColor(red: 0.2, green: 0.9, blue: 0.3)
        let pink = StudyColor(red: 1, green: 0.4, blue: 0.7)
        let page = GoodnotesPage(index: 0, size: size, strokes: [
            pen(2), stroke(yellow, width: 18), stroke(green, width: 18), stroke(pink, width: 18), pen(2.5),
        ])
        #expect(page.highlighterStrokes.map(\.color) == [yellow, green, pink])
        #expect(page.penStrokes.count == 2)
        #expect(InkLayerRenderer.penColors(on: page).count == 1, "nur Schwarz bleibt als Stiftebene")
        #expect(GoodnotesPage(index: 0, size: size, strokes: [stroke(green, width: 18)]).highlighterStrokes.count == 1)
    }

    @Test("Transparenz (CA, Multiply) macht auch schmalere Striche zu Textmarkern, dünne Stifte bleiben Stifte")
    func transparencyHints() {
        let blue = StudyColor(red: 0.2, green: 0.4, blue: 1)
        let page = GoodnotesPage(index: 0, size: size, strokes: [
            stroke(blue, width: 8, opacity: 0.4), stroke(blue, width: 6, multiply: true),
            stroke(blue, width: 2, opacity: 0.5), stroke(blue, width: 2),
        ])
        #expect(page.highlighterFlags == [true, true, false, false])
    }

    @Test("Relativ zu den Stiften der Seite: mindestens dreimal so breit und 6 pt")
    func relativeToPenWidths() {
        let red = StudyColor(red: 1, green: 0, blue: 0)
        let page = GoodnotesPage(index: 0, size: size, strokes: [
            pen(1), pen(1), pen(1.5), stroke(red, width: 8), stroke(red, width: 3),
        ])
        #expect(page.highlighterFlags == [false, false, false, true, false])
        // On a page with only thick pens nothing is a highlighter by this rule.
        let thick = GoodnotesPage(index: 0, size: size, strokes: [pen(6), pen(7), pen(8)])
        #expect(thick.highlighterFlags == [false, false, false])
    }

    @Test("Der Parser liest /CA und den Mischmodus Multiply aus dem Erscheinungsbild")
    func parserReadsTransparency() throws {
        let appearance = MiniObject.stream(
            dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 400 600] /Resources << /ExtGState << /GS0 << /BM /Multiply >> >> >>",
            data: Data("/GS0 gs 0 0 0 rg".utf8))
        let pdf = MiniPDF.page(
            width: 400, height: 600,
            annotations: [
                MiniPDF.ink([(10, 10), (100, 10)], color: (0, 0.8, 0), width: 8, extra: "/CA 0.4"),
                MiniPDF.ink([(10, 50), (100, 50)], color: (1, 0.4, 0.7), width: 8, extra: "/AP << /N 8 0 R >>"),
                MiniPDF.ink([(10, 90), (100, 90)], color: (0, 0, 1), width: 2),
            ],
            extra: [appearance])
        let page = try #require(try GoodnotesParser.parse(data: pdf).pages.first)
        #expect(page.strokes.count == 3)
        #expect(abs(page.strokes[0].opacity - 0.4) < 1e-6 && !page.strokes[0].blendsMultiply)
        #expect(page.strokes[1].blendsMultiply && page.strokes[1].opacity == 1)
        #expect(page.strokes[2].opacity == 1 && !page.strokes[2].blendsMultiply)
        #expect(page.highlighterStrokes.count == 2)
        #expect(page.penStrokes.map(\.width) == [2])
    }

    @Test("Ein grüner Textmarker deckt Wörter ab (Hervorhebung), ohne als Text gelesen zu werden")
    func greenHighlighterEmphasis() {
        let width = 300.0, height = 300.0
        func rect(_ x: Double, _ yBottom: Double, _ w: Double, _ h: Double) -> NormalizedRect {
            .fromBottomLeft(x: x, y: yBottom, width: w, height: h, spaceWidth: width, spaceHeight: height)
        }
        let words = [
            RecognizedWord(text: "wichtig", rect: rect(40, 100, 60, 14)),
            RecognizedWord(text: "andere", rect: rect(120, 100, 60, 14)),
        ]
        let line = RecognizedLine(text: "wichtig andere", rect: rect(40, 100, 140, 14), words: words)
        let green = StudyColor(red: 0.2, green: 0.9, blue: 0.3)
        let marker = InkStroke(points: [PDFPoint(x: 38, y: 107), PDFPoint(x: 102, y: 107)], color: green, width: 18)
        let page = GoodnotesPage(index: 0, size: PageSize(width: width, height: height), strokes: [marker])
        let found = GoodnotesEmphasisDetector.detect(page: page, lines: [line])
        #expect(found.filter { $0.kind == .highlighter }.map(\.text) == ["wichtig"])
        #expect(found.first?.color == green)
    }
}

// MARK: - Illegible ink (finding 6)

@Suite("Unleserliche Handschrift wird markiert")
struct IllegibleInkTests {
    let page = PageSize(width: 595, height: 842)

    func scribble(x: Double, y: Double, color: StudyColor = .black) -> InkStroke {
        let points = (0..<7).map { i in PDFPoint(x: x + Double(i) * 6, y: y + (i % 2 == 0 ? 0 : 24)) }
        return InkStroke(points: points, color: color, width: 2)
    }

    func wordRect(x: Double, y: Double) -> NormalizedRect {
        .fromBottomLeft(x: x - 2, y: y - 2, width: 42, height: 28, spaceWidth: page.width, spaceHeight: page.height)
    }

    func line(_ texts: [(String, Double)], y: Double) -> RecognizedLine {
        let words = texts.map { RecognizedWord(text: $0.0, rect: wordRect(x: $0.1, y: y)) }
        let rect = words.reduce(NormalizedRect.zero) { $0.union($1.rect) }
        return RecognizedLine(text: texts.map(\.0).joined(separator: " "), rect: rect, words: words)
    }

    @Test("Ein Wort ohne erkanntes Wort wird zur unleserlichen Zeile an seiner Stelle")
    func missingWordBecomesIllegible() throws {
        let strokes = [50.0, 110, 170].map { scribble(x: $0, y: 700) }
        let goodnotes = GoodnotesPage(index: 0, size: page, strokes: strokes)
        // Words 1 and 3 were read, the middle one was dropped by the recognizer.
        let lines = [line([("eins", 50), ("drei", 170)], y: 700)]
        let result = IllegibleInk.lines(page: goodnotes, recognized: lines, shapeRects: [])
        let illegible = try #require(result.first)
        #expect(result.count == 1)
        #expect(illegible.text.isEmpty && illegible.status == .illegible && illegible.reviewReasons == [.unreadable])
        #expect(illegible.words.isEmpty && illegible.needsReview)
        let expected = wordRect(x: 110, y: 700)
        #expect(abs(illegible.rect.midX - expected.midX) < 0.01 && abs(illegible.rect.midY - expected.midY) < 0.01)
        #expect(illegible.color == .black)
    }

    @Test("Alles erkannt: keine unleserlichen Zeilen")
    func allReadNothingIllegible() {
        let strokes = [50.0, 110, 170].map { scribble(x: $0, y: 700) }
        let lines = [line([("eins", 50), ("zwei", 110), ("drei", 170)], y: 700)]
        #expect(IllegibleInk.lines(page: GoodnotesPage(index: 0, size: page, strokes: strokes), recognized: lines, shapeRects: []).isEmpty)
    }

    @Test("Textmarker, Unterstreichungen, Flecken, Formen und Satzzeichen zählen nicht")
    func exclusions() {
        let red = StudyColor(red: 1, green: 0, blue: 0)
        let strokes = [
            scribble(x: 50, y: 700),
            // Highlighter band over the word.
            InkStroke(points: [PDFPoint(x: 48, y: 712), PDFPoint(x: 100, y: 712)], color: StudyColor(red: 0.2, green: 0.9, blue: 0.3), width: 18),
            // Underline below the word (long and straight).
            InkStroke(points: [PDFPoint(x: 40, y: 690), PDFPoint(x: 140, y: 690)], color: .black, width: 2),
            // Speck (period) and a hyphen-sized dash far from the words.
            InkStroke(points: [PDFPoint(x: 300, y: 500), PDFPoint(x: 301, y: 501)], color: .black, width: 2),
            // Circle drawn around something at the bottom, reported as shape by the detection.
            InkStroke(points: (0..<12).map { i in
                let a = Double(i) / 11 * 2 * Double.pi
                return PDFPoint(x: 400 + 30 * cos(a), y: 300 + 30 * sin(a))
            }, color: red, width: 2),
        ]
        let goodnotes = GoodnotesPage(index: 0, size: page, strokes: strokes)
        let lines = [line([("eins", 50)], y: 700)]
        let circle = NormalizedRect.fromBottomLeft(x: 368, y: 268, width: 64, height: 64, spaceWidth: page.width, spaceHeight: page.height)
        #expect(IllegibleInk.lines(page: goodnotes, recognized: lines, shapeRects: [circle]).isEmpty)
        // Without the shape information the circle is unread ink.
        #expect(IllegibleInk.lines(page: goodnotes, recognized: lines, shapeRects: []).count == 1)
    }

    @Test("Pipeline: Entfernt man ein erkanntes Wort aus der Erkennung, erscheint dort eine unleserliche Zeile")
    func pipelineFindsDroppedWord() async throws {
        let truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        let document = try GoodnotesParser.parse(url: GoodnotesFixture.fotosyntheseEditable.url)
        // Calls are numbered page by page; within a page the number says nothing about the color, the image does.
        let layerCounts = document.pages.map { InkLayerRenderer.penColors(on: $0).count }
        let starts = layerCounts.indices.map { layerCounts[..<$0].reduce(0, +) }
        let dropped = try #require(truth.items(ofKind: .inkWord, onPage: 1).dropFirst(2).first)

        let output: @Sendable (Int, CGImage) -> TextRecognitionOutput = { callNumber, image in
            let pageNumber = (starts.lastIndex { $0 <= callNumber } ?? 0) + 1
            let pixels = GoodnotesTestSupport.grayPixels(image)
            var byLine: [String: [RecognizedWord]] = [:]
            var order: [String] = []
            for item in truth.items(ofKind: .inkWord, onPage: pageNumber) where item.id != dropped.id {
                let rect = GoodnotesTestSupport.normalized(item.bbox, truth: truth)
                let dark = GoodnotesTestSupport.darkPixelCount(in: pixels, width: image.width, height: image.height, rect: rect)
                guard dark >= 20 else { continue }
                let key = item.lineID ?? item.id
                if byLine[key] == nil { order.append(key) }
                byLine[key, default: []].append(RecognizedWord(text: item.text ?? "", rect: rect))
            }
            let lines = order.map { key -> RecognizedLine in
                let words = byLine[key]!.sorted { $0.rect.minX < $1.rect.minX }
                return RecognizedLine(
                    text: words.map(\.text).joined(separator: " "),
                    rect: words.reduce(NormalizedRect.zero) { $0.union($1.rect) }, words: words)
            }
            return TextRecognitionOutput(lines: lines, engineVersion: "mock", method: .vision)
        }

        // The second chance reads crops too (narrower than a whole A4 layer at scale 3, 1786 px); this recognizer reads
        // nothing there and numbers only the layer calls.
        let layerCalls = CallNumbering()
        let recognizer = CountingRecognizer { _, image, _ in
            image.width < 1700 ? mockOutput() : output(layerCalls.next(), image)
        }
        let pipeline = DigitizationPipeline(
            recognizer: recognizer, environment: testEnvironment,
            settings: PipelineSettings(recognizesImageText: false, rereadsUnderlinedLines: true))
        let pages = try await pipeline.digitizePDF(data: try Data(contentsOf: GoodnotesFixture.fotosyntheseEditable.url)).pages
        #expect(pages.count == 3)
        #expect(recognizer.calls.contains { $0.imageWidth < 1700 }, "das Wort wurde noch einmal ausschnittsweise versucht")

        let droppedRect = GoodnotesTestSupport.normalized(dropped.bbox, truth: truth)
        let first = pages[0].result
        let illegible = first.lines.filter { $0.status == .illegible }
        #expect(illegible.count == 1, "unleserlich: \(illegible.map(\.rect)), verworfen: \(droppedRect)")
        let line = try #require(illegible.first)
        #expect(line.text.isEmpty && line.reviewReasons == [.unreadable])
        #expect(droppedRect.coverage(by: line.rect) > 0.5 && line.rect.coverage(by: droppedRect.insetBy(dx: -0.01, dy: -0.01)) > 0.5)
        #expect(first.originalMarkdown.contains("[unleserlich]"))
        #expect(first.warnings.contains { $0.contains("unleserlich") })
        #expect(first.openReviewCount >= 1)
        // Reading order stays complete and the other pages have nothing illegible (no false alarms on shapes).
        #expect(first.lines.map(\.order) == Array(0..<first.lines.count))
        for page in pages.dropFirst() {
            #expect(page.result.lines.filter { $0.status == .illegible }.isEmpty, "Seite \(page.pageIndex + 1)")
        }
    }
}

/// Thread-safe counter for the calls of a mock recognizer that a handler wants to number itself.
final class CallNumbering: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count - 1
    }
}
