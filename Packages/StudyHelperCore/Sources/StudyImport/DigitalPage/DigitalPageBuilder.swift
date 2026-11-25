import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import StudyCore

/// Builds the "digitale Seite" (docs/DECISIONS.md D-037, PHASES 3a): the original page with the stored text as an
/// invisible text layer (PDF), and the display images of both view modes.
///
/// - PDF pages are drawn as they are (content and annotations, vector). A page with a foreign invisible text layer
///   (reduced Goodnotes export, OCR'd scan) is drawn as a raster instead, so that its text layer does not end up in
///   the output. Photos are drawn as image; the page is as large as the photo in pixels.
/// - The text layer is the stored text including user corrections, word by word in the word boxes (whole lines when
///   the words no longer match the text), in reading order. Lines that are already real text in the output
///   (embedded text, FreeText boxes) are left out, so that no word is found twice. Illegible spots have no text.
/// - Text mode hides the handwriting (editable Goodnotes: the ink annotations of recognized lines, lines on a scanned
///   page image painted over; everything else: the line areas painted in the surrounding paper color) and draws the
///   text visibly at the same place, typed-looking (one size and baseline per line). Lines whose writing can be
///   neither hidden nor painted (flattened writing on an editable page) get no visible text. Printed text, images,
///   sketches, shapes, arrows and highlighter stay.
///
/// Everything here is synchronous CPU work; call it off the main actor. Calls may run concurrently, also with a
/// shared `DigitalPageSources` (no lock is held while drawing). Pages are never cached here; the result depends only
/// on the input and `version`.
public enum DigitalPageBuilder {
    /// Changes whenever the output for the same input changes (cache key of the app).
    public static let version = 2
    /// An image covering at least this share of the page is the page itself (scan), not a picture on it.
    static let pageSizedImage = 0.8
    /// A line counts as lying in an area (printed text, image) if at least this share of it is covered.
    static let coveredShare = 0.5

    // MARK: Public API

    /// Renders the page for display.
    /// - Parameters:
    ///   - mode: original look or text mode.
    ///   - scale: pixels per point (per pixel for photos). Very large pages are limited like `PageRenderer.render`.
    ///   - sources: reuse opened PDFs across calls (optional).
    public static func makeImage(
        _ input: DigitalPageInput, mode: DigitalPageMode, scale: Double, sources: DigitalPageSources? = nil
    ) throws -> CGImage {
        try makeImage(input, mode: mode, scale: scale, sources: sources, options: DigitalPageOptions())
    }

    /// One PDF with a page per input in the given order: original look plus invisible text layer.
    /// - Parameters:
    ///   - title: document title (e.g. subject and import name); no personal data.
    ///   - sources: reuse opened PDFs across calls (optional; pages of the same PDF share one anyway).
    public static func makePDF(
        _ pages: [DigitalPageInput], title: String? = nil, sources: DigitalPageSources? = nil
    ) throws -> Data {
        try makePDF(pages, title: title, sources: sources, options: DigitalPageOptions())
    }

    // MARK: Image

    static func makeImage(
        _ input: DigitalPageInput, mode: DigitalPageMode, scale: Double, sources: DigitalPageSources?,
        options: DigitalPageOptions
    ) throws -> CGImage {
        try withSource(input, sources: sources ?? DigitalPageSources()) { source, keepsDocument in
            guard let bitmap = Bitmap(size: source.size, scale: scale) else { throw DigitalPageError.renderingFailed }
            let context = bitmap.context
            switch mode {
            case .handwriting:
                drawOriginal(source, in: context)
            case .textLayer:
                let lines = textModeLines(input, source: source)
                // Lines whose handwriting is painted over, and lines drawn as visible text.
                var painted = lines
                var shown = lines
                if let goodnotes = source.goodnotesPage, let pdfPage = source.pdfPage {
                    let strokes = DigitalPageInk.handwritingStrokes(page: goodnotes, lines: lines, highlights: input.highlights)
                    if let hidden = DigitalPageInk.hide(strokes: strokes, on: pdfPage, goodnotes: goodnotes) {
                        // The document is changed now; it is dropped after this build instead of being reused.
                        if !hidden.hidden.isEmpty { keepsDocument = false }
                        drawOriginal(source, in: context)
                        DigitalPageInk.draw(hidden.redraw, of: goodnotes, in: context)
                        // Lines without hidden ink are still visible on the page (text on a scan, flattened writing):
                        // a scan is painted over like a photo; other visible writing gets no text drawn over it (the
                        // line stays in the invisible text layer of the PDF).
                        let covered = DigitalPageInk.coveredLines(lines, hiddenStrokes: hidden.hiddenStrokes, of: goodnotes)
                        let scans = source.scanRegions()
                        painted = lines.filter { !covered.contains($0.id) && Self.covered($0.rect, by: scans) >= coveredShare }
                        shown = lines.filter { covered.contains($0.id) } + painted
                    } else {
                        drawOriginal(source, in: context)
                    }
                } else {
                    drawOriginal(source, in: context)
                }
                if !painted.isEmpty { DigitalPagePaper.paint(over: painted, in: bitmap, size: source.size) }
                if options.drawsText {
                    let runs = DigitalPageText.runs(
                        for: shown, highlights: input.highlights, arrows: source.shapeArrows(), size: source.size)
                    DigitalPageText.draw(runs, in: context, visible: true, pageWidth: source.size.width)
                }
            }
            guard let image = context.makeImage() else { throw DigitalPageError.renderingFailed }
            return image
        }
    }

    /// Lines that text mode hides and draws as text: lines with text, without printed text (embedded text and
    /// FreeText stay as they are) and without text recognized inside pictures of a PDF page (the picture stays
    /// untouched; that text is only in the invisible layer).
    static func textModeLines(_ input: DigitalPageInput, source: DigitalPageSource) -> [RecognizedLine] {
        var lines = input.lines.filter { DigitalPageText.hasText($0) && !$0.rect.isEmpty }
        guard source.pdfPage != nil else { return lines }
        let printed = source.embeddedTextRects() + source.freeTextRects()
        lines.removeAll { covered($0.rect, by: printed) >= coveredShare }
        let images = source.imageRegions()
        guard !images.isEmpty else { return lines }
        // Handwriting written onto a picture of an editable page is still handwriting (it has strokes).
        let penCenters: [(Double, Double)] = source.goodnotesPage.map { page in
            zip(page.strokes, page.highlighterFlags).filter { !$0.1 }.map { stroke, _ in
                let box = stroke.boundingBox(pageSize: page.size)
                return (box.midX, box.midY)
            }
        } ?? []
        lines.removeAll { line in
            covered(line.rect, by: images) >= coveredShare
                && !penCenters.contains { line.rect.contains(x: $0.0, y: $0.1) }
        }
        return lines
    }

    /// Lines of the invisible text layer of the PDF.
    static func textLayerLines(_ input: DigitalPageInput, source: DigitalPageSource, rasterized: Bool) -> [RecognizedLine] {
        var lines = input.lines.filter { DigitalPageText.hasText($0) && !$0.rect.isEmpty }
        if source.pdfPage != nil, !rasterized {
            let printed = source.embeddedTextRects() + source.freeTextRects()
            lines.removeAll { covered($0.rect, by: printed) >= coveredShare }
        }
        return lines
    }

    /// Share of `rect` covered by `areas` (overlaps of the areas counted once per area, at most 1).
    static func covered(_ rect: NormalizedRect, by areas: [NormalizedRect]) -> Double {
        guard rect.area > 0 else { return 0 }
        return min(1, areas.reduce(0) { $0 + rect.intersection($1).area } / rect.area)
    }

    // MARK: PDF

    static func makePDF(
        _ pages: [DigitalPageInput], title: String?, sources: DigitalPageSources?, options: DigitalPageOptions
    ) throws -> Data {
        guard !pages.isEmpty else { throw DigitalPageError.renderingFailed }
        let sources = sources ?? DigitalPageSources()
        let data = NSMutableData()
        var auxiliary: [CFString: Any] = [kCGPDFContextCreator: "StudyHelper"]
        if let title, !title.isEmpty { auxiliary[kCGPDFContextTitle] = title }
        var firstBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &firstBox, auxiliary as CFDictionary) else {
            throw DigitalPageError.renderingFailed
        }
        for input in pages {
            try withSource(input, sources: sources) { source, _ in
                var box = CGRect(x: 0, y: 0, width: source.size.width, height: source.size.height)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData as CFData] as CFDictionary)
                defer { context.endPDFPage() }
                let rasterized = source.hasForeignTextLayer()
                if rasterized, let page = source.pdfPage {
                    guard let image = raster(of: page, scale: options.rasterScale) else { throw DigitalPageError.renderingFailed }
                    context.interpolationQuality = .high
                    context.draw(image, in: box)
                } else {
                    drawOriginal(source, in: context)
                }
                let lines = textLayerLines(input, source: source, rasterized: rasterized)
                let runs = DigitalPageText.runs(
                    for: lines, highlights: input.highlights, arrows: source.shapeArrows(), size: source.size)
                DigitalPageText.draw(runs, in: context, visible: false)
            }
        }
        context.closePDF()
        return data as Data
    }

    /// The page as JPEG-compressed raster (keeps the PDF small; handwriting stays sharp at 3×).
    static func raster(of page: PDFPage, scale: Double) -> CGImage? {
        guard let image = PageRenderer.render(page: page, scale: scale, includeAnnotations: true) else { return nil }
        guard let jpeg = PageRenderer.jpegData(from: image, quality: 0.9),
              let provider = CGDataProvider(data: jpeg as CFData),
              let decoded = CGImage(
                jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return decoded
    }

    // MARK: Drawing helpers

    /// Draws the original page (PDF with annotations, or the photo) into a context in displayed page points.
    static func drawOriginal(_ source: DigitalPageSource, in context: CGContext) {
        if let page = source.pdfPage {
            let previous = page.displaysAnnotations
            page.displaysAnnotations = true
            defer { page.displaysAnnotations = previous }
            page.draw(with: .mediaBox, to: context)
        } else if let photo = source.photo {
            context.interpolationQuality = .high
            context.draw(photo, in: CGRect(x: 0, y: 0, width: source.size.width, height: source.size.height))
        }
    }

    /// Runs `body` with the opened original. A PDF is drawn with a document checked out of `sources` for this call
    /// only (no lock is held meanwhile); `body` sets `keepsDocument` to false if it changed the document, which is
    /// then dropped instead of being reused.
    private static func withSource<T>(
        _ input: DigitalPageInput, sources: DigitalPageSources,
        _ body: (DigitalPageSource, _ keepsDocument: inout Bool) throws -> T
    ) throws -> T {
        var keepsDocument = true
        switch input.background {
        case .pdf(let data, _, _):
            let pdf = try sources.pdf(data)
            let document = try pdf.checkOut()
            defer { if keepsDocument { pdf.checkIn(document) } }
            return try withExtendedLifetime(document) {
                try body(DigitalPageSource.open(input.background, pdf: pdf, document: document), &keepsDocument)
            }
        case .image:
            return try body(DigitalPageSource.open(input.background, pdf: nil, document: nil), &keepsDocument)
        }
    }
}

/// An RGBA bitmap on white whose context draws in page units (points or photo pixels), origin bottom-left.
struct Bitmap {
    let context: CGContext
    let width: Int
    let height: Int
    /// Pixels per page unit.
    let scale: Double

    init?(size: PageSize, scale requested: Double) {
        guard requested > 0, requested.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = PageRenderer.clampedScale(requested, for: size)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Same scale as `PageRenderer.render`, so that both draw the page identically.
        context.scaleBy(x: scale, y: scale)
        self.context = context
        self.width = width
        self.height = height
        self.scale = scale
    }
}
