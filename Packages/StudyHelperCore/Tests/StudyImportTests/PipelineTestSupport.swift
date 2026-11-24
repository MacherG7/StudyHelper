import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import TestFixtures
@testable import StudyImport

/// Mock recognizer that records every call. `handler` decides what each call returns.
final class CountingRecognizer: TextRecognizing, @unchecked Sendable {
    struct Call {
        var imageWidth: Int
        var imageHeight: Int
        var options: TextRecognitionOptions
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (Int, CGImage, TextRecognitionOptions) -> TextRecognitionOutput

    /// - Parameter handler: receives the 0-based call number, the image and the options.
    init(handler: @escaping @Sendable (Int, CGImage, TextRecognitionOptions) -> TextRecognitionOutput = { _, _, _ in
        TextRecognitionOutput(lines: [], engineVersion: "mock", method: .vision)
    }) {
        self.handler = handler
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var callCount: Int { calls.count }

    func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionOutput {
        let number = record(Call(imageWidth: image.width, imageHeight: image.height, options: options))
        return handler(number, image, options)
    }

    private func record(_ call: Call) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
        return recorded.count - 1
    }
}

/// A one-line output with one rect per word, for mock recognizers.
func mockLine(_ text: String, x: Double = 0.1, y: Double = 0.1, wordWidth: Double = 0.1, height: Double = 0.03) -> RecognizedLine {
    var cursor = x
    var words: [RecognizedWord] = []
    for token in WordTokenizer.tokens(in: text) {
        words.append(RecognizedWord(text: token.original, rect: NormalizedRect(x: cursor, y: y, width: wordWidth, height: height)))
        cursor += wordWidth + 0.02
    }
    return RecognizedLine(
        text: text, rect: NormalizedRect(x: x, y: y, width: cursor - x - 0.02, height: height), words: words)
}

func mockOutput(_ lines: RecognizedLine...) -> TextRecognitionOutput {
    TextRecognitionOutput(lines: lines, engineVersion: "mock", method: .vision)
}

let testEnvironment = RecognitionEnvironment(osVersion: "macOS 27.0", deviceModel: "TestMac1,1")

/// A small white image for mock recognition.
func blankImage(width: Int = 200, height: Int = 300) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Truth rectangle (PDF points, origin bottom-left) as a normalized rect.
func normalizedRect(of item: GoodnotesTruthItem, in truth: GoodnotesGroundTruth) -> NormalizedRect {
    let r = item.rect
    return .fromBottomLeft(
        x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height),
        spaceWidth: truth.pageWidth, spaceHeight: truth.pageHeight)
}

func fixtureData(_ url: URL) throws -> Data { try Data(contentsOf: url) }

/// Words of all lines of a result.
func allWords(_ result: DigitizationResult) -> [(line: RecognizedLine, index: Int, word: RecognizedWord)] {
    result.lines.flatMap { line in line.words.enumerated().map { (line, $0.offset, $0.element) } }
}

/// Words that a highlight of `kind` refers to, as normalized texts.
func highlightedWords(_ result: DigitizationResult, kind: HighlightKind) -> [String] {
    let linesByID = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.id, $0) })
    return result.highlights.filter { $0.kind == kind }.flatMap { highlight in
        highlight.words.compactMap { ref in
            linesByID[ref.lineID].flatMap { ref.wordIndex < $0.words.count ? $0.words[ref.wordIndex].text : nil }
        }
    }.map { WordTokenizer.normalize($0) }
}

/// Forwards to another recognizer and records the calls.
final class RecordingRecognizer: TextRecognizing, @unchecked Sendable {
    private let inner: any TextRecognizing
    private let lock = NSLock()
    private var recorded: [TextRecognitionOptions] = []
    private var recordedWidths: [Int] = []

    init(_ inner: any TextRecognizing) { self.inner = inner }

    var options: [TextRecognitionOptions] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Pixel width of every recognized image, in call order.
    var widths: [Int] {
        lock.lock(); defer { lock.unlock() }
        return recordedWidths
    }

    func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionOutput {
        lock.withLock { recordedWidths.append(image.width) }
        record(options)
        return try await inner.recognize(image, options: options)
    }

    private func record(_ options: TextRecognitionOptions) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(options)
    }
}

/// Real-Vision digitizations of the Goodnotes fixtures, computed once and shared by the tests.
actor PipelineFixtureCache {
    struct Run: Sendable {
        var pages: [PageDigitization]
        var recognizerOptions: [TextRecognitionOptions]
        /// Pixel width of the recognized image of each call (same order as `recognizerOptions`).
        var imageWidths: [Int] = []
    }

    static let shared = PipelineFixtureCache()
    private var runs: [String: Task<Run, Error>] = [:]

    /// - Parameters:
    ///   - reduced: the reduced fixture to cross-check with, if any.
    func run(editable: GoodnotesFixture = .fotosyntheseEditable, reduced: GoodnotesFixture?) async throws -> Run {
        let key = editable.rawValue + "|" + (reduced?.rawValue ?? "-")
        if let task = runs[key] { return try await task.value }
        let task = Task { () -> Run in
            let recorder = RecordingRecognizer(VisionTextRecognizer())
            let pipeline = DigitizationPipeline(recognizer: recorder, environment: testEnvironment)
            let results = try await pipeline.digitizePDF(
                data: try Data(contentsOf: editable.url), reducedPDF: try reduced.map { try Data(contentsOf: $0.url) })
            precondition(results.failures.isEmpty, "Seiten fehlgeschlagen: \(results.failures)")
            return Run(pages: results.pages, recognizerOptions: recorder.options, imageWidths: recorder.widths)
        }
        runs[key] = task
        return try await task.value
    }
}
