import CoreGraphics
import CoreText
import Foundation

/// A point in PDF page space (origin bottom-left, unit = point).
struct Pt: Equatable, Sendable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) {
        self.x = round2(x)
        self.y = round2(y)
    }
}

/// Bounding box of points as `[x, y, w, h]`, grown by `pad` on every side.
func boundingBox(of strokes: [[Pt]], pad: Double = 0) -> [Double] {
    let all = strokes.joined()
    guard let first = all.first else { return [0, 0, 0, 0] }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in all {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    return [round2(minX - pad), round2(minY - pad), round2(maxX - minX + 2 * pad), round2(maxY - minY + 2 * pad)]
}

/// Synthetic "handwriting": glyph outlines of a handwriting-like system font, flattened to polylines.
/// Every contour (letter outline, counter, dot of an umlaut ...) becomes one stroke.
struct HandwritingFont {
    static let preferredName = "Noteworthy-Light"
    static let fallbackName = "Helvetica"

    /// Extra spacing between letters so neighbouring outlines do not touch.
    static let tracking = 0.4

    let font: CTFont
    let size: Double

    /// PostScript name of the font that is actually used (the preferred one, or the fallback).
    static var resolvedName: String {
        HandwritingFont(size: 12).postScriptName
    }

    var postScriptName: String { CTFontCopyPostScriptName(font) as String }

    /// Version string of the font that is actually used, e.g. `Version 12.0d1e1`.
    var versionString: String {
        (CTFontCopyName(font, kCTFontVersionNameKey) as String?) ?? "unknown"
    }

    /// Version string of the font that is actually used (see `resolvedName`).
    static var resolvedVersion: String {
        HandwritingFont(size: 12).versionString
    }

    init(size: Double) {
        self.size = size
        let preferred = CTFontCreateWithName(Self.preferredName as CFString, CGFloat(size), nil)
        if CTFontCopyPostScriptName(preferred) as String == Self.preferredName {
            font = preferred
        } else {
            font = CTFontCreateWithName(Self.fallbackName as CFString, CGFloat(size), nil)
        }
    }

    private func glyphs(for text: String) -> [CGGlyph] {
        let units = Array(text.precomposedStringWithCanonicalMapping.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        return glyphs
    }

    private func advance(of glyph: CGGlyph) -> Double {
        var g = glyph
        return Double(CTFontGetAdvancesForGlyphs(font, .horizontal, &g, nil, 1))
    }

    var spaceAdvance: Double {
        advance(of: glyphs(for: " ")[0])
    }

    /// Lays out one word with its left origin at `x` on `baseline`; returns the strokes and the advance width.
    func layoutWord(_ word: String, x: Double, baseline: Double) -> (strokes: [[Pt]], advance: Double) {
        var strokes: [[Pt]] = []
        var pen = x
        for glyph in glyphs(for: word) {
            if glyph != 0, let path = CTFontCreatePathForGlyph(font, glyph, nil) {
                strokes.append(contentsOf: Self.flatten(path, dx: pen, dy: baseline))
            }
            pen += advance(of: glyph) + Self.tracking
        }
        return (strokes, pen - x)
    }

    /// Flattens all subpaths of `path` into polylines (quad: 4 segments, cubic: 6), translated by (dx, dy).
    /// Closed subpaths repeat their first point at the end.
    static func flatten(_ path: CGPath, dx: Double, dy: Double) -> [[Pt]] {
        var result: [[Pt]] = []
        var current: [Pt] = []
        var last = CGPoint.zero

        func flush() {
            // drop consecutive duplicates
            var cleaned: [Pt] = []
            for p in current where cleaned.last != p { cleaned.append(p) }
            if cleaned.count >= 2 { result.append(cleaned) }
            current = []
        }
        func add(_ p: CGPoint) { current.append(Pt(Double(p.x) + dx, Double(p.y) + dy)) }

        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint:
                flush()
                last = e.points[0]
                add(last)
            case .addLineToPoint:
                last = e.points[0]
                add(last)
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                let steps = 4
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    add(CGPoint(x: u * u * last.x + 2 * u * t * c.x + t * t * p.x,
                                y: u * u * last.y + 2 * u * t * c.y + t * t * p.y))
                }
                last = p
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                let steps = 6
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    add(CGPoint(
                        x: u * u * u * last.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                        y: u * u * u * last.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y))
                }
                last = p
            case .closeSubpath:
                if let first = current.first { current.append(first) }
                flush()
            @unknown default:
                break
            }
        }
        flush()
        return result
    }
}

/// Text widths of the standard-14 fonts Helvetica / Helvetica-Bold (via the system's identical metrics).
enum HelveticaMetrics {
    static func width(_ text: String, bold: Bool, size: Double) -> Double {
        let name = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
        // Windows-1252 round trip so that the measured text is exactly what the PDF shows.
        let shown = String(decoding: WinAnsi.bytes(text).map { UInt16($0) }, as: UTF16.self)
        let units = Array(shown.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        var advances = [CGSize](repeating: .zero, count: units.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, units.count)
        return round2(advances.reduce(0) { $0 + Double($1.width) })
    }
}
