import Foundation

// MARK: - Number and string formatting

/// Formats a number for PDF output with at most `decimals` fractional digits and no trailing zeros.
/// Output is locale independent and deterministic.
func pdfNumber(_ value: Double, decimals: Int = 2) -> String {
    let factor = pow(10.0, Double(decimals))
    let rounded = (value * factor).rounded() / factor
    if rounded == rounded.rounded() {
        return String(Int(rounded))
    }
    var text = String(format: "%.\(decimals)f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

/// Rounds to two decimals (used for every coordinate that ends up in a file).
func round2(_ value: Double) -> Double {
    let r = (value * 100).rounded() / 100
    return r == 0 ? 0 : r
}

func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

/// Windows-1252 ("WinAnsiEncoding") encoding of strings for standard-14 fonts.
enum WinAnsi {
    private static let extras: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86,
        0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C,
        0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95,
        0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B,
        0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    static func bytes(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if v < 0x80 || (v >= 0xA0 && v <= 0xFF) {
                out.append(UInt8(v))
            } else if let b = extras[v] {
                out.append(b)
            } else {
                out.append(0x3F) // "?"
            }
        }
        return out
    }

    /// A PDF literal string `( ... )` that only contains printable ASCII (high bytes become octal escapes).
    static func literal(_ text: String) -> String {
        var s = "("
        for b in bytes(text) {
            switch b {
            case 0x28, 0x29, 0x5C:
                s += "\\" + String(UnicodeScalar(b))
            case 0x20...0x7E:
                s += String(UnicodeScalar(b))
            default:
                let oct = String(b, radix: 8)
                s += "\\" + String(repeating: "0", count: 3 - oct.count) + oct
            }
        }
        return s + ")"
    }
}

/// PDF text string: a literal string for plain ASCII, otherwise UTF-16BE hex with byte order mark.
func pdfTextString(_ text: String) -> String {
    if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
        return WinAnsi.literal(text)
    }
    return pdfUTF16Hex(text)
}

/// UTF-16BE hex string with BOM, e.g. `<FEFF0041>`.
func pdfUTF16Hex(_ text: String) -> String {
    var hex = "<FEFF"
    for unit in text.utf16 {
        let h = String(unit, radix: 16, uppercase: true)
        hex += String(repeating: "0", count: 4 - h.count) + h
    }
    return hex + ">"
}

// MARK: - Object table writer

struct PDFRef: Hashable {
    let number: Int
    var ref: String { "\(number) 0 R" }
}

/// Minimal PDF 1.7 writer: numbered objects, uncompressed streams, classic xref table.
/// No timestamps and no /ID, so output is byte-deterministic for identical input.
struct PDFBuilder {
    private var objects: [Data?] = []

    mutating func reserve() -> PDFRef {
        objects.append(nil)
        return PDFRef(number: objects.count)
    }

    mutating func set(_ ref: PDFRef, _ body: String) {
        objects[ref.number - 1] = Data(body.utf8)
    }

    mutating func set(_ ref: PDFRef, stream dictionary: String, data: Data) {
        var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        body.append(data)
        body.append(Data("\nendstream".utf8))
        objects[ref.number - 1] = body
    }

    @discardableResult
    mutating func add(_ body: String) -> PDFRef {
        let ref = reserve()
        set(ref, body)
        return ref
    }

    @discardableResult
    mutating func addStream(_ dictionary: String, data: Data) -> PDFRef {
        let ref = reserve()
        set(ref, stream: dictionary, data: data)
        return ref
    }

    func serialize(root: PDFRef, info: PDFRef) -> Data {
        var out = Data("%PDF-1.7\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]) // binary marker comment
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            precondition(object != nil, "PDF object \(index + 1) was reserved but never set")
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(object!)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            let digits = String(offset)
            xref += String(repeating: "0", count: 10 - digits.count) + digits + " 00000 n \n"
        }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root \(root.ref) /Info \(info.ref) >>\n"
        xref += "startxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }
}

// MARK: - Colors

/// A color given as `#RRGGBB`.
struct HexColor {
    let hex: String
    let r: Double
    let g: Double
    let b: Double

    init(_ hex: String) {
        self.hex = hex.uppercased()
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        r = Double((value >> 16) & 0xFF) / 255
        g = Double((value >> 8) & 0xFF) / 255
        b = Double(value & 0xFF) / 255
    }

    /// `r g b` with three decimals, as used in /C arrays and color operators.
    var components: String {
        [r, g, b].map { pdfNumber($0, decimals: 3) }.joined(separator: " ")
    }
}

/// Accumulates page-content operators as ASCII text.
struct ContentStream {
    private(set) var text = ""

    mutating func raw(_ s: String) { text += s + "\n" }
    mutating func save() { raw("q") }
    mutating func restore() { raw("Q") }
    mutating func strokeColor(_ c: HexColor) { raw("\(c.components) RG") }
    mutating func fillColor(_ c: HexColor) { raw("\(c.components) rg") }
    mutating func lineWidth(_ w: Double) { raw("\(pdfNumber(w)) w") }

    mutating func polyline(_ points: [Pt]) {
        guard let first = points.first else { return }
        raw("\(pdfNumber(first.x)) \(pdfNumber(first.y)) m")
        for p in points.dropFirst() { raw("\(pdfNumber(p.x)) \(pdfNumber(p.y)) l") }
    }

    mutating func rect(x: Double, y: Double, w: Double, h: Double) {
        raw("\(pdfNumber(x)) \(pdfNumber(y)) \(pdfNumber(w)) \(pdfNumber(h)) re")
    }

    /// Visible or invisible text run (`renderMode` 3 = invisible).
    mutating func text(_ string: String, font: String, size: Double, x: Double, y: Double,
                       color: HexColor? = nil, renderMode: Int = 0, horizontalScale: Double = 100) {
        raw("BT")
        if let color { fillColor(color) }
        if renderMode != 0 { raw("\(renderMode) Tr") }
        raw("/\(font) \(pdfNumber(size)) Tf")
        if horizontalScale != 100 { raw("\(pdfNumber(horizontalScale)) Tz") }
        raw("\(pdfNumber(x)) \(pdfNumber(y)) Td")
        raw("\(WinAnsi.literal(string)) Tj")
        raw("ET")
    }
}
