import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Turns photos, scans and PDFs into stored text (SPEC §2). One call digitizes a whole source once; later steps
/// work on the stored result and never trigger a new recognition.
///
/// What happens to which input:
/// - **Photo or scan** (`digitizeImage`): Vision on the image, optionally a second pass on a rescaled image.
/// - **Goodnotes "bearbeitbar" PDF**: every pen color is rendered as its own layer (black ink on white) and
///   recognized separately, so each word knows its color; visible worksheet text is taken from the PDF;
///   FreeText boxes are taken verbatim; highlighter, underline and circle emphasis come from the annotations.
///   With a matching reduced PDF the recognized words are cross-checked against its text layer.
/// - **Other PDF with visible embedded text**: text and formatting are taken from the PDF, no recognition.
/// - **PDF without embedded text** (scan, reduced Goodnotes PDF alone): the page is rendered and recognized like an image.
///
/// The pipeline is a value type; the recognizer does the heavy work off the main thread.
public struct DigitizationPipeline: Sendable {
    public let recognizer: any TextRecognizing
    public let environment: RecognitionEnvironment
    public let settings: PipelineSettings
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - recognizer: `VisionTextRecognizer()` in the app, a mock in tests.
    ///   - environment: OS version and device model to record (`.current` in the app).
    ///   - settings: multi-pass, custom words, scales.
    ///   - now: clock for the recorded date (tests).
    public init(
        recognizer: any TextRecognizing = VisionTextRecognizer(),
        environment: RecognitionEnvironment = .current,
        settings: PipelineSettings = PipelineSettings(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recognizer = recognizer
        self.environment = environment
        self.settings = settings
        self.now = now
    }

    // MARK: Images

    /// Below this confidence a recognized line counts as illegible (instead of merely uncertain).
    public static let illegibleConfidence = 0.2
    /// Pages whose embedded text comes with raster images covering at least this share of the page get a warning.
    static let imageWarningCoverage = 0.08

    /// Digitizes a photo or scan. The pixels are first turned upright according to `orientation` (the EXIF
    /// orientation of camera photos), once, so that recognition, the stored JPEG and the rects all agree.
    /// The returned image data is the upright image as JPEG, `pageSize` its size in pixels.
    public func digitizeImage(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> PageDigitization {
        try Task.checkCancellation()
        var image = PageRenderer.upright(image, orientation: orientation)
        let longest = Double(max(image.width, image.height))
        if longest > PageRenderer.maxSide, let reduced = PageRenderer.scaled(image, by: PageRenderer.maxSide / longest) {
            image = reduced
        }
        let outcome = try await recognizeWithPasses(image, prefersDocumentRecognition: settings.prefersDocumentRecognition)
        var warnings: [String] = []
        if outcome.lines.isEmpty { warnings.append("Auf dem Bild wurde kein Text erkannt.") }
        if outcome.variedWords > 0 { warnings.append(Self.variationWarning(outcome.variedWords)) }
        let lines = LineMerging.assignReadingOrder(outcome.lines)
        let illegible = lines.filter { $0.status == .illegible }.count
        if illegible > 0 { warnings.append(Self.illegibleWarning(illegible)) }
        let result = makeResult(
            lines: lines, highlights: [], method: outcome.method, engineVersion: outcome.engineVersion,
            passes: outcome.passes, usedReducedPDF: false,
            pageSize: PageSize(width: Double(image.width), height: Double(image.height)), warnings: warnings)
        return PageDigitization(
            pageIndex: 0, result: result,
            imageData: PageRenderer.jpegData(from: image, quality: settings.imageQuality))
    }

    /// Digitizes an image file's data (JPEG, HEIC, PNG, ...), reading its EXIF orientation.
    /// - Throws: `DigitizationError.unreadableImage` if the data is not an image.
    public func digitizeImage(data: Data) async throws -> PageDigitization {
        guard let decoded = PageRenderer.decodeImage(data: data) else { throw DigitizationError.unreadableImage }
        return try await digitizeImage(decoded.image, orientation: decoded.orientation)
    }

    // MARK: PDFs

    /// Number of pages of a PDF, or nil if it cannot be read.
    public static func pageCount(ofPDF data: Data) -> Int? {
        PDFDocument(data: data)?.pageCount
    }

    /// Digitizes every page of a PDF and returns all results at once. A page that cannot be processed becomes a
    /// `PageFailure` in its place; the other pages are kept. For long documents prefer `digitizePDFPages`, which
    /// hands over the pages one by one so that images can be saved and released.
    /// - Parameters:
    ///   - data: the PDF (Goodnotes editable or reduced export, worksheet, scan).
    ///   - reducedPDF: the reduced Goodnotes export of the same note, to cross-check the recognition.
    ///     Ignored (with a warning on each page) if it does not belong to `data`.
    ///   - progress: called after each page with (pages done, page count).
    /// - Throws: `DigitizationError` for unreadable, encrypted or empty PDFs; `CancellationError` if the task is cancelled.
    public func digitizePDF(
        data: Data, reducedPDF: Data? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [PageResult] {
        var results: [PageResult] = []
        try await digitizePDFPages(data: data, reducedPDF: reducedPDF) { result, done, total in
            results.append(result)
            progress?(done, total)
        }
        return results
    }

    /// Digitizes a PDF page by page and calls `onPage` after each one with (result, pages done, page count).
    /// Only one page is held in memory by the pipeline at a time; the next page starts when `onPage` returns.
    /// A failing page is reported as `.failure`, the run continues. Cancellation (checked between pages and
    /// between ink layers) stops early with `CancellationError`.
    /// - Parameter pageIndices: 0-based pages to process; nil means all pages. Other pages are skipped without any
    ///   work, and `pagesDone`/`pageCount` in `onPage` count only the processed pages. Indices outside the document are ignored.
    public func digitizePDFPages(
        data: Data, reducedPDF: Data? = nil, pageIndices: Set<Int>? = nil,
        onPage: (_ result: PageResult, _ pagesDone: Int, _ pageCount: Int) async throws -> Void
    ) async throws {
        guard let document = PDFDocument(data: data) else { throw DigitizationError.notAPDF }
        if document.isLocked, !document.unlock(withPassword: "") { throw DigitizationError.encrypted }
        guard document.pageCount > 0 else { throw DigitizationError.emptyDocument }

        let goodnotes = try parseGoodnotes(data)
        var reducedDocument: GoodnotesDocument?
        var reducedWarning: String?
        if let reducedPDF, let goodnotes, goodnotes.variant == .editable {
            do {
                let parsed = try GoodnotesParser.parse(data: reducedPDF)
                switch GoodnotesPairing.check(editable: goodnotes, reduced: parsed) {
                case .compatible: reducedDocument = parsed
                default: reducedWarning = "Das reduzierte PDF gehört nicht zu dieser Notiz und wurde nicht zum Abgleich verwendet."
                }
            } catch {
                reducedWarning = "Das reduzierte PDF konnte nicht gelesen werden und wurde nicht zum Abgleich verwendet."
            }
        }

        let wanted = (0..<document.pageCount).filter { pageIndices?.contains($0) ?? true }
        for (position, index) in wanted.enumerated() {
            try Task.checkCancellation()
            let result: PageResult
            do {
                guard let pdfPage = document.page(at: index) else { throw DigitizationError.renderingFailed(pageIndex: index) }
                var digitization: PageDigitization
                if let goodnotes, goodnotes.variant == .editable, index < goodnotes.pages.count {
                    digitization = try await digitizeEditablePage(
                        index: index, goodnotes: goodnotes.pages[index], pdfPage: pdfPage,
                        reducedPage: reducedDocument.flatMap { index < $0.pages.count ? $0.pages[index] : nil })
                    if let reducedWarning { digitization.result.warnings.append(reducedWarning) }
                } else if goodnotes?.variant != .reduced, let embedded = EmbeddedTextExtractor.extract(from: pdfPage) {
                    digitization = try embeddedPage(index: index, embedded: embedded, pdfPage: pdfPage)
                } else {
                    digitization = try await recognizeRenderedPage(index: index, pdfPage: pdfPage)
                }
                result = .success(digitization)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = .failure(Self.failure(for: error, pageIndex: index))
            }
            try await onPage(result, position + 1, wanted.count)
        }
    }

    private static func failure(for error: Error, pageIndex: Int) -> PageFailure {
        if let known = error as? DigitizationError, let message = known.errorDescription {
            return PageFailure(pageIndex: pageIndex, message: message)
        }
        return PageFailure(
            pageIndex: pageIndex,
            message: "Seite \(pageIndex + 1) konnte nicht erkannt werden: \(error.localizedDescription)")
    }

    private func parseGoodnotes(_ data: Data) throws -> GoodnotesDocument? {
        do {
            return try GoodnotesParser.parse(data: data)
        } catch GoodnotesError.notAPDF {
            throw DigitizationError.notAPDF
        } catch GoodnotesError.encrypted {
            throw DigitizationError.encrypted
        } catch {
            // Not recognizable as a Goodnotes export: handled as a generic PDF.
            return nil
        }
    }

    // MARK: Embedded text

    private func embeddedPage(index: Int, embedded: EmbeddedTextPage, pdfPage: PDFPage) throws -> PageDigitization {
        // The extractor's order (e.g. columns) is kept.
        let lines = LineMerging.assignReadingOrder(embedded: embedded.lines, others: [])
        var warnings: [String] = []
        if embedded.imageCoverage >= Self.imageWarningCoverage { warnings.append(Self.imagesWarning) }
        let result = makeResult(
            lines: lines, highlights: embedded.highlights, method: .embeddedPDFText, engineVersion: nil,
            passes: 0, usedReducedPDF: false, pageSize: embedded.pageSize, customWordsCount: 0, warnings: warnings)
        return PageDigitization(pageIndex: index, result: result, imageData: try pageImage(pdfPage, index: index))
    }

    static let imagesWarning = "Seite enthält Bilder; Text darin wurde nicht erkannt. Bei Bedarf neu erkennen."

    // MARK: Rendered pages (scans, reduced Goodnotes PDFs)

    private func recognizeRenderedPage(index: Int, pdfPage: PDFPage) async throws -> PageDigitization {
        guard let image = PageRenderer.render(page: pdfPage, scale: settings.recognitionScale, includeAnnotations: true) else {
            throw DigitizationError.renderingFailed(pageIndex: index)
        }
        let outcome = try await recognizeWithPasses(image, prefersDocumentRecognition: settings.prefersDocumentRecognition)
        var warnings: [String] = []
        if outcome.lines.isEmpty { warnings.append("Auf dieser Seite wurde kein Text erkannt.") }
        if outcome.variedWords > 0 { warnings.append(Self.variationWarning(outcome.variedWords)) }
        let lines = LineMerging.assignReadingOrder(outcome.lines)
        let illegible = lines.filter { $0.status == .illegible }.count
        if illegible > 0 { warnings.append(Self.illegibleWarning(illegible)) }
        let result = makeResult(
            lines: lines, highlights: [], method: outcome.method,
            engineVersion: outcome.engineVersion, passes: outcome.passes, usedReducedPDF: false,
            pageSize: PageRenderer.pageSize(of: pdfPage), warnings: warnings)
        return PageDigitization(pageIndex: index, result: result, imageData: try pageImage(pdfPage, index: index))
    }

    // MARK: Goodnotes editable pages

    private func digitizeEditablePage(
        index: Int, goodnotes page: GoodnotesPage, pdfPage: PDFPage, reducedPage: GoodnotesPage?
    ) async throws -> PageDigitization {
        var warnings: [String] = []
        var engineVersion: String?
        var passes = 1
        var variedWords = 0

        // 1. Handwriting: one recognition per pen color layer.
        let colors = InkLayerRenderer.penColors(on: page)
        var layerOutcomes: [(layer: Int, outcome: RecognitionOutcome)] = []
        let scale = PageRenderer.clampedScale(settings.recognitionScale, for: page.size)
        let outcomes = try await concurrentMap(Array(colors.enumerated()), maxConcurrent: 2) { item -> (Int, RecognitionOutcome) in
            let (layerIndex, color) = item
            try Task.checkCancellation()
            guard let layerImage = InkLayerRenderer.renderLayer(of: page, color: color, scale: scale) else {
                throw DigitizationError.renderingFailed(pageIndex: index)
            }
            var outcome = try await self.recognizeWithPasses(layerImage, prefersDocumentRecognition: false)
            outcome.lines = outcome.lines.map { Self.colored($0, with: color) }
            return (layerIndex, outcome)
        }
        for (layer, outcome) in outcomes {
            layerOutcomes.append((layer, outcome))
            engineVersion = engineVersion ?? outcome.engineVersion
            passes = max(passes, outcome.passes)
            variedWords += outcome.variedWords
        }
        var layerLines = layerOutcomes.map(\.outcome.lines)
        func mergedInk() -> [RecognizedLine] {
            LineMerging.mergeLayerFragments(
                layerLines.enumerated().flatMap { entry in entry.element.map { LineMerging.LayerLine(line: $0, layer: entry.offset) } })
        }
        var inkLines = mergedInk()

        // Visible worksheet text of the page and exact text of FreeText boxes.
        let embedded = EmbeddedTextExtractor.extract(from: pdfPage)
        let freeText = LineMerging.freeTextLines(page.freeTexts)

        // 2. Second chance: ink the first pass skipped, and lines that swallowed several rows, are read again row by row.
        if settings.retryCropLimit > 0 {
            let preliminary = LineMerging.assignReadingOrder(embedded: embedded?.lines ?? [], others: inkLines + freeText)
            let detectedFirst = GoodnotesEmphasisDetector.detect(page: page, lines: preliminary)
            let shapes = Self.shapeRects(of: detectedFirst)
            let retried = try await retryUnreadInk(page: page, layerLines: layerLines, shapeRects: shapes)
            if retried != layerLines {
                layerLines = retried
                inkLines = mergedInk()
            }
        }

        // 3. Cross-check with the reduced PDF (its text layer is Goodnotes' own, error-prone recognition).
        var usedReduced = false
        if let reducedPage {
            inkLines = ReducedPDFComparator.crossCheck(lines: inkLines, against: reducedPage)
            usedReduced = true
        }

        let provisional = LineMerging.assignReadingOrder(embedded: embedded?.lines ?? [], others: inkLines + freeText)

        // 4. Emphasis from the annotations; formatting highlights of the embedded text without duplicates.
        let detected = GoodnotesEmphasisDetector.detect(page: page, lines: provisional)
        let highlights = detected + Self.nonDuplicate(embedded?.highlights ?? [], comparedTo: detected)

        // 5. Ink that no recognized handwritten word explains becomes an illegible line (the recognizer drops what it cannot read).
        let illegible = IllegibleInk.lines(page: page, recognized: inkLines, shapeRects: Self.shapeRects(of: detected))
        let allLines = illegible.isEmpty
            ? provisional
            : LineMerging.assignReadingOrder(embedded: embedded?.lines ?? [], others: inkLines + freeText + illegible)

        if colors.isEmpty, page.strokes.isEmpty { warnings.append("Seite enthält keine Handschrift.") }
        if allLines.isEmpty { warnings.append("Auf dieser Seite wurde kein Text gefunden.") }
        if variedWords > 0 { warnings.append(Self.variationWarning(variedWords)) }
        let illegibleCount = allLines.filter { $0.status == .illegible }.count
        if illegibleCount > 0 { warnings.append(Self.illegibleWarning(illegibleCount)) }
        if let embedded, embedded.imageCoverage >= Self.imageWarningCoverage { warnings.append(Self.imagesWarning) }

        let result = makeResult(
            lines: allLines, highlights: highlights, method: .goodnotesInkLayers, engineVersion: engineVersion,
            passes: passes, usedReducedPDF: usedReduced, pageSize: page.size, warnings: warnings)
        return PageDigitization(pageIndex: index, result: result, imageData: try pageImage(pdfPage, index: index))
    }

    /// Areas of ink shapes (underlines, circles) among the detected emphasis; the strokes inside are not text.
    static func shapeRects(of highlights: [RecognizedHighlight]) -> [NormalizedRect] {
        highlights.filter { $0.source == .goodnotesShape && [.underline, .doubleUnderline, .circled].contains($0.kind) }.map(\.rect)
    }

    static func colored(_ line: RecognizedLine, with color: StudyColor) -> RecognizedLine {
        var line = line
        line.color = color
        for index in line.words.indices { line.words[index].color = color }
        return line
    }

    /// Embedded-text highlights that the Goodnotes detector did not already report (same kind, shared words).
    private static func nonDuplicate(
        _ embedded: [RecognizedHighlight], comparedTo detected: [RecognizedHighlight]
    ) -> [RecognizedHighlight] {
        embedded.filter { candidate in
            !detected.contains { other in
                other.kind == candidate.kind
                    && !Set(other.words).intersection(candidate.words).isEmpty
            }
        }
    }

    // MARK: Recognition with optional second pass

    struct RecognitionOutcome: Sendable {
        var lines: [RecognizedLine]
        var engineVersion: String
        var method: RecognitionMethod
        var passes: Int
        var variedWords: Int
    }

    func recognizeWithPasses(_ image: CGImage, prefersDocumentRecognition: Bool) async throws -> RecognitionOutcome {
        try Task.checkCancellation()
        let options = settings.recognitionOptions(prefersDocumentRecognition: prefersDocumentRecognition)
        let first = try await recognizer.recognize(image, options: options)
        let firstLines = Self.markIllegible(ScriptGuard.apply(to: first.lines))
        guard settings.multiPass, let scaled = PageRenderer.scaled(image, by: settings.secondPassScale) else {
            return RecognitionOutcome(
                lines: firstLines, engineVersion: first.engineVersion, method: first.method, passes: 1, variedWords: 0)
        }
        try Task.checkCancellation()
        let second = try await recognizer.recognize(scaled, options: options)
        let marked = LineMerging.markVariation(first: firstLines, second: second.lines)
        return RecognitionOutcome(
            lines: marked.lines, engineVersion: first.engineVersion, method: first.method, passes: 2,
            variedWords: marked.variedWords)
    }

    /// Lines the recognizer itself hardly trusts (confidence below `illegibleConfidence`) are illegible.
    static func markIllegible(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.map { line in
            guard line.confidence < illegibleConfidence, line.status != .illegible, !line.isUserCorrected else { return line }
            var line = line
            line.status = .illegible
            if !line.reviewReasons.contains(.unreadable) { line.reviewReasons.append(.unreadable) }
            for index in line.words.indices {
                line.words[index].status = .illegible
                if !line.words[index].reviewReasons.contains(.unreadable) { line.words[index].reviewReasons.append(.unreadable) }
            }
            return line
        }
    }

    // MARK: Helpers

    private func makeResult(
        lines: [RecognizedLine], highlights: [RecognizedHighlight], method: RecognitionMethod, engineVersion: String?,
        passes: Int, usedReducedPDF: Bool, pageSize: PageSize, customWordsCount: Int? = nil, warnings: [String]
    ) -> DigitizationResult {
        DigitizationResult(
            lines: lines, highlights: highlights,
            metadata: RecognitionMetadata(
                method: method, engineVersion: engineVersion, osVersion: environment.osVersion,
                deviceModel: environment.deviceModel, date: now(), passes: passes,
                customWordsCount: customWordsCount ?? settings.customWords.count, usedReducedPDF: usedReducedPDF),
            originalMarkdown: OriginalTextMarkdown.build(lines: lines, highlights: highlights),
            pageSize: pageSize, warnings: warnings)
    }

    private func pageImage(_ pdfPage: PDFPage, index: Int) throws -> Data? {
        guard let image = PageRenderer.render(page: pdfPage, scale: settings.renderScale, includeAnnotations: true) else {
            throw DigitizationError.renderingFailed(pageIndex: index)
        }
        return PageRenderer.jpegData(from: image, quality: settings.imageQuality)
    }

    private static func illegibleWarning(_ count: Int) -> String {
        count == 1
            ? "1 Stelle war nicht lesbar und ist als unleserlich markiert. Bitte den Text ergänzen."
            : "\(count) Stellen waren nicht lesbar und sind als unleserlich markiert. Bitte den Text ergänzen."
    }

    private static func variationWarning(_ count: Int) -> String {
        count == 1
            ? "1 Wort wurde in den beiden Erkennungsdurchläufen unterschiedlich gelesen und ist als unsicher markiert."
            : "\(count) Wörter wurden in den beiden Erkennungsdurchläufen unterschiedlich gelesen und sind als unsicher markiert."
    }
}

/// Runs `transform` over `items` with at most `maxConcurrent` operations at a time; results keep the input order.
func concurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item], maxConcurrent: Int, _ transform: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var results: [(Int, Output)] = []
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let index = next, item = items[index]
            next += 1
            group.addTask { (index, try await transform(item)) }
        }
        for _ in 0..<min(maxConcurrent, items.count) { addNext() }
        while let result = try await group.next() {
            results.append(result)
            addNext()
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
