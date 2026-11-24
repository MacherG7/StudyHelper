import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Arrows drawn with the Goodnotes shape tool inside a text row ("Kausalkette (→ B.S.35)"). They are stamp
/// annotations, not ink, so the recognizer never sees them; the arrow is read from the stamp's appearance
/// (a stroked shaft plus a head) and inserted into the text of the line it sits in.
enum ShapeArrows {
    struct Arrow: Equatable {
        /// Normalized page rect (origin top-left).
        var rect: NormalizedRect
        var symbol: String
    }

    /// Two points closer than this (in form units) are the same point.
    static let joinTolerance = 2.5
    /// An arrow taller than this (in line heights) is a connector between rows, not part of a text row.
    static let maximumHeight = 1.5
    /// Largest gap (in line heights) between the arrow and the end of the line it belongs to.
    static let maximumGap = 1.5

    // MARK: Reading the stamps

    /// Arrow stamps of `page` with their direction.
    static func arrows(of page: PDFPage) -> [Arrow] {
        guard let cgPage = page.pageRef, let dictionary = cgPage.dictionary else { return [] }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return [] }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { return [] }
        var result: [Arrow] = []
        let pageStream = CGPDFContentStreamCreateWithPage(cgPage)
        defer { CGPDFContentStreamRelease(pageStream) }
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
                  let rect = rectangle(annot, key: "Rect"),
                  let shape = PathCollector.collect(normal, parent: pageStream),
                  let direction = direction(of: shape) else { continue }
            // Form space → page user space: the form's bounding box is fitted into the annotation rect.
            let form = shape.bbox ?? rect
            guard form.width > 0, form.height > 0 else { continue }
            func toPage(_ p: CGPoint) -> CGPoint {
                CGPoint(x: rect.minX + (p.x - form.minX) * rect.width / form.width,
                        y: rect.minY + (p.y - form.minY) * rect.height / form.height)
            }
            func normalized(_ p: CGPoint) -> NormalizedRect {
                NormalizedRect.fromBottomLeft(
                    x: Double(p.x - box.minX), y: Double(p.y - box.minY), width: 0, height: 0,
                    spaceWidth: Double(box.width), spaceHeight: Double(box.height)).rotatedClockwise(page.rotation)
            }
            let tail = normalized(toPage(direction.tail)), tip = normalized(toPage(direction.tip))
            let dx = (tip.x - tail.x) * Double(box.width), dy = (tip.y - tail.y) * Double(box.height)
            let pageRect = NormalizedRect.fromBottomLeft(
                x: Double(rect.minX - box.minX), y: Double(rect.minY - box.minY),
                width: Double(rect.width), height: Double(rect.height),
                spaceWidth: Double(box.width), spaceHeight: Double(box.height)).rotatedClockwise(page.rotation)
            result.append(Arrow(rect: pageRect, symbol: symbol(dx: dx, dy: dy, bothEnds: direction.bothEnds)))
        }
        return result
    }

    /// Arrow symbol for a direction in top-left page space (y grows downwards).
    static func symbol(dx: Double, dy: Double, bothEnds: Bool) -> String {
        if abs(dx) >= 2 * abs(dy) { return bothEnds ? "↔" : (dx > 0 ? "→" : "←") }
        if abs(dy) >= 2 * abs(dx) { return bothEnds ? "↕" : (dy > 0 ? "↓" : "↑") }
        switch (dx > 0, dy > 0) {
        case (true, true): return "↘"
        case (true, false): return "↗"
        case (false, true): return "↙"
        case (false, false): return "↖"
        }
    }

    /// The stroked paths of a stamp appearance in form space.
    struct Shape {
        var subpaths: [[CGPoint]]
        var hasRectangle: Bool
        var bbox: CGRect?
    }

    /// Shaft (the longest open subpath) and head(s): a short subpath (2 legs, or a small triangle) touching one
    /// end of the shaft. Nil for anything else (boxes, plain lines, curly brackets without a head …).
    static func direction(of shape: Shape) -> (tail: CGPoint, tip: CGPoint, bothEnds: Bool)? {
        guard !shape.hasRectangle, shape.subpaths.count >= 2, shape.subpaths.count <= 3 else { return nil }
        func length(_ path: [CGPoint]) -> Double {
            zip(path, path.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        let sorted = shape.subpaths.sorted { length($0) > length($1) }
        guard let shaft = sorted.first, let start = shaft.first, let end = shaft.last,
              hypot(end.x - start.x, end.y - start.y) > 0 else { return nil }
        let shaftLength = hypot(end.x - start.x, end.y - start.y)
        var headAtStart = false, headAtEnd = false
        for head in sorted.dropFirst() {
            guard head.count >= 3, head.count <= 5, length(head) < 1.5 * shaftLength else { return nil }
            func touches(_ p: CGPoint) -> Bool {
                head.contains { hypot($0.x - p.x, $0.y - p.y) <= joinTolerance + 0.05 * shaftLength }
            }
            if touches(end) { headAtEnd = true } else if touches(start) { headAtStart = true } else { return nil }
        }
        switch (headAtStart, headAtEnd) {
        case (false, true): return (start, end, false)
        case (true, false): return (end, start, false)
        case (true, true): return (start, end, true)
        default: return nil
        }
    }

    private static func rectangle(_ dictionary: CGPDFDictionaryRef, key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values: [CGFloat] = []
        for index in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else { return nil }
            values.append(value)
        }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    // MARK: Inserting into lines

    /// Inserts every arrow that sits in a text row into that line's text, at its horizontal position.
    /// Lines the user corrected and arrows outside any row (connectors between boxes) are left alone.
    static func insert(_ arrows: [Arrow], into lines: [RecognizedLine]) -> [RecognizedLine] {
        guard !arrows.isEmpty else { return lines }
        let heights = lines.filter { !$0.rect.isEmpty && $0.status != .illegible }.map(\.rect.height).sorted()
        guard !heights.isEmpty else { return lines }
        let lineHeight = heights[heights.count / 2]
        var result = lines
        for arrow in arrows.sorted(by: { $0.rect.x < $1.rect.x }) where arrow.rect.height <= maximumHeight * lineHeight {
            let midY = arrow.rect.midY, midX = arrow.rect.midX
            var best: (index: Int, distance: Double)?
            for (index, line) in result.enumerated()
            where !line.rect.isEmpty && line.status != .illegible && !line.isUserCorrected
                && !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                let r = line.rect
                guard midY >= r.y, midY <= r.maxY else { continue }
                let gap = max(r.x - arrow.rect.maxX, arrow.rect.x - r.maxX, 0)
                guard gap <= maximumGap * lineHeight else { continue }
                let distance = gap + abs(r.midY - midY)
                if distance < (best?.distance ?? .infinity) { best = (index, distance) }
            }
            guard let best else { continue }
            result[best.index].text = inserting(arrow.symbol, atX: midX, into: result[best.index])
        }
        return result
    }

    /// The line text with `symbol` placed between the tokens left and right of `x`.
    static func inserting(_ symbol: String, atX x: Double, into line: RecognizedLine) -> String {
        let tokens = LineTextAlignment.tokens(of: line.text, words: line.words)
        guard !tokens.isEmpty else { return symbol }
        // Token centers: word boxes where known, otherwise the position estimated from the character offset.
        let total = Double(max(1, tokens.reduce(0) { $0 + $1.text.count } + tokens.count - 1))
        var offset = 0
        var centers: [Double] = []
        for token in tokens {
            let estimated = line.rect.x + line.rect.width * (Double(offset) + Double(token.text.count) / 2) / total
            if let index = token.wordIndex, index < line.words.count, !line.words[index].rect.isEmpty {
                centers.append(line.words[index].rect.midX)
            } else {
                centers.append(estimated)
            }
            offset += token.text.count + 1
        }
        let position = centers.filter { $0 < x }.count
        var pieces = tokens.map(\.text)
        // Already there (e.g. typed text or a second pass): nothing to add.
        if position > 0, pieces[position - 1].hasSuffix(symbol) { return line.text }
        if position < pieces.count, pieces[position].hasPrefix(symbol) { return line.text }
        if position > 0, ["(", "[", "„", "\""].contains(pieces[position - 1]) {
            pieces[position - 1] += symbol
        } else {
            pieces.insert(symbol, at: position)
        }
        return pieces.joined(separator: " ")
    }
}

/// Collects the stroked subpaths of a form XObject (an annotation appearance) with `CGPDFScanner`.
private final class PathCollector {
    var subpaths: [[CGPoint]] = []
    var hasRectangle = false
    private var current: [[CGPoint]] = []
    /// The path under construction contains a rectangle (`re`); only painted rectangles count, not clip areas.
    private var currentHasRectangle = false
    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []

    static func collect(_ stream: CGPDFStreamRef, parent: CGPDFContentStreamRef) -> ShapeArrows.Shape? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let collector = PathCollector()
        let table = makeTable()
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(collector).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        var bbox: CGRect?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "BBox", &array), let array, CGPDFArrayGetCount(array) == 4 {
            var v: [CGFloat] = []
            for i in 0..<4 { var n: CGPDFReal = 0; if CGPDFArrayGetNumber(array, i, &n) { v.append(n) } }
            if v.count == 4 { bbox = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1])) }
        }
        return ShapeArrows.Shape(subpaths: collector.subpaths, hasRectangle: collector.hasRectangle, bbox: bbox)
    }

    private static func from(_ info: UnsafeMutableRawPointer?) -> PathCollector {
        Unmanaged<PathCollector>.fromOpaque(info!).takeUnretainedValue()
    }

    private func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values.append(value)
        }
        return values.reversed()
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(ctm) }

    private static func makeTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in let c = PathCollector.from(info); c.stack.append(c.ctm) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in let c = PathCollector.from(info); if let t = c.stack.popLast() { c.ctm = t } }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let c = PathCollector.from(info)
            guard let m = c.numbers(scanner, 6) else { return }
            c.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(c.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let c = PathCollector.from(info)
            guard let v = c.numbers(scanner, 2) else { return }
            c.current.append([c.point(v[0], v[1])])
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let c = PathCollector.from(info)
            guard let v = c.numbers(scanner, 2), !c.current.isEmpty else { return }
            c.current[c.current.count - 1].append(c.point(v[0], v[1]))
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            let c = PathCollector.from(info)
            guard let v = c.numbers(scanner, 6), !c.current.isEmpty else { return }
            c.current[c.current.count - 1].append(c.point(v[4], v[5]))
        }
        for name in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, name) { scanner, info in
                let c = PathCollector.from(info)
                guard let v = c.numbers(scanner, 4), !c.current.isEmpty else { return }
                c.current[c.current.count - 1].append(c.point(v[2], v[3]))
            }
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            let c = PathCollector.from(info)
            guard let first = c.current.last?.first else { return }
            c.current[c.current.count - 1].append(first)
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let c = PathCollector.from(info)
            _ = c.numbers(scanner, 4)
            c.current.append([])
            c.currentHasRectangle = true
        }
        // Painting: stroked or filled paths count (a head may be a filled triangle); "n" only clips.
        for name in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, name) { _, info in
                let c = PathCollector.from(info)
                c.subpaths += c.current.filter { $0.count >= 2 }
                c.hasRectangle = c.hasRectangle || c.currentHasRectangle
                c.current = []
                c.currentHasRectangle = false
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            let c = PathCollector.from(info)
            c.current = []
            c.currentHasRectangle = false
        }
        return table
    }
}
