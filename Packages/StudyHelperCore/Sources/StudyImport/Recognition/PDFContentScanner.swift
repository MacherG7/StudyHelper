import CoreGraphics
import CoreText
import Foundation
import StudyCore

/// `RGBColor` is also a (Carbon) type exported by PDFKit/AppKit; files that import those use this name.
typealias StudyColor = RGBColor

/// A text-showing operation in a page content stream (one `Tj`, `TJ`, `'` or `"`).
struct ScannedTextRun {
    /// Start of the text on the baseline, in PDF user space (points, origin bottom-left).
    var origin: CGPoint
    /// Font size in points after the text matrix and CTM.
    var size: Double
    /// Estimated x of the end of the run (the real glyph advances are not known here).
    var estimatedEndX: Double
    var fontName: String
    var isBold: Bool
    var color: RGBColor
    /// False for text render mode 3 (invisible, e.g. an OCR layer) and mode 7 (clip only).
    var isVisible: Bool
    /// Number of non-whitespace bytes in the shown strings.
    var visibleByteCount: Int
}

/// A thin horizontal mark in the page content: a stroked line or a filled flat rectangle.
/// Candidate for an underline (or a table border, rule, ...).
struct ScannedSegment {
    var minX: Double
    var maxX: Double
    /// Vertical center in user space.
    var y: Double
    var thickness: Double
    var color: RGBColor
}

/// Walks the content stream of a PDF page with `CGPDFScanner` and records what `PDFKit` does not tell:
/// text render mode (visible or invisible), font weight, fill color of every text run, and thin horizontal
/// path objects (underline candidates). Form XObjects are followed.
final class PDFContentScanner {
    private(set) var runs: [ScannedTextRun] = []
    private(set) var segments: [ScannedSegment] = []
    /// Bounding boxes of the raster images (image XObjects) drawn on the page, in user space.
    private(set) var images: [CGRect] = []

    /// Scans `page`. `maxFormDepth` bounds the recursion into form XObjects.
    static func scan(page: CGPDFPage, maxFormDepth: Int = 4) -> PDFContentScanner {
        let scanner = PDFContentScanner()
        let state = ScanState(maxFormDepth: maxFormDepth)
        let stream = CGPDFContentStreamCreateWithPage(page)
        state.run(stream: stream)
        scanner.runs = state.runs
        scanner.segments = state.segments
        scanner.images = state.images
        return scanner
    }
}

// MARK: - Scan state

private struct GraphicsState {
    var ctm = CGAffineTransform.identity
    var fill = RGBColor.black
    var stroke = RGBColor.black
    var lineWidth = 1.0
    var fontName = ""
    var fontIsBold = false
    var fontIsTwoByte = false
    var fontSize = 0.0
    var charSpacing = 0.0
    var wordSpacing = 0.0
    var horizontalScale = 1.0
    var leading = 0.0
    var rise = 0.0
    var renderMode = 0
}

private final class ScanState {
    var runs: [ScannedTextRun] = []
    var segments: [ScannedSegment] = []
    var images: [CGRect] = []

    private var state = GraphicsState()
    private var stack: [GraphicsState] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var currentStream: CGPDFContentStreamRef?
    private let maxFormDepth: Int
    private var formDepth = 0

    // Path under construction (coordinates before the CTM).
    private var pathLines: [(CGPoint, CGPoint)] = []
    private var pathRects: [CGRect] = []
    private var currentPoint: CGPoint?
    private var subpathStart: CGPoint?

    private let table: CGPDFOperatorTableRef
    private let metricsFont = CTFontCreateWithName("Helvetica" as CFString, 1000, nil)

    init(maxFormDepth: Int) {
        self.maxFormDepth = maxFormDepth
        table = Self.makeOperatorTable()
    }

    func run(stream: CGPDFContentStreamRef) {
        let previous = currentStream
        currentStream = stream
        let info = Unmanaged.passUnretained(self).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        currentStream = previous
    }

    static func from(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    // MARK: Operand helpers

    private func number(_ scanner: CGPDFScannerRef) -> Double? {
        var value: CGPDFReal = 0
        return CGPDFScannerPopNumber(scanner, &value) ? Double(value) : nil
    }

    private func numbers(_ scanner: CGPDFScannerRef, count: Int) -> [Double]? {
        var values: [Double] = []
        for _ in 0..<count {
            guard let n = number(scanner) else { return nil }
            values.append(n)
        }
        return values.reversed()
    }

    // MARK: Graphics state

    func save() { stack.append(state) }
    func restore() { if let top = stack.popLast() { state = top } }

    func concat(_ scanner: CGPDFScannerRef) {
        guard let m = numbers(scanner, count: 6) else { return }
        state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(state.ctm)
    }

    func lineWidth(_ scanner: CGPDFScannerRef) {
        if let w = number(scanner) { state.lineWidth = w }
    }

    // MARK: Colors

    private static func color(fromComponents c: [Double]) -> RGBColor? {
        switch c.count {
        case 1: return RGBColor(red: c[0], green: c[0], blue: c[0])
        case 3: return RGBColor(red: c[0], green: c[1], blue: c[2])
        case 4:
            let k = c[3]
            return RGBColor(red: (1 - c[0]) * (1 - k), green: (1 - c[1]) * (1 - k), blue: (1 - c[2]) * (1 - k))
        default: return nil
        }
    }

    func setColor(_ scanner: CGPDFScannerRef, components: Int, fill: Bool) {
        guard let values = numbers(scanner, count: components), let color = Self.color(fromComponents: values) else { return }
        if fill { state.fill = color } else { state.stroke = color }
    }

    /// `sc`/`scn`/`SC`/`SCN`: as many numbers as there are; a trailing pattern name is ignored.
    func setColorGeneric(_ scanner: CGPDFScannerRef, fill: Bool) {
        var name: UnsafePointer<CChar>?
        _ = CGPDFScannerPopName(scanner, &name) // pattern name on top: ignore it
        var values: [Double] = []
        while let n = number(scanner) { values.append(n) }
        values.reverse()
        guard let color = Self.color(fromComponents: values) else { return }
        if fill { state.fill = color } else { state.stroke = color }
    }

    // MARK: Text state

    func beginText() {
        textMatrix = .identity
        lineMatrix = .identity
    }

    func setFont(_ scanner: CGPDFScannerRef) {
        guard let size = number(scanner) else { return }
        state.fontSize = size
        var namePointer: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &namePointer), let namePointer, let stream = currentStream else { return }
        var dictionary: CGPDFDictionaryRef?
        let object = CGPDFContentStreamGetResource(stream, "Font", namePointer)
        guard let object, CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else {
            state.fontName = String(cString: namePointer)
            state.fontIsBold = Self.nameIndicatesBold(state.fontName)
            state.fontIsTwoByte = false
            return
        }
        let info = Self.fontInfo(dictionary)
        state.fontName = info.name
        state.fontIsBold = info.isBold
        state.fontIsTwoByte = info.isTwoByte
    }

    static func nameIndicatesBold(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["bold", "black", "heavy", "semibold", "demi"].contains { lower.contains($0) }
    }

    static func fontInfo(_ font: CGPDFDictionaryRef) -> (name: String, isBold: Bool, isTwoByte: Bool) {
        var name = ""
        var pointer: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(font, "BaseFont", &pointer), let pointer { name = String(cString: pointer) }
        // Subset prefix "ABCDEF+".
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        var subtypePointer: UnsafePointer<CChar>?
        var isType0 = false
        if CGPDFDictionaryGetName(font, "Subtype", &subtypePointer), let subtypePointer {
            isType0 = String(cString: subtypePointer) == "Type0"
        }
        var isBold = nameIndicatesBold(name)

        // FontDescriptor: directly or via DescendantFonts (Type0).
        var descriptor: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor) || descriptor == nil {
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                _ = CGPDFDictionaryGetDictionary(descendant, "FontDescriptor", &descriptor)
                if name.isEmpty, CGPDFDictionaryGetName(descendant, "BaseFont", &pointer), let pointer {
                    name = String(cString: pointer)
                    isBold = isBold || nameIndicatesBold(name)
                }
            }
        }
        if let descriptor {
            var flags: CGPDFInteger = 0
            // Bit 19 (value 0x40000): ForceBold.
            if CGPDFDictionaryGetInteger(descriptor, "Flags", &flags), flags & 0x40000 != 0 { isBold = true }
            var weight: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(descriptor, "FontWeight", &weight), weight >= 600 { isBold = true }
            var fontNamePointer: UnsafePointer<CChar>?
            if name.isEmpty, CGPDFDictionaryGetName(descriptor, "FontName", &fontNamePointer), let fontNamePointer {
                name = String(cString: fontNamePointer)
                isBold = isBold || nameIndicatesBold(name)
            }
        }
        return (name, isBold, isType0)
    }

    func setCharSpacing(_ scanner: CGPDFScannerRef) { if let v = number(scanner) { state.charSpacing = v } }
    func setWordSpacing(_ scanner: CGPDFScannerRef) { if let v = number(scanner) { state.wordSpacing = v } }
    func setHorizontalScale(_ scanner: CGPDFScannerRef) { if let v = number(scanner) { state.horizontalScale = v / 100 } }
    func setLeading(_ scanner: CGPDFScannerRef) { if let v = number(scanner) { state.leading = v } }
    func setRise(_ scanner: CGPDFScannerRef) { if let v = number(scanner) { state.rise = v } }
    func setRenderMode(_ scanner: CGPDFScannerRef) { if let v = number(scanner) { state.renderMode = Int(v) } }

    func setTextMatrix(_ scanner: CGPDFScannerRef) {
        guard let m = numbers(scanner, count: 6) else { return }
        textMatrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        lineMatrix = textMatrix
    }

    func moveText(_ scanner: CGPDFScannerRef, setLeading: Bool) {
        guard let t = numbers(scanner, count: 2) else { return }
        if setLeading { state.leading = -t[1] }
        translateLine(tx: t[0], ty: t[1])
    }

    func nextLine() { translateLine(tx: 0, ty: -state.leading) }

    private func translateLine(tx: Double, ty: Double) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    // MARK: Showing text

    /// Rough advance of `bytes` in text space (before the horizontal scale is applied to nothing else):
    /// Helvetica metrics for one-byte fonts, half an em per two-byte code.
    private func advance(of bytes: [UInt8]) -> Double {
        let size = state.fontSize
        var width = 0.0
        if state.fontIsTwoByte {
            let codes = bytes.count / 2
            width = Double(codes) * 0.55 * size + Double(codes) * state.charSpacing
        } else {
            width = helveticaWidth(bytes) / 1000 * size
            width += Double(bytes.count) * state.charSpacing
            width += Double(bytes.filter { $0 == 0x20 }.count) * state.wordSpacing
        }
        return width * state.horizontalScale
    }

    private func helveticaWidth(_ bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        let units = bytes.map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(metricsFont, units, &glyphs, units.count) else {
            return Double(bytes.count) * 500
        }
        var advances = [CGSize](repeating: .zero, count: units.count)
        CTFontGetAdvancesForGlyphs(metricsFont, .horizontal, glyphs, &advances, units.count)
        return advances.reduce(0) { $0 + Double($1.width) }
    }

    func showString(_ scanner: CGPDFScannerRef) {
        guard let bytes = Self.popString(scanner) else { return }
        show(items: [.string(bytes)])
    }

    func showArray(_ scanner: CGPDFScannerRef) {
        var array: CGPDFArrayRef?
        guard CGPDFScannerPopArray(scanner, &array), let array else { return }
        var items: [ShowItem] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var string: CGPDFStringRef?
            var value: CGPDFReal = 0
            if CGPDFArrayGetString(array, index, &string), let string {
                items.append(.string(Self.bytes(of: string)))
            } else if CGPDFArrayGetNumber(array, index, &value) {
                items.append(.adjustment(Double(value)))
            }
        }
        show(items: items)
    }

    /// `'` and `"`: move to the next line, then show.
    func showStringOnNextLine(_ scanner: CGPDFScannerRef, setsSpacing: Bool) {
        guard let bytes = Self.popString(scanner) else { return }
        if setsSpacing {
            if let c = number(scanner) { state.charSpacing = c }
            if let w = number(scanner) { state.wordSpacing = w }
        }
        nextLine()
        show(items: [.string(bytes)])
    }

    enum ShowItem {
        case string([UInt8])
        case adjustment(Double)
    }

    private static func popString(_ scanner: CGPDFScannerRef) -> [UInt8]? {
        var string: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &string), let string else { return nil }
        return bytes(of: string)
    }

    private static func bytes(of string: CGPDFStringRef) -> [UInt8] {
        let length = CGPDFStringGetLength(string)
        guard length > 0, let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    private func show(items: [ShowItem]) {
        let composite = textMatrix.concatenating(state.ctm)
        let origin = CGPoint(x: 0, y: state.rise).applying(composite)
        let scaleY = (composite.c * composite.c + composite.d * composite.d).squareRoot()
        var advanceTotal = 0.0
        var visibleBytes = 0
        for item in items {
            switch item {
            case .string(let bytes):
                advanceTotal += advance(of: bytes)
                visibleBytes += bytes.filter { $0 != 0x20 && $0 != 0x00 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }.count
            case .adjustment(let thousandths):
                advanceTotal -= thousandths / 1000 * state.fontSize * state.horizontalScale
            }
        }
        let endX = CGPoint(x: advanceTotal, y: state.rise).applying(composite).x
        runs.append(ScannedTextRun(
            origin: origin, size: state.fontSize * scaleY, estimatedEndX: Double(endX),
            fontName: state.fontName, isBold: state.fontIsBold, color: state.fill,
            isVisible: state.renderMode != 3 && state.renderMode != 7, visibleByteCount: visibleBytes
        ))
        textMatrix = CGAffineTransform(translationX: advanceTotal, y: 0).concatenating(textMatrix)
    }

    // MARK: Paths

    func moveTo(_ scanner: CGPDFScannerRef) {
        guard let p = numbers(scanner, count: 2) else { return }
        currentPoint = CGPoint(x: p[0], y: p[1])
        subpathStart = currentPoint
    }

    func lineTo(_ scanner: CGPDFScannerRef) {
        guard let p = numbers(scanner, count: 2) else { return }
        let next = CGPoint(x: p[0], y: p[1])
        if let currentPoint { pathLines.append((currentPoint, next)) }
        currentPoint = next
    }

    func closePath() {
        if let currentPoint, let subpathStart, currentPoint != subpathStart {
            pathLines.append((currentPoint, subpathStart))
        }
        currentPoint = subpathStart
    }

    func curve(_ scanner: CGPDFScannerRef, operands: Int) {
        // Curves are never underlines; keep the current point moving so later segments stay consistent.
        guard let p = numbers(scanner, count: operands) else { return }
        currentPoint = CGPoint(x: p[operands - 2], y: p[operands - 1])
    }

    func rectangle(_ scanner: CGPDFScannerRef) {
        guard let r = numbers(scanner, count: 4) else { return }
        pathRects.append(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).standardized)
    }

    func paint(stroke: Bool, fill: Bool) {
        let ctm = state.ctm
        let scale = (abs(ctm.a * ctm.d - ctm.b * ctm.c)).squareRoot()
        if fill {
            for rect in pathRects {
                let t = rect.applying(ctm)
                if t.height <= 3, t.width >= 2 {
                    segments.append(ScannedSegment(
                        minX: Double(t.minX), maxX: Double(t.maxX), y: Double(t.midY),
                        thickness: Double(t.height), color: state.fill))
                }
            }
        }
        if stroke {
            let thickness = state.lineWidth * scale
            if thickness <= 3 {
                for (a, b) in pathLines {
                    let p = a.applying(ctm), q = b.applying(ctm)
                    if abs(p.y - q.y) <= 0.5, abs(p.x - q.x) >= 2 {
                        segments.append(ScannedSegment(
                            minX: Double(min(p.x, q.x)), maxX: Double(max(p.x, q.x)),
                            y: Double((p.y + q.y) / 2), thickness: thickness, color: state.stroke))
                    }
                }
            }
        }
        endPath()
    }

    func endPath() {
        pathLines.removeAll(keepingCapacity: true)
        pathRects.removeAll(keepingCapacity: true)
        currentPoint = nil
        subpathStart = nil
    }

    // MARK: Form XObjects

    func invokeXObject(_ scanner: CGPDFScannerRef) {
        var namePointer: UnsafePointer<CChar>?
        guard formDepth < maxFormDepth, CGPDFScannerPopName(scanner, &namePointer), let namePointer,
              let parent = currentStream,
              let object = CGPDFContentStreamGetResource(parent, "XObject", namePointer) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        if String(cString: subtype) == "Image" {
            images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm))
            return
        }
        guard String(cString: subtype) == "Form" else { return }

        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let form = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)

        save()
        let savedText = (textMatrix, lineMatrix)
        var matrixArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrixArray), let matrixArray, CGPDFArrayGetCount(matrixArray) == 6 {
            var m = [CGPDFReal](repeating: 0, count: 6)
            for i in 0..<6 { _ = CGPDFArrayGetNumber(matrixArray, i, &m[i]) }
            state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
                .concatenating(state.ctm)
        }
        formDepth += 1
        run(stream: form)
        formDepth -= 1
        (textMatrix, lineMatrix) = savedText
        restore()
    }

    // MARK: Operator table

    private static func makeOperatorTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!
        func set(_ name: String, _ callback: @escaping CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }
        set("q") { _, i in ScanState.from(i).save() }
        set("Q") { _, i in ScanState.from(i).restore() }
        set("cm") { s, i in ScanState.from(i).concat(s) }
        set("w") { s, i in ScanState.from(i).lineWidth(s) }

        set("g") { s, i in ScanState.from(i).setColor(s, components: 1, fill: true) }
        set("G") { s, i in ScanState.from(i).setColor(s, components: 1, fill: false) }
        set("rg") { s, i in ScanState.from(i).setColor(s, components: 3, fill: true) }
        set("RG") { s, i in ScanState.from(i).setColor(s, components: 3, fill: false) }
        set("k") { s, i in ScanState.from(i).setColor(s, components: 4, fill: true) }
        set("K") { s, i in ScanState.from(i).setColor(s, components: 4, fill: false) }
        set("sc") { s, i in ScanState.from(i).setColorGeneric(s, fill: true) }
        set("scn") { s, i in ScanState.from(i).setColorGeneric(s, fill: true) }
        set("SC") { s, i in ScanState.from(i).setColorGeneric(s, fill: false) }
        set("SCN") { s, i in ScanState.from(i).setColorGeneric(s, fill: false) }

        set("BT") { _, i in ScanState.from(i).beginText() }
        set("Tf") { s, i in ScanState.from(i).setFont(s) }
        set("Tc") { s, i in ScanState.from(i).setCharSpacing(s) }
        set("Tw") { s, i in ScanState.from(i).setWordSpacing(s) }
        set("Tz") { s, i in ScanState.from(i).setHorizontalScale(s) }
        set("TL") { s, i in ScanState.from(i).setLeading(s) }
        set("Ts") { s, i in ScanState.from(i).setRise(s) }
        set("Tr") { s, i in ScanState.from(i).setRenderMode(s) }
        set("Tm") { s, i in ScanState.from(i).setTextMatrix(s) }
        set("Td") { s, i in ScanState.from(i).moveText(s, setLeading: false) }
        set("TD") { s, i in ScanState.from(i).moveText(s, setLeading: true) }
        set("T*") { _, i in ScanState.from(i).nextLine() }
        set("Tj") { s, i in ScanState.from(i).showString(s) }
        set("TJ") { s, i in ScanState.from(i).showArray(s) }
        set("'") { s, i in ScanState.from(i).showStringOnNextLine(s, setsSpacing: false) }
        set("\"") { s, i in ScanState.from(i).showStringOnNextLine(s, setsSpacing: true) }

        set("m") { s, i in ScanState.from(i).moveTo(s) }
        set("l") { s, i in ScanState.from(i).lineTo(s) }
        set("c") { s, i in ScanState.from(i).curve(s, operands: 6) }
        set("v") { s, i in ScanState.from(i).curve(s, operands: 4) }
        set("y") { s, i in ScanState.from(i).curve(s, operands: 4) }
        set("h") { _, i in ScanState.from(i).closePath() }
        set("re") { s, i in ScanState.from(i).rectangle(s) }
        set("S") { _, i in ScanState.from(i).paint(stroke: true, fill: false) }
        set("s") { _, i in let st = ScanState.from(i); st.closePath(); st.paint(stroke: true, fill: false) }
        set("f") { _, i in ScanState.from(i).paint(stroke: false, fill: true) }
        set("F") { _, i in ScanState.from(i).paint(stroke: false, fill: true) }
        set("f*") { _, i in ScanState.from(i).paint(stroke: false, fill: true) }
        set("B") { _, i in ScanState.from(i).paint(stroke: true, fill: true) }
        set("B*") { _, i in ScanState.from(i).paint(stroke: true, fill: true) }
        set("b") { _, i in let st = ScanState.from(i); st.closePath(); st.paint(stroke: true, fill: true) }
        set("b*") { _, i in let st = ScanState.from(i); st.closePath(); st.paint(stroke: true, fill: true) }
        set("n") { _, i in ScanState.from(i).endPath() }
        set("Do") { s, i in ScanState.from(i).invokeXObject(s) }
        return table
    }
}
