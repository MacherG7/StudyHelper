import CoreGraphics
import CoreText
import Foundation
import PDFKit
import StudyCore
import TestFixtures
@testable import StudyImport

/// Inputs and pixel/text helpers for the digital page tests. No Vision: the lines come from the fixture ground truth
/// (handwriting), from the PDF's own text (worksheet text) and from the FreeText boxes, as the pipeline stores them.
enum DigitalPageTestSupport {
    // MARK: Inputs

    static func data(_ fixture: GoodnotesFixture) throws -> Data { try Data(contentsOf: fixture.url) }

    /// Page `index` of the editable Fotosynthese fixture with "perfect" stored lines and the detected highlights.
    static func editableInput(_ index: Int) throws -> DigitalPageInput {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let data = try data(.fotosyntheseEditable)
        let page = loaded.document.pages[index]
        let pdfPage = try pdfPage(data, index)
        let ink = GoodnotesTestSupport.perfectPage(truth: loaded.truth, pageNumber: index + 1).lines
        let embedded = EmbeddedTextExtractor.extract(from: pdfPage)?.lines ?? []
        let freeText = LineMerging.freeTextLines(page.freeTexts)
        let lines = LineMerging.assignReadingOrder(embedded: embedded, others: ink + freeText)
        let highlights = GoodnotesEmphasisDetector.detect(page: page, lines: lines)
        return DigitalPageInput(background: .pdf(data: data, pageIndex: index, variant: .editable), lines: lines, highlights: highlights)
    }

    /// Page `index` of the reduced fixture imported on its own: the handwriting as recognized (truth), the printed
    /// text as Vision would read it from the rendered page (here: PDFKit's visible text).
    static func reducedInput(_ index: Int, variant: GoodnotesVariant? = .reduced) throws -> DigitalPageInput {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseReduced)
        let data = try data(.fotosyntheseReduced)
        let ink = GoodnotesTestSupport.perfectPage(truth: loaded.truth, pageNumber: index + 1).lines
        let printed = EmbeddedTextExtractor.extract(from: try pdfPage(data, index))?.lines ?? []
        let lines = LineMerging.assignReadingOrder(ink + printed)
        return DigitalPageInput(background: .pdf(data: data, pageIndex: index, variant: variant), lines: lines)
    }

    static func worksheetInput(_ index: Int) throws -> DigitalPageInput {
        let data = try Data(contentsOf: DigitalWorksheetFixture.url)
        let embedded = try requireValue(EmbeddedTextExtractor.extract(from: try pdfPage(data, index)))
        return DigitalPageInput(
            background: .pdf(data: data, pageIndex: index, variant: .other), lines: embedded.lines,
            highlights: embedded.highlights)
    }

    /// A "photo" of page 1 of the editable fixture: rendered, on beige paper, as JPEG. Lines from the truth.
    static func photoInput() throws -> (input: DigitalPageInput, image: CGImage) {
        let data = try data(.fotosyntheseEditable)
        let page = try pdfPage(data, 0)
        let rendered = try requireValue(PageRenderer.render(page: page, scale: 1.5))
        let width = rendered.width, height = rendered.height
        let context = try requireValue(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.92, blue: 0.84, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.multiply)
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        let photo = try requireValue(context.makeImage())
        let jpeg = try requireValue(PageRenderer.jpegData(from: photo, quality: 0.92))
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let lines = GoodnotesTestSupport.perfectPage(truth: loaded.truth, pageNumber: 1).lines
        return (DigitalPageInput(background: .image(data: jpeg), lines: lines), photo)
    }

    static func pdfPage(_ data: Data, _ index: Int) throws -> PDFPage {
        try requireValue(PDFDocument(data: data)?.page(at: index))
    }

    // MARK: Truth

    static func truthRects(_ kind: GoodnotesItemKind, page: Int, fixture: GoodnotesFixture = .fotosyntheseEditable) throws -> [NormalizedRect] {
        let truth = try GoodnotesTestSupport.load(fixture).truth
        return truth.items(ofKind: kind, onPage: page).map { GoodnotesTestSupport.normalized($0.bbox, truth: truth) }
    }

    // MARK: Text of the output PDF

    static func tokens(_ text: String) -> [String] {
        WordTokenizer.tokens(in: text).map(\.normalized)
    }

    static func counts(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// The tokens of `expected` that PDFKit finds as text inside `rect` (normalized, displayed page) of `page`,
    /// matched in order with `WordAlignment` (other text in the rect is ignored).
    static func matchedTokens(_ expected: String, on page: PDFPage, in rect: NormalizedRect) -> Int {
        let size = page.bounds(for: .mediaBox).size
        let r = rect.toBottomLeft(spaceWidth: size.width, spaceHeight: size.height)
        let grow = 0.2 * r.height
        let area = CGRect(x: r.x - grow, y: r.y - grow, width: r.width + 2 * grow, height: r.height + 2 * grow)
        let found = WordTokenizer.tokens(in: page.selection(for: area)?.string ?? "")
        let wanted = WordTokenizer.tokens(in: expected)
        return WordAlignment.align(wanted, found).filter { if case .match = $0 { true } else { false } }.count
    }

    /// True if `text` occurs on `page` with the center of its selection inside `rect` (grown by `tolerance` line heights).
    static func findsText(_ text: String, on page: PDFPage, in rect: NormalizedRect, tolerance: Double = 0.3) -> Bool {
        guard let document = page.document else { return false }
        let size = page.bounds(for: .mediaBox).size
        let r = rect.toBottomLeft(spaceWidth: size.width, spaceHeight: size.height)
        let grow = tolerance * r.height
        let area = CGRect(x: r.x - grow, y: r.y - grow, width: r.width + 2 * grow, height: r.height + 2 * grow)
        return document.findString(text, withOptions: []).contains { selection in
            guard selection.pages.contains(page) else { return false }
            let b = selection.bounds(for: page)
            return area.contains(CGPoint(x: b.midX, y: b.midY))
        }
    }

    // MARK: Pixels

    struct Pixels {
        var width: Int
        var height: Int
        var rgba: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            rgba = [UInt8](repeating: 255, count: width * height * 4)
            rgba.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }

        func pixelRange(_ rect: NormalizedRect) -> (x: Range<Int>, y: Range<Int>) {
            let x0 = max(0, Int((rect.minX * Double(width)).rounded(.down)))
            let x1 = min(width, Int((rect.maxX * Double(width)).rounded(.up)))
            let y0 = max(0, Int((rect.minY * Double(height)).rounded(.down)))
            let y1 = min(height, Int((rect.maxY * Double(height)).rounded(.up)))
            return (x0..<max(x0, x1), y0..<max(y0, y1))
        }

        func count(in rect: NormalizedRect, where predicate: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            let range = pixelRange(rect)
            var count = 0
            for y in range.y {
                for x in range.x {
                    let o = (y * width + x) * 4
                    if predicate(rgba[o], rgba[o + 1], rgba[o + 2]) { count += 1 }
                }
            }
            return count
        }

        /// Pen ink: dark in gray (black, red, blue and green pens all are).
        func ink(in rect: NormalizedRect) -> Int {
            count(in: rect) { r, g, b in 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) < 140 }
        }

        /// Anything that is not (nearly) white or light gray paper.
        func marked(in rect: NormalizedRect) -> Int {
            count(in: rect) { r, g, b in min(r, g, b) < 215 }
        }

        /// Mean absolute channel difference (0…255) to `other` inside `rect` (whole image if nil).
        func meanDifference(to other: Pixels, in rect: NormalizedRect? = nil) -> Double {
            guard width == other.width, height == other.height else { return 255 }
            let range = pixelRange(rect ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1))
            var sum = 0.0, n = 0
            for y in range.y {
                for x in range.x {
                    let o = (y * width + x) * 4
                    for c in 0..<3 { sum += abs(Double(rgba[o + c]) - Double(other.rgba[o + c])) }
                    n += 3
                }
            }
            return n > 0 ? sum / Double(n) : 0
        }
    }

    // MARK: Synthetic pages

    /// Raw RGB bytes of an image with dark text on light gray (text inside a picture).
    static func textImage(_ text: String, width: Int, height: Int) -> Data {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.9, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.3, alpha: 1))
            context.fillEllipse(in: CGRect(x: width / 10, y: height / 10, width: width / 3, height: height / 3))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, Double(height) / 6, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: Double(width) * 0.1, y: Double(height) * 0.7)
            CTLineDraw(line, context)
        }
        var rgb = Data(capacity: width * height * 3)
        for i in 0..<(width * height) { rgb.append(contentsOf: rgba[(i * 4)..<(i * 4 + 3)]) }
        return rgb
    }

    /// A zig-zag scribble filling a box (x, y, w, h in user space), as handwriting stand-in.
    static func scribble(x: Double, y: Double, w: Double, h: Double, color: (Double, Double, Double) = (0, 0, 0)) -> String {
        var points: [(Double, Double)] = []
        let steps = max(4, Int(w / 4))
        for i in 0...steps {
            points.append((x + w * Double(i) / Double(steps), i % 2 == 0 ? y + 2 : y + h - 2))
        }
        return MiniPDF.ink(points, color: color, width: 2)
    }
}

/// `#require` for optionals outside a test function body (throws instead of recording).
struct RequireError: Error, CustomStringConvertible {
    var description: String
}

func requireValue<T>(_ value: T?, _ what: String = "Wert") throws -> T {
    guard let value else { throw RequireError(description: "\(what) fehlt") }
    return value
}
