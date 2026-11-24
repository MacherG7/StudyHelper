import CoreGraphics
import Foundation
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

/// The second chance ("Nachlesen") of the Goodnotes ink path with a mock recognizer that behaves like the real
/// Vision problems: it skips a line of the full-page image, or merges two rows into one low-confidence line of
/// foreign letters, but reads the same ink fine when it gets a crop. Stroke geometry comes from the synthetic
/// Goodnotes fixture (page 1, black layer: lines 2, 3 and 4 are written on separate rows).
@Suite("Nachlesen: übersprungene und verschmolzene Handschriftzeilen")
struct HandwritingRetryTests {
    let truth: GoodnotesGroundTruth
    let layerWidth = 1786  // A4 at the default recognition scale 3

    init() throws { truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth() }

    // MARK: Mock

    func isFullPage(_ image: CGImage) -> Bool { image.width >= 1700 }

    /// Truth lines (page 1) whose ink is on the image: words with dark pixels, grouped per handwritten line.
    func truthLines(on image: CGImage, omitting omitted: Set<String> = []) -> [String: RecognizedLine] {
        let pixels = GoodnotesTestSupport.grayPixels(image)
        var byLine: [String: [RecognizedWord]] = [:]
        for item in truth.items(ofKind: .inkWord, onPage: 1) {
            let key = item.lineID ?? item.id
            guard !omitted.contains(key) else { continue }
            let rect = GoodnotesTestSupport.normalized(item.bbox, truth: truth)
            let dark = GoodnotesTestSupport.darkPixelCount(in: pixels, width: image.width, height: image.height, rect: rect)
            guard dark >= 20 else { continue }
            byLine[key, default: []].append(RecognizedWord(text: item.text ?? "", rect: rect))
        }
        return byLine.mapValues { words in
            let sorted = words.sorted { $0.rect.minX < $1.rect.minX }
            return RecognizedLine(
                text: sorted.map(\.text).joined(separator: " "),
                rect: sorted.reduce(NormalizedRect.zero) { $0.union($1.rect) }, words: sorted)
        }
    }

    /// A line over the dark pixels of a (crop) image, with the given text.
    func inkLine(in image: CGImage, text: String, confidence: Double = 0.9) -> RecognizedLine? {
        let pixels = GoodnotesTestSupport.grayPixels(image)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[y * image.width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let rect = NormalizedRect(
            x: Double(minX) / Double(image.width), y: Double(minY) / Double(image.height),
            width: Double(maxX - minX + 1) / Double(image.width), height: Double(maxY - minY + 1) / Double(image.height))
        let tokens = text.split(separator: " ").map(String.init)
        let each = rect.width / Double(max(1, tokens.count))
        let words = tokens.enumerated().map { index, token in
            RecognizedWord(
                text: token, rect: NormalizedRect(x: rect.x + Double(index) * each, y: rect.y, width: each * 0.9, height: rect.height),
                confidence: confidence)
        }
        return RecognizedLine(text: text, rect: rect, confidence: confidence, words: words)
    }

    func lineRect(_ lineID: String) -> NormalizedRect {
        truth.items(ofKind: .inkWord, onPage: 1).filter { $0.lineID == lineID }
            .map { GoodnotesTestSupport.normalized($0.bbox, truth: truth) }
            .reduce(NormalizedRect.zero) { $0.union($1) }
    }

    func run(_ recognizer: CountingRecognizer, settings: PipelineSettings = PipelineSettings()) async throws -> DigitizationResult {
        let pipeline = DigitizationPipeline(recognizer: recognizer, environment: testEnvironment, settings: settings)
        var result: DigitizationResult?
        try await pipeline.digitizePDFPages(
            data: try Data(contentsOf: GoodnotesFixture.fotosyntheseEditable.url), pageIndices: [0]
        ) { page, _, _ in
            if case .success(let digitization) = page { result = digitization.result }
        }
        return try #require(result)
    }

    func layerCount() throws -> Int {
        let document = try GoodnotesParser.parse(url: GoodnotesFixture.fotosyntheseEditable.url)
        return InkLayerRenderer.penColors(on: document.pages[0]).count
    }

    func output(_ lines: [RecognizedLine]) -> TextRecognitionOutput {
        TextRecognitionOutput(lines: lines, engineVersion: "mock", method: .vision)
    }

    // MARK: Skipped line

    @Test("Eine auf der ganzen Seite übersprungene Zeile wird im Ausschnitt gelesen: Text, Seitenposition, Farbe stimmen, Zeile ist „nachgelesen“ unsicher")
    func skippedLineIsRecovered() async throws {
        let recognizer = CountingRecognizer { _, image, _ in
            if self.isFullPage(image) {
                return self.output(Array(self.truthLines(on: image, omitting: ["p1-line03"]).values))
            }
            return self.output([self.inkLine(in: image, text: "in chemische Energie um")].compactMap { $0 })
        }
        let result = try await run(recognizer)
        let found = try #require(result.lines.first { $0.text == "in chemische Energie um" })
        #expect(found.rect.iou(lineRect("p1-line03")) > 0.7, "Rect \(found.rect) statt \(lineRect("p1-line03"))")
        // Read only in the second pass: uncertain with its own reason, the words keep the recognizer's status.
        #expect(found.status == .uncertain && found.reviewReasons == [.reReadSeparately])
        #expect(found.needsReview && found.words.allSatisfy { $0.status == .confident })
        #expect(result.lines.filter { $0.text != found.text && $0.status != .illegible }.allSatisfy { !$0.reviewReasons.contains(.reReadSeparately) })
        #expect(found.color?.hex == "#000000" && found.words.allSatisfy { $0.color?.hex == "#000000" })
        #expect(found.words.allSatisfy { $0.rect.coverage(by: found.rect.insetBy(dx: -0.002, dy: -0.002)) > 0.9 })
        #expect(result.lines.filter { $0.status == .illegible }.isEmpty, "nichts unleserlich: \(result.lines.map(\.rect))")
        #expect(!result.warnings.contains { $0.contains("unleserlich") })
        #expect(result.lines.count(where: { $0.text.contains("chemische") }) == 1, "keine Doppelung")
        // Reading order: the recovered line sits between the lines above and below it, numbering is complete.
        #expect(result.lines.map(\.order) == Array(0..<result.lines.count))
        let order = result.lines.map(\.text)
        let before = try #require(order.firstIndex { $0.contains("Pflanzen") })
        let after = try #require(order.firstIndex { $0.contains("Chloroplasten") })
        let at = try #require(order.firstIndex { $0 == "in chemische Energie um" })
        #expect(before < at && at < after)
        // One crop was read (plus the full-page calls of the layers).
        let crops = recognizer.calls.filter { $0.imageWidth < 1700 }
        #expect(crops.count == 1)
    }

    @Test("Bleibt der Ausschnitt in der ersten Größe leer, wird er einmal 1,5-fach vergrößert wiederholt")
    func secondAttemptIsEnlarged() async throws {
        let crops = CallNumbering()
        let recognizer = CountingRecognizer { _, image, _ in
            if self.isFullPage(image) {
                return self.output(Array(self.truthLines(on: image, omitting: ["p1-line03"]).values))
            }
            return crops.next() == 0 ? self.output([]) : self.output([self.inkLine(in: image, text: "in chemische Energie um")].compactMap { $0 })
        }
        let result = try await run(recognizer)
        let cropCalls = recognizer.calls.filter { $0.imageWidth < 1700 }
        #expect(cropCalls.count == 2)
        #expect(Double(cropCalls[1].imageWidth) / Double(cropCalls[0].imageWidth) > 1.45)
        #expect(Double(cropCalls[1].imageWidth) / Double(cropCalls[0].imageWidth) < 1.55)
        let found = try #require(result.lines.first { $0.text == "in chemische Energie um" })
        #expect(found.rect.iou(lineRect("p1-line03")) > 0.7, "die Abbildung auf die Seite stimmt auch bei der Vergrößerung")
        #expect(result.lines.filter { $0.status == .illegible }.isEmpty)
    }

    @Test("Liest der Ausschnitt nur Unsicheres, Leeres oder fremde Schrift, bleibt die Stelle unleserlich markiert")
    func unusableCropResultsStayIllegible() async throws {
        let recognizer = CountingRecognizer { _, image, _ in
            if self.isFullPage(image) {
                return self.output(Array(self.truthLines(on: image, omitting: ["p1-line03"]).values))
            }
            return self.output([
                self.inkLine(in: image, text: "schwach", confidence: 0.3),
                self.inkLine(in: image, text: "Міста", confidence: 0.9),
            ].compactMap { $0 })
        }
        let result = try await run(recognizer)
        let illegible = result.lines.filter { $0.status == .illegible }
        #expect(illegible.count == 1)
        #expect(illegible[0].rect.iou(lineRect("p1-line03")) > 0.5)
        #expect(!result.lines.contains { $0.text.contains("schwach") || $0.text.contains("М") })
    }

    // MARK: Merged rows

    /// The full-page answer for the black layer: lines 2 and 3 merged into one tall line of foreign letters.
    func mergedOutput(_ image: CGImage, text: String, confidence: Double) -> TextRecognitionOutput {
        var lines = truthLines(on: image, omitting: ["p1-line02", "p1-line03"])
        let merged = lineRect("p1-line02").union(lineRect("p1-line03"))
        let pixels = GoodnotesTestSupport.grayPixels(image)
        let hasInk = GoodnotesTestSupport.darkPixelCount(in: pixels, width: image.width, height: image.height, rect: lineRect("p1-line02")) > 20
        var result = Array(lines.values)
        lines.removeAll()
        if hasInk {
            let word = RecognizedWord(text: text, rect: merged, confidence: confidence)
            result.append(RecognizedLine(
                text: text, rect: merged, confidence: confidence, words: [word],
                status: confidence < 0.5 ? .uncertain : .confident,
                reviewReasons: confidence < 0.5 ? [.lowConfidence] : []))
        }
        return output(result)
    }

    func medianHeight(_ lines: [RecognizedLine]) -> Double {
        let heights = lines.filter { $0.status != .illegible }.map(\.rect.height).sorted()
        return heights[heights.count / 2]
    }

    @Test("Eine hohe, schwach gelesene Zeile fremder Schrift über zwei Zeilen wird durch die beiden Zeilen ersetzt")
    func tallForeignLineIsSplit() async throws {
        let recognizer = CountingRecognizer { _, image, _ in
            if self.isFullPage(image) { return self.mergedOutput(image, text: "ІŞ Міста", confidence: 0.3) }
            return self.output([self.inkLine(in: image, text: "Reihe gelesen")].compactMap { $0 })
        }
        let result = try await run(recognizer)
        let rows = result.lines.filter { $0.text == "Reihe gelesen" }
        #expect(rows.count == 2, "Zeilen: \(result.lines.map(\.text))")
        #expect(!result.lines.contains { $0.text.contains("М") || $0.text.contains("Ş") })
        for (row, id) in zip(rows.sorted { $0.rect.minY < $1.rect.minY }, ["p1-line02", "p1-line03"]) {
            #expect(row.rect.iou(lineRect(id)) > 0.7, "\(id): \(row.rect) statt \(lineRect(id))")
            #expect(row.color?.hex == "#000000")
        }
        let tall = result.lines.filter { $0.rect.height > 1.8 * medianHeight(result.lines) }
        #expect(tall.isEmpty, "hohe Zeilen: \(tall.map(\.text))")
        #expect(rows.allSatisfy { $0.status == .uncertain && $0.reviewReasons.contains(.reReadSeparately) })
        #expect(result.lines.filter { $0.status == .illegible }.isEmpty)
        #expect(result.lines.map(\.order) == Array(0..<result.lines.count))
    }

    @Test("Auch eine sicher gelesene hohe Zeile, die aus zwei Schriftzeilen besteht, wird zeilenweise nachgelesen")
    func tallConfidentLineOfTwoRowsIsSplit() async throws {
        let recognizer = CountingRecognizer { _, image, _ in
            if self.isFullPage(image) { return self.mergedOutput(image, text: "Pflanzen wandeln in chemische", confidence: 1) }
            return self.output([self.inkLine(in: image, text: "Reihe gelesen")].compactMap { $0 })
        }
        let result = try await run(recognizer)
        #expect(result.lines.count(where: { $0.text == "Reihe gelesen" }) == 2)
        #expect(!result.lines.contains { $0.text.contains("wandeln in chemische") })
    }

    @Test("Eine hohe Zeile bleibt, wenn das Nachlesen nichts ergibt, und ist unsicher mit Grund lowConfidence; kein Strich wird unleserlich")
    func tallLineIsKeptWithoutRetryResult() async throws {
        let recognizer = CountingRecognizer { _, image, _ in
            self.isFullPage(image) ? self.mergedOutput(image, text: "ІŞ Міста", confidence: 0.3) : self.output([])
        }
        let result = try await run(recognizer)
        let kept = try #require(result.lines.first { $0.text == "ІŞ Міста" })
        #expect(kept.status == .uncertain && kept.reviewReasons.contains(.lowConfidence))
        #expect(kept.needsReview)
        #expect(result.lines.filter { $0.status == .illegible }.isEmpty, "die Striche sind von der Zeile erklärt")
    }

    @Test("Eine breite normale Zeile mit hoher Konfidenz wird nicht nachgelesen")
    func normalLinesAreLeftAlone() async throws {
        let recognizer = CountingRecognizer { _, image, _ in
            self.isFullPage(image) ? self.output(Array(self.truthLines(on: image).values)) : self.output([])
        }
        let result = try await run(recognizer)
        #expect(recognizer.calls.allSatisfy { $0.imageWidth >= 1700 }, "kein Ausschnitt gelesen")
        #expect(recognizer.callCount == (try layerCount()))
        #expect(result.lines.filter { $0.status == .illegible }.isEmpty)
    }

    // MARK: Cap

    @Test("Das Limit begrenzt die zusätzlichen Erkennungsaufrufe je Seite; 0 schaltet das Nachlesen aus")
    func cropLimit() async throws {
        let layers = try layerCount()
        func extraCalls(limit: Int) async throws -> (extra: Int, result: DigitizationResult) {
            let recognizer = CountingRecognizer()  // reads nothing at all
            let result = try await run(recognizer, settings: PipelineSettings(retryCropLimit: limit))
            return (recognizer.callCount - layers, result)
        }
        let unlimited = try await extraCalls(limit: 40)
        #expect(unlimited.extra >= 9, "mindestens eine Anfrage je Schriftzeile: \(unlimited.extra)")
        #expect(unlimited.extra <= 40)
        let three = try await extraCalls(limit: 3)
        #expect(three.extra == 3)
        let off = try await extraCalls(limit: 0)
        #expect(off.extra == 0)
        for entry in [unlimited, three, off] {
            // Everything but the exact FreeText box is unread ink and stays illegible.
            let handwriting = entry.result.lines.filter { $0.color?.hex != nil || $0.status == .illegible }
            #expect(handwriting.count(where: { $0.status == .illegible }) >= 9, "ungelesene Tinte bleibt unleserlich")
        }
    }

    // MARK: Illegible areas stay within one row

    @Test("Unleserliche Flächen überspannen nie zwei Zeilen: nichts gelesen ergibt eine Fläche je Schriftzeile")
    func illegibleAreasStayInOneRow() async throws {
        let result = try await run(CountingRecognizer(), settings: PipelineSettings(retryCropLimit: 0))
        let rows = (1...9).map { lineRect(String(format: "p1-line%02d", $0)) }
        for line in result.lines where line.status == .illegible {
            let spanned = rows.filter { row in row.midY > line.rect.minY && row.midY < line.rect.maxY }
            #expect(spanned.count <= 1, "unleserliche Fläche \(line.rect) überspannt \(spanned.count) Zeilen")
        }
    }

    @Test("Dichte Handschrift: zwei Zeilen, deren Kästen sich berühren, ergeben zwei unleserliche Flächen statt einer")
    func denseRowsGiveTwoAreas() {
        // 2 rows of a 14 pt line pitch 20 pt: the boxes of the rows are 6 pt apart (closer than the cluster gap).
        func squiggle(x: Double, y: Double) -> InkStroke {
            InkStroke(points: [PDFPoint(x: x, y: y - 7), PDFPoint(x: x + 9, y: y + 7), PDFPoint(x: x + 18, y: y - 7)], color: .black, width: 1)
        }
        var strokes: [InkStroke] = []
        for rowY in [600.0, 580.0] {
            for word in 0..<10 { strokes.append(squiggle(x: 40 + Double(word) * 22, y: rowY)) }
        }
        let page = GoodnotesPage(index: 0, size: PageSize(width: 400, height: 800), strokes: strokes)
        let areas = IllegibleInk.lines(page: page, recognized: [], shapeRects: [])
        #expect(areas.count == 2, "Flächen: \(areas.map(\.rect))")
        #expect(areas.allSatisfy { $0.rect.height * 800 < 24 })
    }

    @Test("Ein erkanntes Zeilenkästchen erklärt Tinte über den Wortkästchen nahe seiner Wörter, eine Lücke von über 0,5 Zeilenhöhen aber nicht")
    func lineBoxExplainsInkOnlyNearWords() {
        func mark(x: Double) -> InkStroke {
            InkStroke(points: [PDFPoint(x: x - 4, y: 606.5), PDFPoint(x: x + 4, y: 608.5)], color: .black, width: 1)
        }
        let size = PageSize(width: 400, height: 800)
        // The line box spans PDF y 590...610 (20 pt), the words only 595...605; words at x 40...100 and 300...360.
        func rect(_ x0: Double, _ x1: Double, y0: Double, y1: Double) -> NormalizedRect {
            NormalizedRect(x: x0 / 400, y: (800 - y1) / 800, width: (x1 - x0) / 400, height: (y1 - y0) / 800)
        }
        let line = RecognizedLine(text: "links rechts", rect: rect(40, 360, y0: 590, y1: 610), words: [
            RecognizedWord(text: "links", rect: rect(40, 100, y0: 595, y1: 605)),
            RecognizedWord(text: "rechts", rect: rect(300, 360, y0: 595, y1: 605)),
        ])
        // The mark at x 100 sits above the word box but inside the line box next to a word: explained.
        // The mark at x 200 is in the hole between the words: not explained.
        let page = GoodnotesPage(index: 0, size: size, strokes: [mark(x: 100), mark(x: 200)])
        let unexplained = IllegibleInk.unexplainedStrokes(page: page, recognized: [line], shapeRects: [], lineHeight: 16)
        #expect(unexplained.map(\.index) == [1])
    }
}
