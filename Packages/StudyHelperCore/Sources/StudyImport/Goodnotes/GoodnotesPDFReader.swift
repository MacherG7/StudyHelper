import CoreGraphics
import Foundation
import StudyCore

/// Low-level reader: CGPDF page dictionaries -> `GoodnotesDocument`.
///
/// All coordinates in the result are PDF user space points relative to the lower-left corner of the page's
/// MediaBox (so they always lie in 0…width × 0…height, also for PDFs whose MediaBox does not start at 0,0).
enum GoodnotesPDFReader {
    static func read(data: Data) throws -> GoodnotesDocument {
        // Cheap signature check first: the header may be preceded by a little junk but must be near the start.
        let head = data.prefix(1024)
        guard head.range(of: Data("%PDF".utf8)) != nil else { throw GoodnotesError.notAPDF }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw GoodnotesError.notAPDF
        }
        if document.isEncrypted, !document.isUnlocked {
            // Many PDFs are "encrypted" with an empty user password (print/copy restrictions only).
            if !document.unlockWithPassword("") { throw GoodnotesError.encrypted }
        }
        guard document.numberOfPages > 0 else { throw GoodnotesError.notAPDF }

        let (producer, creator) = readInfo(document)
        var pages: [GoodnotesPage] = []
        var hasInkOrFreeText = false
        var hasOtherAnnotations = false
        var hasInvisibleText = false

        let textLayers = GoodnotesTextLayerReader.readAll(data: data, pageCount: document.numberOfPages)

        for number in 1...document.numberOfPages {
            guard let cgPage = document.page(at: number), let pageDict = cgPage.dictionary else {
                throw GoodnotesError.notAPDF
            }
            let box = cgPage.getBoxRect(.mediaBox)
            let size = PageSize(width: Double(box.width), height: Double(box.height))
            var page = GoodnotesPage(index: number - 1, size: size)
            parseAnnotations(
                of: pageDict, box: box, into: &page,
                hasInkOrFreeText: &hasInkOrFreeText, hasOtherAnnotations: &hasOtherAnnotations)
            if number - 1 < textLayers.count { page.textLayer = textLayers[number - 1] }
            // Everything is read in the unrotated page space; the displayed (rotated) orientation is what the
            // rendered page image, the embedded text and the user see, so the page is rotated as a whole.
            let rotation = ((Int(cgPage.rotationAngle) % 360) + 360) % 360
            if rotation != 0 { rotate(&page, clockwiseDegrees: rotation) }
            if !hasInvisibleText, InvisibleTextScanner.pageDrawsInvisibleText(cgPage) { hasInvisibleText = true }
            pages.append(page)
        }

        let hasTextLayer = pages.contains { !$0.textLayer.isEmpty }
        let mentionsGoodnotes = [producer, creator].contains { $0?.localizedCaseInsensitiveContains("goodnotes") == true }
        let variant: GoodnotesVariant
        if hasInkOrFreeText {
            variant = .editable
        } else if !hasOtherAnnotations, hasTextLayer, mentionsGoodnotes || hasInvisibleText {
            variant = .reduced
        } else {
            variant = .other
        }
        return GoodnotesDocument(variant: variant, pages: pages, producer: producer, creator: creator)
    }

    // MARK: Rotation

    /// Moves strokes, rects and text-layer words of an unrotated page into the space of the page displayed
    /// rotated clockwise by `degrees` (90, 180, 270) and swaps the size for 90/270.
    static func rotate(_ page: inout GoodnotesPage, clockwiseDegrees degrees: Int) {
        let w = page.size.width, h = page.size.height
        func point(_ p: PDFPoint) -> PDFPoint {
            switch degrees {
            case 90: return PDFPoint(x: p.y, y: w - p.x)
            case 180: return PDFPoint(x: w - p.x, y: h - p.y)
            case 270: return PDFPoint(x: h - p.y, y: p.x)
            default: return p
            }
        }
        for i in page.strokes.indices { page.strokes[i].points = page.strokes[i].points.map(point) }
        for i in page.freeTexts.indices { page.freeTexts[i].rect = page.freeTexts[i].rect.rotatedClockwise(degrees) }
        for i in page.stamps.indices { page.stamps[i].rect = page.stamps[i].rect.rotatedClockwise(degrees) }
        for i in page.textLayer.indices { page.textLayer[i].rect = page.textLayer[i].rect.rotatedClockwise(degrees) }
        if degrees % 180 != 0 { page.size = PageSize(width: h, height: w) }
        page.rotation = degrees
    }

    // MARK: Document info

    private static func readInfo(_ document: CGPDFDocument) -> (producer: String?, creator: String?) {
        guard let info = document.info else { return (nil, nil) }
        return (textString(info, "Producer"), textString(info, "Creator"))
    }

    // MARK: Annotations

    private static func parseAnnotations(
        of pageDict: CGPDFDictionaryRef, box: CGRect, into page: inout GoodnotesPage,
        hasInkOrFreeText: inout Bool, hasOtherAnnotations: inout Bool
    ) {
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(pageDict, "Annots", &annots), let annots else { return }
        let size = page.size
        for i in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, i, &annot), let annot else { continue }
            var subtypeC: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(annot, "Subtype", &subtypeC), let subtypeC else { continue }
            let subtype = String(cString: subtypeC)

            // Hidden annotations (flag bit 2) are not part of the visible note.
            var flags: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(annot, "F", &flags), flags & 2 != 0 { continue }

            switch subtype {
            case "Ink":
                hasInkOrFreeText = true
                page.strokes += inkStrokes(of: annot, box: box)
            case "FreeText":
                hasInkOrFreeText = true
                let text = textString(annot, "Contents") ?? ""
                let rect = normalizedRect(of: annot, box: box, size: size) ?? .zero
                page.freeTexts.append(FreeTextBox(text: text, rect: rect, name: textString(annot, "NM")))
            case "Stamp":
                let rect = normalizedRect(of: annot, box: box, size: size) ?? .zero
                page.stamps.append(StampShape(rect: rect, name: textString(annot, "NM")))
            case "Link", "Widget", "Popup":
                break
            default:
                hasOtherAnnotations = true
            }
        }
    }

    private static func inkStrokes(of annot: CGPDFDictionaryRef, box: CGRect) -> [InkStroke] {
        var inkList: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annot, "InkList", &inkList), let inkList else { return [] }
        let color = penColor(of: annot)
        let width = penWidth(of: annot)
        let name = textString(annot, "NM")
        let (opacity, multiply) = transparency(of: annot)
        var strokes: [InkStroke] = []
        for i in 0..<CGPDFArrayGetCount(inkList) {
            var list: CGPDFArrayRef?
            guard CGPDFArrayGetArray(inkList, i, &list), let list else { continue }
            let numbers = numbers(in: list)
            var points: [PDFPoint] = []
            points.reserveCapacity(numbers.count / 2)
            var k = 0
            while k + 1 < numbers.count {
                points.append(PDFPoint(x: numbers[k] - Double(box.minX), y: numbers[k + 1] - Double(box.minY)))
                k += 2
            }
            guard !points.isEmpty else { continue }
            strokes.append(InkStroke(
                points: points, color: color, width: width, name: name, opacity: opacity, blendsMultiply: multiply))
        }
        return strokes
    }

    /// Opacity and blend mode: `/CA` of the annotation, else the graphics states (`/ExtGState`) used by the
    /// appearance stream `/AP /N`.
    private static func transparency(of annot: CGPDFDictionaryRef) -> (opacity: Double, multiply: Bool) {
        var opacity = 1.0
        var multiply = false
        var ca: CGPDFReal = 1
        if CGPDFDictionaryGetNumber(annot, "CA", &ca) { opacity = Double(ca) }

        var ap: CGPDFDictionaryRef?
        var normal: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(annot, "AP", &ap), let ap,
              CGPDFDictionaryGetStream(ap, "N", &normal), let normal,
              let streamDict = CGPDFStreamGetDictionary(normal) else { return (opacity, multiply) }
        var resources: CGPDFDictionaryRef?
        var states: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(streamDict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "ExtGState", &states), let states else { return (opacity, multiply) }
        final class Box { var opacity = 1.0; var multiply = false }
        let box = Box()
        CGPDFDictionaryApplyBlock(states, { _, object, _ in
            var state: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &state), let state else { return true }
            var value: CGPDFReal = 1
            if CGPDFDictionaryGetNumber(state, "CA", &value) { box.opacity = min(box.opacity, Double(value)) }
            if CGPDFDictionaryGetNumber(state, "ca", &value) { box.opacity = min(box.opacity, Double(value)) }
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(state, "BM", &name), let name, String(cString: name) == "Multiply" { box.multiply = true }
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(state, "BM", &array), let array {
                for i in 0..<CGPDFArrayGetCount(array) {
                    var item: UnsafePointer<CChar>?
                    if CGPDFArrayGetName(array, i, &item), let item, String(cString: item) == "Multiply" { box.multiply = true }
                }
            }
            return true
        }, nil)
        return (min(opacity, box.opacity), multiply || box.multiply)
    }

    /// `/C`: 0 = transparent (treated as black), 1 = gray, 3 = RGB, 4 = CMYK.
    private static func penColor(of annot: CGPDFDictionaryRef) -> RGBColor {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annot, "C", &array), let array else { return .black }
        let c = numbers(in: array)
        switch c.count {
        case 1:
            return RGBColor(red: c[0], green: c[0], blue: c[0])
        case 3:
            return RGBColor(red: c[0], green: c[1], blue: c[2])
        case 4:
            let k = c[3]
            return RGBColor(red: (1 - c[0]) * (1 - k), green: (1 - c[1]) * (1 - k), blue: (1 - c[2]) * (1 - k))
        default:
            return .black
        }
    }

    /// `/BS /W`, then the third value of `/Border`, default 1.
    private static func penWidth(of annot: CGPDFDictionaryRef) -> Double {
        var bs: CGPDFDictionaryRef?
        var w: CGPDFReal = 0
        if CGPDFDictionaryGetDictionary(annot, "BS", &bs), let bs, CGPDFDictionaryGetNumber(bs, "W", &w) {
            return Double(w)
        }
        var border: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(annot, "Border", &border), let border {
            let n = numbers(in: border)
            if n.count >= 3 { return n[2] }
        }
        return 1
    }

    private static func normalizedRect(of annot: CGPDFDictionaryRef, box: CGRect, size: PageSize) -> NormalizedRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(annot, "Rect", &array), let array else { return nil }
        let r = numbers(in: array)
        guard r.count == 4 else { return nil }
        let x0 = min(r[0], r[2]) - Double(box.minX), x1 = max(r[0], r[2]) - Double(box.minX)
        let y0 = min(r[1], r[3]) - Double(box.minY), y1 = max(r[1], r[3]) - Double(box.minY)
        return .fromBottomLeft(
            x: x0, y: y0, width: x1 - x0, height: y1 - y0, spaceWidth: size.width, spaceHeight: size.height)
    }

    // MARK: CGPDF helpers

    private static func numbers(in array: CGPDFArrayRef) -> [Double] {
        var result: [Double] = []
        let count = CGPDFArrayGetCount(array)
        result.reserveCapacity(count)
        for i in 0..<count {
            var value: CGPDFReal = 0
            if CGPDFArrayGetNumber(array, i, &value) {
                result.append(Double(value))
            } else {
                result.append(0)
            }
        }
        return result
    }

    /// PDF text string (UTF-16BE with BOM or PDFDocEncoding) -> Swift string.
    private static func textString(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var string: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, key, &string), let string,
              let copy = CGPDFStringCopyTextString(string) else { return nil }
        return copy as String
    }
}

// MARK: - Invisible text detection

/// Finds out whether a page draws text in render mode 3 (invisible), which is how OCR layers and the
/// reduced Goodnotes export store recognized handwriting. Scans the content stream with `CGPDFScanner`
/// (also form XObjects, a few levels deep).
private enum InvisibleTextScanner {
    final class State {
        var found = false
        var depth = 0
        /// Form XObject streams are scanned once each (guards against self-referencing forms).
        var visitedForms = 0
    }

    static func pageDrawsInvisibleText(_ page: CGPDFPage) -> Bool {
        let state = State()
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan(stream, state: state)
        return state.found
    }

    static func scan(_ stream: CGPDFContentStreamRef, state: State) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let info else { return }
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode), mode == 3 {
                Unmanaged<State>.fromOpaque(info).takeUnretainedValue().found = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
            guard !state.found, state.depth < 3, state.visitedForms < 64 else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dict = CGPDFStreamGetDictionary(xobject) else { return }
            var subtypeC: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtypeC), let subtypeC,
                  String(cString: subtypeC) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
            state.visitedForms += 1
            state.depth += 1
            let child = CGPDFContentStreamCreateWithStream(xobject, resources ?? dict, parent)
            InvisibleTextScanner.scan(child, state: state)
            state.depth -= 1
        }
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
    }
}
