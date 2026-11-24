import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Text inside raster images that are part of a PDF page's content: pasted worksheet screenshots, scanned
/// worksheets and maps in Goodnotes notes ("Eingefügte Bilder und Arbeitsblätter sind Seiteninhalt, teils mit
/// eigenem Text", SPEC §1). The page is rendered without ink and text boxes (so no handwriting), every image area is
/// cut out and recognized on its own, and the lines are mapped back to page coordinates.
enum ImageText {
    /// Images smaller than this share of the page are icons or decoration and are skipped.
    static let minimumAreaShare = 0.01
    /// Padding around an image crop, in points (Vision misses text touching the border).
    static let padding = 6.0
    /// A recognized image line is dropped if an existing line (embedded text) covers this share of it.
    static let duplicateCoverage = 0.5

    /// Image areas of `page` in normalized page coordinates (rotation applied), overlapping ones merged: raster
    /// images of the page content and stamp annotations that show a raster image (Goodnotes stores pasted
    /// pictures as stamps; its shape-tool arrows are stamps too, but without an image).
    static func regions(of page: PDFPage, imageStamps: [CGRect]) -> [NormalizedRect] {
        guard let cgPage = page.pageRef else { return [] }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return [] }
        let padded = (PDFContentScanner.scan(page: cgPage).images + imageStamps)
            .map { $0.intersection(box) }
            .filter { !$0.isNull && $0.width * $0.height >= minimumAreaShare * box.width * box.height }
            .map { $0.insetBy(dx: -padding, dy: -padding).intersection(box) }
        return merged(padded).map { r in
            NormalizedRect.fromBottomLeft(
                x: Double(r.minX - box.minX), y: Double(r.minY - box.minY),
                width: Double(r.width), height: Double(r.height),
                spaceWidth: Double(box.width), spaceHeight: Double(box.height)
            ).rotatedClockwise(page.rotation)
        }
    }

    /// `/Rect` of every visible stamp annotation of `page` whose normal appearance draws a raster image
    /// (directly or through nested form XObjects), in PDF user space.
    static func imageStampRects(of page: CGPDFPage) -> [CGRect] {
        guard let dictionary = page.dictionary else { return [] }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { return [] }
        var rects: [CGRect] = []
        for index in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &annot), let annot else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(annot, "Subtype", &subtype), let subtype, String(cString: subtype) == "Stamp"
            else { continue }
            var flags: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(annot, "F", &flags), flags & 2 != 0 { continue }
            var appearance: CGPDFDictionaryRef?, normal: CGPDFStreamRef?
            guard CGPDFDictionaryGetDictionary(annot, "AP", &appearance), let appearance,
                  CGPDFDictionaryGetStream(appearance, "N", &normal), let normal,
                  streamDrawsImage(normal, depth: 0),
                  let rect = rectangle(annot) else { continue }
            rects.append(rect)
        }
        return rects
    }

    /// True if the form stream's resources contain an image XObject (forms followed up to depth 3).
    private static func streamDrawsImage(_ stream: CGPDFStreamRef, depth: Int) -> Bool {
        guard depth <= 3, let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        var children: [CGPDFStreamRef] = []
        var found = false
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var child: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &child), let child,
                  let childDictionary = CGPDFStreamGetDictionary(child) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(childDictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image": found = true; return false
            case "Form": children.append(child)
            default: break
            }
            return true
        }, nil)
        return found || children.contains { streamDrawsImage($0, depth: depth + 1) }
    }

    private static func rectangle(_ annot: CGPDFDictionaryRef) -> CGRect? {
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

    /// Renders the page content plus the image stamps only (no ink, text boxes or shape stamps).
    static func renderContent(of page: PDFPage, scale: Double, imageStamps: [CGRect]) -> CGImage? {
        var hidden: [PDFAnnotation] = []
        for annotation in page.annotations where annotation.shouldDisplay {
            let bounds = annotation.bounds
            let isImageStamp = annotation.type == "Stamp" && imageStamps.contains {
                abs($0.minX - bounds.minX) < 1.5 && abs($0.minY - bounds.minY) < 1.5
                    && abs($0.width - bounds.width) < 1.5 && abs($0.height - bounds.height) < 1.5
            }
            if !isImageStamp {
                annotation.shouldDisplay = false
                hidden.append(annotation)
            }
        }
        defer { for annotation in hidden { annotation.shouldDisplay = true } }
        return PageRenderer.render(page: page, scale: scale, includeAnnotations: !imageStamps.isEmpty)
    }

    /// Unions overlapping rectangles until none overlap.
    static func merged(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects {
            var current = rect
            var changed = true
            while changed {
                changed = false
                if let index = result.firstIndex(where: { $0.intersects(current) }) {
                    current = current.union(result.remove(at: index))
                    changed = true
                }
            }
            result.append(current)
        }
        return result.sorted { ($0.maxY, $0.minX) > ($1.maxY, $1.minX) }
    }

    /// Pixel crop of `region` in an image of `width` × `height` pixels, and the normalized rect it really covers.
    static func crop(_ region: NormalizedRect, width: Int, height: Int) -> (pixels: CGRect, rect: NormalizedRect)? {
        let w = Double(width), h = Double(height)
        let pixels = CGRect(x: region.x * w, y: region.y * h, width: region.width * w, height: region.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8 else { return nil }
        let rect = NormalizedRect(
            x: pixels.minX / w, y: pixels.minY / h, width: pixels.width / w, height: pixels.height / h)
        return (pixels, rect)
    }

    /// Lines that are not already present as `existing` lines (e.g. the embedded text of the same worksheet).
    static func withoutDuplicates(_ lines: [RecognizedLine], of existing: [RecognizedLine]) -> [RecognizedLine] {
        lines.filter { line in
            !existing.contains { line.rect.coverage(by: $0.rect) > duplicateCoverage }
        }
    }
}

extension DigitizationPipeline {
    /// Recognizes the text of the raster images on `pdfPage` (without annotations).
    /// - Parameter existing: lines the page already has from its text layer; image text duplicating them is dropped.
    func recognizeImageText(on pdfPage: PDFPage, existing: [RecognizedLine]) async throws -> (lines: [RecognizedLine], engineVersion: String?) {
        guard settings.recognizesImageText else { return ([], nil) }
        let stamps = pdfPage.pageRef.map(ImageText.imageStampRects(of:)) ?? []
        let regions = ImageText.regions(of: pdfPage, imageStamps: stamps)
        guard !regions.isEmpty,
              let page = ImageText.renderContent(of: pdfPage, scale: settings.recognitionScale, imageStamps: stamps)
        else { return ([], nil) }
        var lines: [RecognizedLine] = []
        var engineVersion: String?
        for region in regions {
            try Task.checkCancellation()
            guard let crop = ImageText.crop(region, width: page.width, height: page.height),
                  let image = page.cropping(to: crop.pixels) else { continue }
            let outcome = try await recognizeWithPasses(image, prefersDocumentRecognition: settings.prefersDocumentRecognition)
            engineVersion = engineVersion ?? outcome.engineVersion
            lines += outcome.lines
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.rect.isEmpty }
                .map { HandwritingRetry.mapToPage($0, cropRect: crop.rect) }
        }
        return (ImageText.withoutDuplicates(lines, of: existing), engineVersion)
    }
}
