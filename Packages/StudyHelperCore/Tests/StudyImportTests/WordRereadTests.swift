import CoreGraphics
import Foundation
import StudyCore
import Testing

@testable import StudyImport
@testable import TestFixtures

private struct ListSpellChecker: SpellChecking {
    var words: Set<String>
    func isKnown(_ word: String) -> Bool { words.contains(word) }
    func guesses(for word: String) -> [String] { [] }
}

private let checker = ListSpellChecker(words: [
    "Durch", "die", "Die", "Eingriffe", "des", "Menschen", "Teil", "auch", "Lauch", "alle",
])

/// Answers like Vision: line crops (wide images) and word crops get their own readings; every call is recorded.
private final class FakeReader: WordImageReading, @unchecked Sendable {
    struct Call { var isLine: Bool; var languageCorrection: Bool; var customWords: [String] }
    let word: (Bool) -> [String]
    let line: (Bool) -> [String]
    let delay: Double
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(delay: Double = 0, word: @escaping (Bool) -> [String], line: @escaping (Bool) -> [String]) {
        self.delay = delay
        self.word = word
        self.line = line
    }

    var calls: [Call] { lock.withLock { recorded } }

    func read(_ image: CGImage, languageCorrection: Bool, customWords: [String]) async throws -> TextReading {
        let isLine = Double(image.width) / Double(image.height) > 10
        lock.withLock { recorded.append(Call(isLine: isLine, languageCorrection: languageCorrection, customWords: customWords)) }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let strings = isLine ? line(languageCorrection) : word(languageCorrection)
        return TextReading(observations: strings.isEmpty ? [] : [.init(minX: 0.02, width: 0.96, candidates: strings)])
    }
}

/// A blank "photo" (PNG) and a line of words spread over it.
private func photoRequest(
    _ text: String, wordIndex: Int, terms: Set<String> = [],
    rerank: (@Sendable ([String], String, String) async -> [String])? = nil
) throws -> WordRereadRequest {
    let width = 1200, height = 400
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let png = try #require(PageRenderer.pngData(from: image))
    let tokens = WordTokenizer.tokens(in: text)
    let words = tokens.enumerated().map { index, token in
        RecognizedWord(text: token.original, rect: NormalizedRect(
            x: 0.05 + 0.9 * Double(index) / Double(tokens.count), y: 0.4,
            width: 0.9 / Double(tokens.count) - 0.02, height: 0.1))
    }
    let line = RecognizedLine(
        text: text, rect: NormalizedRect(x: 0.05, y: 0.4, width: 0.9, height: 0.1), words: words, origin: .recognizer)
    return WordRereadRequest(
        background: .image(data: png), line: line, wordIndex: wordIndex, pageLines: [line], terms: terms,
        spellChecker: checker, rerank: rerank)
}

/// Counts calls of the rerank closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]] = []
    func add(_ value: [String]) { lock.withLock { values.append(value) } }
    var all: [[String]] { lock.withLock { values } }
}

@Suite("Wort neu lesen (Vision-Vorschläge)")
struct WordRereadTests {
    @Test("Wort- und Zeilenausschnitt, mit und ohne Sprachkorrektur; Fachbegriffe als customWords; klare Mehrheit ohne Modell")
    func consensus() async throws {
        let reader = FakeReader(
            word: { $0 ? ["Eingriffe", "Eingrife", "Eingrifte"] : ["Eingrite"] },
            line: { $0 ? ["Durch die Eingriffe des Menschen"] : [] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader)
        let counter = Counter()
        let request = try photoRequest(
            "Durch die Eingrifte des Menschen", wordIndex: 2, terms: ["Pedosphäre", "Anthroposphäre"],
            rerank: { candidates, _, _ in counter.add(candidates); return candidates.reversed() })
        let result = try await provider.candidates(for: request)
        #expect(result.first?.text == "Eingriffe")
        #expect(result.first?.sources.contains(.vision) == true)
        #expect(!result.contains { $0.text == "Eingrifte" })
        #expect(result.count <= VisionWordCandidateProvider.maximumCount)
        #expect(counter.all.isEmpty)
        let calls = reader.calls
        #expect(calls.count == 4)
        #expect(calls.filter(\.isLine).count == 2)
        #expect(calls.filter { $0.languageCorrection }.allSatisfy { $0.customWords == ["Anthroposphäre", "Pedosphäre"] })
        #expect(calls.filter { !$0.languageCorrection }.allSatisfy { $0.customWords.isEmpty })
    }

    @Test("Bestätigte Lesung: das Wort wird überall gleich gelesen; Vorschläge nur echte Wörter (D-047)")
    func confirmedReading() async throws {
        let reader = FakeReader(
            word: { _ in ["Lithosphäre", "Lithophäre", "Litosphäre"] },
            line: { _ in ["Durch die Lithosphäre des Menschen", "Durch die Lithophäre des Menschen"] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader)
        let result = try await provider.reread(for: try photoRequest("Durch die Lithosphäre des Menschen", wordIndex: 2))
        #expect(result.readingConfirmed)
        // The mutations ("Lithophäre", "Litosphäre") are no words: nothing is offered.
        #expect(result.candidates.isEmpty)
        #expect(result.ranked.contains { $0.text == "Lithophäre" })
        #expect(result.readings.count == 4)

        // A misreading the other passes repeat: one reading prefers a real word, so it is not confirmed.
        let misread = FakeReader(
            word: { $0 ? ["Eingrifte"] : ["Eingrifte"] },
            line: { $0 ? ["Durch die Eingriffe des Menschen"] : ["Durch die Eingrifte des Menschen"] })
        let other = try await VisionWordCandidateProvider(sources: nil, reader: misread)
            .reread(for: try photoRequest("Durch die Eingrifte des Menschen", wordIndex: 2))
        #expect(!other.readingConfirmed)
        #expect(other.candidates.map(\.text) == ["Eingriffe"])
        #expect(other.candidates.count <= VisionWordCandidateProvider.plausibleCount)
    }

    @Test("Knappe Wahl zwischen bekannten Wörtern: das Modell ordnet um, erfundene Antworten zählen nicht")
    func rerank() async throws {
        let reader = FakeReader(word: { _ in ["Lauch", "auch"] }, line: { _ in ["Teil Lauch alle", "Teil auch alle"] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader)
        let counter = Counter()
        let reordered = try await provider.candidates(for: try photoRequest(
            "Teil lauch alle", wordIndex: 1, rerank: { candidates, before, after in
                counter.add(candidates + [before, after])
                return ["auch", "Lauch"]
            }))
        #expect(reordered.prefix(2).map(\.text) == ["auch", "Lauch"])
        #expect(reordered[0].sources.contains(.model))
        #expect(counter.all == [["Lauch", "auch", "Teil", "alle"]])

        let invented = try await provider.candidates(for: try photoRequest(
            "Teil lauch alle", wordIndex: 1, rerank: { _, _, _ in ["Bauch", "Rauch"] }))
        #expect(invented.prefix(2).map(\.text) == ["Lauch", "auch"])
        #expect(!invented.contains { $0.sources.contains(.model) })
    }

    @Test("Modell antwortet nicht rechtzeitig: Reihenfolge der Lesungen bleibt")
    func rerankTimeout() async throws {
        let reader = FakeReader(word: { _ in ["Lauch", "auch"] }, line: { _ in ["Teil Lauch alle", "Teil auch alle"] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader, rerankTimeout: 0.2)
        let finished = Counter()
        let result = try await provider.candidates(for: try photoRequest(
            "Teil lauch alle", wordIndex: 1, rerank: { candidates, _, _ in
                // Ignores cancellation on purpose and answers far beyond the timeout.
                let until = Date().addingTimeInterval(8)
                while Date() < until { try? await Task.sleep(nanoseconds: 50_000_000) }
                finished.add(["fertig"])
                return candidates.reversed()
            }))
        #expect(result.prefix(2).map(\.text) == ["Lauch", "auch"])
        // The provider did not wait for the model (relative check: robust under load).
        #expect(finished.all.isEmpty)
    }

    @Test("Zeilenausschnitt wird für weitere Wörter derselben Zeile nicht erneut gelesen")
    func lineCache() async throws {
        let reader = FakeReader(word: { _ in ["Eingriffe"] }, line: { _ in ["Durch die Eingriffe des Menschen"] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader)
        let request = try photoRequest("Durch die Eingrifte des Menschen", wordIndex: 2)
        _ = try await provider.candidates(for: request)
        var next = request
        next.wordIndex = 4
        _ = try await provider.candidates(for: next)
        #expect(reader.calls.filter(\.isLine).count == 2)
        #expect(reader.calls.filter { !$0.isLine }.count == 4)
    }

    @Test("Abbruch der Aufgabe beendet das Lesen")
    func cancellation() async throws {
        let reader = FakeReader(delay: 20, word: { _ in ["Eingriffe"] }, line: { _ in [] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader)
        let request = try photoRequest("Durch die Eingrifte des Menschen", wordIndex: 2)
        let task = Task { try await provider.candidates(for: request) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        // Without cancellation the reads would return normally after 20 s; the error proves the cancellation.
        let start = Date()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 15)
    }

    @Test("Ungültiger Wortindex oder unlesbarer Hintergrund")
    func invalid() async throws {
        let reader = FakeReader(word: { _ in ["x"] }, line: { _ in [] })
        let provider = VisionWordCandidateProvider(sources: nil, reader: reader)
        var request = try photoRequest("Durch die Eingrifte", wordIndex: 7)
        let none = try await provider.candidates(for: request)
        #expect(none.isEmpty)
        request.wordIndex = 1
        request.background = .image(data: Data("kein Bild".utf8))
        await #expect(throws: DigitalPageError.unreadableImage) { _ = try await provider.candidates(for: request) }
    }

    @Test("Goodnotes-Striche: nur Striche der eigenen Zeile, ohne Textmarker und Striche außerhalb")
    func strokeSelection() {
        let size = PageSize(width: 600, height: 800)
        func stroke(_ x0: Double, _ x1: Double, y: Double, width: Double = 1) -> InkStroke {
            InkStroke(points: [PDFPoint(x: x0, y: y), PDFPoint(x: x1, y: y)], color: RGBColor(red: 0, green: 0, blue: 0), width: width)
        }
        // Rows: A centred at 0.125 (PDF y 700), B at 0.15 (PDF y 680).
        let page = GoodnotesPage(index: 0, size: size, strokes: [
            stroke(100, 150, y: 700),               // 0: row A
            stroke(100, 150, y: 680),               // 1: row B
            stroke(160, 170, y: 681),               // 2: row B
            stroke(90, 200, y: 680, width: 18),     // 3: highlighter over row B
            stroke(450, 500, y: 680),               // 4: row B, far right of the word
            stroke(100, 150, y: 660),               // 5: row below B (0.175)
        ])
        let a = RecognizedLine(text: "Zeile A", rect: NormalizedRect(x: 0.1, y: 0.11, width: 0.8, height: 0.03))
        let b = RecognizedLine(text: "Zeile B", rect: NormalizedRect(x: 0.1, y: 0.135, width: 0.8, height: 0.03))
        let c = RecognizedLine(text: "Zeile C", rect: NormalizedRect(x: 0.1, y: 0.16, width: 0.8, height: 0.03))
        // A tall word box of row B that reaches into rows A and C.
        let word = NormalizedRect(x: 0.15, y: 0.12, width: 0.15, height: 0.06)
        let crop = WordCropRenderer.expanded(word, dx: 0.02, dy: 0.01)
        let indices = WordCropRenderer.strokeIndices(page: page, rect: word, crop: crop, line: b, pageLines: [a, b, c])
        #expect(indices == [1, 2])
        let image = WordCropRenderer.strokeCrop(
            page: page, rect: word, margin: WordCropRenderer.wordMargin, line: b, pageLines: [a, b, c])
        #expect(image != nil)
    }

    @Test("Echte Texterkennung: ein handschriftähnlich gezeichnetes Wort wird richtig vorgeschlagen",
          .tags(.vision), .enabled(if: VisionTestSupport.isEnabled))
    func visionSmoke() async throws {
        let font = HandwritingFont(size: 30)
        let pixelsPerPoint = 3.0, margin = 20.0
        let words = ["Die", "Eingriffe", "des", "Menschen"]
        var pen = margin
        var layouts: [(strokes: [[Pt]], x0: Double, x1: Double)] = []
        for word in words {
            let layout = font.layoutWord(word, x: pen, baseline: margin + 12)
            layouts.append((layout.strokes, pen, pen + layout.advance))
            pen += layout.advance + font.spaceAdvance * 1.5
        }
        let widthPt = pen + margin, heightPt = 30 + 2 * margin
        let width = Int(widthPt * pixelsPerPoint), height = Int(heightPt * pixelsPerPoint)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for layout in layouts {
            for stroke in layout.strokes {
                guard let first = stroke.first else { continue }
                context.move(to: CGPoint(x: first.x, y: first.y))
                for p in stroke.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
                context.strokePath()
            }
        }
        let image = try #require(context.makeImage())
        let png = try #require(PageRenderer.pngData(from: image))
        let recognized = ["Die", "Eingrifte", "des", "Menschen"]
        let rects = layouts.map { layout -> NormalizedRect in
            let box = boundingBox(of: layout.strokes, pad: 2)
            return NormalizedRect.fromBottomLeft(
                x: box[0], y: box[1], width: box[2], height: box[3], spaceWidth: widthPt, spaceHeight: heightPt)
        }
        let line = RecognizedLine(
            text: recognized.joined(separator: " "), rect: rects[0].union(rects[3]),
            words: zip(recognized, rects).map { RecognizedWord(text: $0, rect: $1) }, origin: .recognizer)
        let provider = VisionWordCandidateProvider()
        let request = WordRereadRequest(
            background: .image(data: png), line: line, wordIndex: 1, pageLines: [line], spellChecker: checker)
        let candidates = try await provider.candidates(for: request)
        #expect(candidates.prefix(5).contains { $0.text.lowercased() == "eingriffe" },
                "Vorschläge: \(candidates.map(\.text))")
        #expect(!candidates.contains { $0.text == "Eingrifte" })
    }
}
