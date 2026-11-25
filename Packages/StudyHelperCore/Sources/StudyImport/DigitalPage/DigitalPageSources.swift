import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import StudyCore

/// Opened originals for building several digital pages of the same file: each PDF is checked once, its Goodnotes
/// structure parsed once, and an idle `PDFDocument` is kept for the next call. Pass one instance to consecutive
/// `DigitalPageBuilder` calls.
///
/// Thread safety: an instance may be used from any number of threads at once. Its locks are held only to look up,
/// insert or hand out cached objects, never while a PDF is opened, parsed or drawn: every build draws with a
/// `PDFDocument` of its own (the idle one, or a new one while that is in use), so concurrent builds, also of the same
/// PDF, never wait for each other. Only the `capacity` most recently used PDFs are kept.
public final class DigitalPageSources: @unchecked Sendable {
    /// Number of PDFs kept open (least recently used out first).
    static let capacity = 2
    private let lock = NSLock()
    /// Most recently used last.
    private var opened: [OpenedPDF] = []

    public init() {}

    /// The opened PDF for `data`: a cached one with the same bytes, or a newly opened one.
    func pdf(_ data: Data) throws -> OpenedPDF {
        let key = OpenedPDF.Key(data)
        let candidates = lock.withLock { opened.filter { $0.key == key } }
        // The full comparison (only on a key hit) runs outside the lock.
        if let hit = candidates.first(where: { $0.data == data }) {
            lock.withLock {
                if let index = opened.firstIndex(where: { $0 === hit }) { opened.append(opened.remove(at: index)) }
            }
            return hit
        }
        let pdf = try OpenedPDF(data: data, key: key)
        lock.withLock {
            opened.append(pdf)
            if opened.count > Self.capacity { opened.removeFirst(opened.count - Self.capacity) }
        }
        return pdf
    }

    /// The cached PDFs, least recently used first (tests).
    var cached: [OpenedPDF] { lock.withLock { opened } }
}

/// One opened PDF: its bytes, its Goodnotes structure (parsed on first use) and at most one idle `PDFDocument`.
///
/// A build takes a document for its exclusive use with `checkOut()` and returns it with `checkIn(_:)`, unless it
/// changed the document (text mode hides ink annotations): a changed document is dropped, so no later build ever
/// draws a shared document in a changed state.
final class OpenedPDF: @unchecked Sendable {
    /// Cheap identity of the bytes: count plus a hash of the first and last 4 KB. A key hit is confirmed by a full
    /// comparison.
    struct Key: Hashable {
        var count: Int
        var hash: Int

        init(_ data: Data) {
            var hasher = Hasher()
            hasher.combine(data.prefix(4096))
            hasher.combine(data.suffix(4096))
            count = data.count
            hash = hasher.finalize()
        }
    }

    let data: Data
    let key: Key
    private let lock = NSLock()
    private var idle: PDFDocument?
    private var parsed: GoodnotesDocument??

    /// Opens the PDF once to check that it can be read; that document becomes the idle one.
    init(data: Data, key: Key) throws {
        self.data = data
        self.key = key
        idle = try Self.open(data)
    }

    /// A document for exclusive use: the idle one, or a new one while that is in use.
    func checkOut() throws -> PDFDocument {
        let cached = lock.withLock { () -> PDFDocument? in
            defer { idle = nil }
            return idle
        }
        return try cached ?? Self.open(data)
    }

    /// Returns an unchanged document for reuse (kept only if no other document is idle).
    func checkIn(_ document: PDFDocument) {
        lock.withLock { if idle == nil { idle = document } }
    }

    /// The Goodnotes structure of the file, nil if it cannot be parsed. Parsed outside the lock: two first calls at
    /// the same time may both parse; the first result is kept.
    var goodnotes: GoodnotesDocument? {
        if let cached = lock.withLock({ parsed }) { return cached }
        let result = try? GoodnotesParser.parse(data: data)
        return lock.withLock {
            if parsed == nil { parsed = .some(result) }
            return parsed ?? result
        }
    }

    private static func open(_ data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else { throw DigitalPageError.unreadablePDF }
        if document.isLocked, !document.unlock(withPassword: "") { throw DigitalPageError.unreadablePDF }
        return document
    }
}

/// What the builder needs to know about the original of one page.
struct DigitalPageSource {
    /// Displayed page size: points (PDF, rotation applied) or pixels (photo).
    var size: PageSize
    var pdfPage: PDFPage?
    var photo: CGImage?
    var variant: GoodnotesVariant
    /// The Goodnotes page (editable exports only), strokes in displayed page space.
    var goodnotesPage: GoodnotesPage?

    var isPhoto: Bool { photo != nil }

    /// Opens the page of `background`. For a PDF, `document` is a document of `pdf` checked out for this build; keep
    /// it alive while the result is used (a `PDFPage` does not retain its document).
    static func open(
        _ background: DigitalPageInput.Background, pdf: OpenedPDF?, document: PDFDocument?
    ) throws -> DigitalPageSource {
        switch background {
        case .image(let data):
            guard let decoded = PageRenderer.decodeImage(data: data) else { throw DigitalPageError.unreadableImage }
            let image = PageRenderer.upright(decoded.image, orientation: decoded.orientation)
            return DigitalPageSource(
                size: PageSize(width: Double(image.width), height: Double(image.height)),
                pdfPage: nil, photo: image, variant: .other, goodnotesPage: nil)
        case .pdf(_, let pageIndex, let stored):
            guard let pdf, let document else { throw DigitalPageError.unreadablePDF }
            guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else {
                throw DigitalPageError.pageOutOfRange(pageIndex: pageIndex)
            }
            let variant = stored ?? pdf.goodnotes?.variant ?? .other
            var goodnotesPage: GoodnotesPage?
            if variant == .editable, let document = pdf.goodnotes, pageIndex < document.pages.count {
                goodnotesPage = document.pages[pageIndex]
            }
            return DigitalPageSource(
                size: PageRenderer.pageSize(of: page), pdfPage: page, photo: nil, variant: variant,
                goodnotesPage: goodnotesPage)
        }
    }

    // MARK: Page facts

    /// The page carries a foreign invisible text layer (reduced Goodnotes export, OCR'd scan). It must not end up in
    /// the digital page, so the PDF gets a raster of the page instead of its content.
    func hasForeignTextLayer() -> Bool {
        guard let page = pdfPage?.pageRef else { return false }
        if variant == .reduced { return true }
        return PDFContentScanner.scan(page: page).runs.contains { !$0.isVisible && $0.visibleByteCount > 0 }
    }

    /// Rects of the visible embedded text lines (real text of the page).
    func embeddedTextRects() -> [NormalizedRect] {
        guard let pdfPage else { return [] }
        return EmbeddedTextExtractor.extract(from: pdfPage)?.lines.map(\.rect) ?? []
    }

    /// Visible FreeText annotations whose appearance draws real text (or that have no appearance, so PDFKit draws
    /// `/Contents`): drawing the page puts their text into the output as text.
    func freeTextRects() -> [NormalizedRect] {
        guard let pdfPage, let cgPage = pdfPage.pageRef, let dictionary = cgPage.dictionary else { return [] }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { return [] }
        var result: [NormalizedRect] = []
        for index in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &annot), let annot,
                  DigitalPagePDF.subtype(of: annot) == "FreeText", !DigitalPagePDF.isHidden(annot),
                  let rect = DigitalPagePDF.rect(of: annot) else { continue }
            var appearance: CGPDFDictionaryRef?, normal: CGPDFStreamRef?
            if CGPDFDictionaryGetDictionary(annot, "AP", &appearance), let appearance,
               CGPDFDictionaryGetStream(appearance, "N", &normal), let normal {
                guard DigitalPagePDF.streamUsesFonts(normal, depth: 0) else { continue }
            }
            result.append(normalized(rect))
        }
        return result
    }

    /// Image areas of the page content and image stamps, without page-sized images (a scanned page is one image; its
    /// text is the page's text, not text inside a picture).
    func imageRegions() -> [NormalizedRect] {
        allImageRegions().filter { $0.area < DigitalPageBuilder.pageSizedImage }
    }

    /// Page-sized images (scans): text on them is part of the page's raster, not ink that an annotation could hide.
    func scanRegions() -> [NormalizedRect] {
        allImageRegions().filter { $0.area >= DigitalPageBuilder.pageSizedImage }
    }

    private func allImageRegions() -> [NormalizedRect] {
        guard let pdfPage else { return [] }
        let stamps = pdfPage.pageRef.map(ImageText.imageStampRects(of:)) ?? []
        return ImageText.regions(of: pdfPage, imageStamps: stamps)
    }

    func shapeArrows() -> [ShapeArrows.Arrow] {
        guard let pdfPage else { return [] }
        return ShapeArrows.arrows(of: pdfPage)
    }

    /// A rect in the page's (unrotated) user space, normalized to the displayed page.
    func normalized(_ rect: CGRect) -> NormalizedRect {
        guard let pdfPage else { return .zero }
        let box = pdfPage.bounds(for: .mediaBox)
        return NormalizedRect.fromBottomLeft(
            x: Double(rect.minX - box.minX), y: Double(rect.minY - box.minY),
            width: Double(rect.width), height: Double(rect.height),
            spaceWidth: Double(box.width), spaceHeight: Double(box.height)
        ).rotatedClockwise(pdfPage.rotation)
    }
}

/// Small CGPDF helpers of the digital page.
enum DigitalPagePDF {
    static func subtype(of annot: CGPDFDictionaryRef) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(annot, "Subtype", &name), let name else { return nil }
        return String(cString: name)
    }

    /// Flag bit 2 (hidden).
    static func isHidden(_ annot: CGPDFDictionaryRef) -> Bool {
        var flags: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(annot, "F", &flags) && flags & 2 != 0
    }

    static func rect(of annot: CGPDFDictionaryRef) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annot, "Rect", &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values: [CGFloat] = []
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
            values.append(value)
        }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    static func textString(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, key, &string), let string,
              let copy = CGPDFStringCopyTextString(string) else { return nil }
        return copy as String
    }

    /// True if the form stream (or a form it draws, up to depth 3) has fonts in its resources.
    static func streamUsesFonts(_ stream: CGPDFStreamRef, depth: Int) -> Bool {
        guard depth <= 3, let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts, CGPDFDictionaryGetCount(fonts) > 0 {
            return true
        }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        var children: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var child: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &child), let child { children.append(child) }
            return true
        }, nil)
        return children.contains { streamUsesFonts($0, depth: depth + 1) }
    }
}
