import CoreGraphics
import Foundation

/// Raw, low-level view of a PDF through CGPDFDocument (does not interpret annotations like PDFKit does).
struct RawPDF {
    let document: CGPDFDocument

    init(url: URL) throws {
        guard let doc = CGPDFDocument(url as CFURL) else { throw RawPDFError.cannotOpen(url.lastPathComponent) }
        document = doc
    }

    init(data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else {
            throw RawPDFError.cannotOpen("in-memory data")
        }
        document = doc
    }

    var pageCount: Int { document.numberOfPages }

    /// 1-based page access.
    func page(_ number: Int) throws -> RawPage {
        guard let page = document.page(at: number), let dict = page.dictionary else {
            throw RawPDFError.missingPage(number)
        }
        return RawPage(page: page, dictionary: dict)
    }
}

enum RawPDFError: Error {
    case cannotOpen(String)
    case missingPage(Int)
}

struct RawPage {
    let page: CGPDFPage
    let dictionary: CGPDFDictionaryRef

    var mediaBox: CGRect { page.getBoxRect(.mediaBox) }

    var hasAnnotsKey: Bool {
        var array: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, "Annots", &array)
    }

    var annotations: [RawAnnotation] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array else { return [] }
        var result: [RawAnnotation] = []
        for i in 0..<CGPDFArrayGetCount(array) {
            var d: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(array, i, &d), let d { result.append(RawAnnotation(dictionary: d)) }
        }
        return result
    }

    /// Decoded page content stream(s) as Latin-1 text (the fixtures write plain ASCII operators).
    var contentText: String {
        func text(of stream: CGPDFStreamRef) -> String {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream { return text(of: stream) }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return "" }
        var result = ""
        for i in 0..<CGPDFArrayGetCount(array) {
            var s: CGPDFStreamRef?
            if CGPDFArrayGetStream(array, i, &s), let s { result += text(of: s) }
        }
        return result
    }

    /// Image XObjects in the page resources: (name, width, height, color space name, bits per component).
    var imageXObjects: [RawImage] {
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return [] }
        final class Box { var images: [RawImage] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(xobjects, { key, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let d = CGPDFStreamGetDictionary(stream),
                  RawPDFValue.name(d, "Subtype") == "Image" else { return true }
            box.images.append(RawImage(
                name: String(cString: key),
                width: Int(RawPDFValue.number(d, "Width") ?? 0),
                height: Int(RawPDFValue.number(d, "Height") ?? 0),
                colorSpace: RawPDFValue.name(d, "ColorSpace"),
                bitsPerComponent: Int(RawPDFValue.number(d, "BitsPerComponent") ?? 0)))
            return true
        }, nil)
        return box.images
    }
}

struct RawImage {
    let name: String
    let width: Int
    let height: Int
    let colorSpace: String?
    let bitsPerComponent: Int
}

struct RawAnnotation {
    let dictionary: CGPDFDictionaryRef

    var subtype: String? { RawPDFValue.name(dictionary, "Subtype") }
    var rect: [Double]? { RawPDFValue.numbers(dictionary, "Rect") }
    var flags: Int? { RawPDFValue.number(dictionary, "F").map(Int.init) }
    var color: [Double]? { RawPDFValue.numbers(dictionary, "C") }
    var name: String? { RawPDFValue.string(dictionary, "NM").flatMap { String(bytes: $0, encoding: .isoLatin1) } }

    /// Border width from /BS /W.
    var borderWidth: Double? {
        var bs: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "BS", &bs), let bs else { return nil }
        return RawPDFValue.number(bs, "W")
    }

    /// One array of coordinates per entry of /InkList.
    var inkList: [[Double]]? {
        var list: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "InkList", &list), let list else { return nil }
        var result: [[Double]] = []
        for i in 0..<CGPDFArrayGetCount(list) {
            var inner: CGPDFArrayRef?
            guard CGPDFArrayGetArray(list, i, &inner), let inner else { return nil }
            result.append(RawPDFValue.numbers(inner))
        }
        return result
    }

    /// Raw bytes of /Contents.
    var contentsBytes: [UInt8]? { RawPDFValue.string(dictionary, "Contents") }

    /// /Contents decoded from UTF-16BE (requires the FEFF byte order mark).
    var contents: String? {
        guard let bytes = contentsBytes, bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF else { return nil }
        return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian)
    }

    var hasNormalAppearance: Bool {
        var ap: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "AP", &ap), let ap else { return false }
        var n: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(ap, "N", &n)
    }

    /// Content of the normal appearance stream (/AP /N) as text; empty if there is none.
    var appearanceText: String {
        var ap: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "AP", &ap), let ap,
              CGPDFDictionaryGetStream(ap, "N", &stream), let stream else { return "" }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the appearance stream declares an ExtGState with /BM /Multiply.
    var appearanceUsesMultiply: Bool {
        var ap: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "AP", &ap), let ap,
              CGPDFDictionaryGetStream(ap, "N", &stream), let stream,
              let sd = CGPDFStreamGetDictionary(stream) else { return false }
        var resources: CGPDFDictionaryRef?
        var gstates: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(sd, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "ExtGState", &gstates), let gstates else { return false }
        final class Box { var multiply = false }
        let box = Box()
        CGPDFDictionaryApplyBlock(gstates, { _, object, _ in
            var gs: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &gs), let gs, RawPDFValue.name(gs, "BM") == "Multiply" {
                box.multiply = true
            }
            return true
        }, nil)
        return box.multiply
    }

    /// Everything about an annotation that does not depend on its geometry: subtype, color, stroke width, flags,
    /// whether it has an appearance stream and whether that uses Multiply, plus /Contents for text annotations.
    var signature: String {
        [subtype ?? "?", colorHex ?? "-", borderWidth.map { String($0) } ?? "-", flags.map(String.init) ?? "-",
         hasNormalAppearance ? "AP" : "noAP", appearanceUsesMultiply ? "multiply" : "normal",
         contents ?? "-", RawPDFValue.name(dictionary, "Name") ?? "-"].joined(separator: "|")
    }

    /// `#RRGGBB` from /C.
    var colorHex: String? {
        guard let c = color, c.count == 3 else { return nil }
        let bytes = c.map { Int(($0 * 255).rounded()) }
        return "#" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    var isYellow: Bool {
        guard let c = color, c.count == 3 else { return false }
        return c[0] > 0.9 && c[1] > 0.8 && c[2] < 0.4
    }
}

enum RawPDFValue {
    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var p: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(d, key, &p), let p else { return nil }
        return String(cString: p)
    }

    static func number(_ d: CGPDFDictionaryRef, _ key: String) -> Double? {
        var v: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(d, key, &v) else { return nil }
        return Double(v)
    }

    static func numbers(_ d: CGPDFDictionaryRef, _ key: String) -> [Double]? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(d, key, &array), let array else { return nil }
        return numbers(array)
    }

    static func numbers(_ array: CGPDFArrayRef) -> [Double] {
        (0..<CGPDFArrayGetCount(array)).compactMap { i in
            var v: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, i, &v) ? Double(v) : nil
        }
    }

    static func string(_ d: CGPDFDictionaryRef, _ key: String) -> [UInt8]? {
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &s), let s, let ptr = CGPDFStringGetBytePtr(s) else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: CGPDFStringGetLength(s)))
    }
}

/// Checks the classic cross-reference table of a PDF: every entry must point at `<n> 0 obj`.
func validateXref(_ data: Data) -> [String] {
    var problems: [String] = []
    let text = String(decoding: data, as: UTF8.self)
    guard let startRange = text.range(of: "startxref\n", options: .backwards) else { return ["no startxref"] }
    let after = text[startRange.upperBound...]
    guard let offset = Int(after.prefix { $0.isNumber }) else { return ["bad startxref offset"] }
    let bytes = [UInt8](data)
    guard offset + 4 <= bytes.count, String(decoding: bytes[offset..<offset + 4], as: UTF8.self) == "xref" else {
        return ["startxref does not point at xref"]
    }
    let tableText = String(decoding: bytes[offset...], as: UTF8.self)
    let lines = tableText.split(separator: "\n", omittingEmptySubsequences: false)
    // lines: "xref", "0 N", then N entries
    guard lines.count > 2, let header = lines[1].split(separator: " ").last, let count = Int(header) else {
        return ["bad xref header"]
    }
    for index in 1..<count {
        let entry = lines[2 + index]
        let parts = entry.split(separator: " ")
        guard entry.utf8.count == 19, parts.count == 3, let off = Int(parts[0]) else {
            problems.append("bad xref entry \(index): '\(entry)'")
            continue
        }
        let expected = "\(index) 0 obj"
        let end = min(off + expected.utf8.count, bytes.count)
        if off >= bytes.count || String(decoding: bytes[off..<end], as: UTF8.self) != expected {
            problems.append("xref entry \(index) does not point at '\(expected)'")
        }
    }
    return problems
}
