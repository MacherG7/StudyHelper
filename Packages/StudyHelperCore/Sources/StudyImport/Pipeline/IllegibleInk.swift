import CoreGraphics
import Foundation
import StudyCore

/// Finds handwriting that the recognizer did not read at all (Vision drops regions it cannot read) and turns each
/// such ink area into an empty line with status `.illegible`, so that the review shows it and the user types the
/// text (SPEC §2: illegible spots are marked, never guessed).
enum IllegibleInk {
    /// Strokes whose center lies this far (in line heights) outside a recognized word still belong to it
    /// (descenders, dots, crossbars).
    static let wordMargin = 0.3
    /// Unexplained strokes closer than this (in line heights) form one area.
    static let clusterGap = 0.5
    /// Smaller areas are specks, not writing.
    static let minimumSize = 0.4
    /// Straight strokes at least this long (in line heights) are lines (underline, table border, arrow), not writing.
    static let longStrokeLength = 1.5
    static let fallbackLineHeight = 14.0

    /// - Parameters:
    ///   - page: the Goodnotes page (strokes in rotated page space).
    ///   - recognized: all recognized lines of the page.
    ///   - shapeRects: areas of detected underlines, circles and the like (normalized); strokes inside are shapes.
    /// - Returns: lines with empty text, status `.illegible`, reason `.unreadable`, the ink area as rect and the pen color.
    static func lines(page: GoodnotesPage, recognized: [RecognizedLine], shapeRects: [NormalizedRect]) -> [RecognizedLine] {
        let width = page.size.width, height = page.size.height
        guard width > 0, height > 0, !page.strokes.isEmpty else { return [] }

        func points(_ r: NormalizedRect) -> CGRect {
            CGRect(x: r.x * width, y: r.y * height, width: r.width * width, height: r.height * height)
        }

        // Typical line height in points.
        let heights = recognized.filter { !$0.words.isEmpty }.map { $0.rect.height * height }.sorted()
        let lineHeight = heights.isEmpty ? fallbackLineHeight : max(6, heights[heights.count / 2])

        // Areas that explain ink: word boxes (the line box for lines without word boxes).
        var wordRects: [CGRect] = []
        /// Lines with text tokens that have no word entry (punctuation): small marks inside them are explained.
        var punctuationLines: [CGRect] = []
        for line in recognized where line.status != .illegible {
            if line.words.isEmpty {
                if !line.text.trimmingCharacters(in: .whitespaces).isEmpty { wordRects.append(points(line.rect)) }
                continue
            }
            for word in line.words where !word.rect.isEmpty { wordRects.append(points(word.rect)) }
            let tokens = LineTextAlignment.tokens(of: line.text, words: line.words)
            if tokens.contains(where: { $0.wordIndex == nil }) { punctuationLines.append(points(line.rect)) }
        }
        let shapes = shapeRects.map(points)

        struct Candidate {
            var index: Int
            var box: CGRect
        }
        let highlighters = page.highlighterFlags
        var candidates: [Candidate] = []
        for (index, stroke) in page.strokes.enumerated() where !highlighters[index] && !stroke.points.isEmpty {
            let box = points(stroke.boundingBox(pageSize: page.size))
            let center = CGPoint(x: box.midX, y: box.midY)
            if isLongStraight(stroke, minimum: longStrokeLength * lineHeight, pageHeight: height) { continue }
            if shapes.contains(where: { rect in
                let overlap = box.intersection(rect)
                return !overlap.isNull && overlap.width * overlap.height >= 0.8 * max(1, box.width * box.height)
            }) { continue }
            let margin = wordMargin * lineHeight
            if wordRects.contains(where: { $0.insetBy(dx: -margin, dy: -margin).contains(center) }) { continue }
            let overlap = wordRects.contains { rect in
                let o = box.intersection(rect)
                return !o.isNull && o.width * o.height >= 0.5 * max(1, box.width * box.height)
            }
            if overlap { continue }
            candidates.append(Candidate(index: index, box: box))
        }
        guard !candidates.isEmpty else { return [] }

        // Connected areas of the unexplained strokes.
        var parent = Array(candidates.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let gap = clusterGap * lineHeight
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                if candidates[i].box.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(candidates[j].box.insetBy(dx: -gap / 2, dy: -gap / 2)) {
                    parent[find(j)] = find(i)
                }
            }
        }
        var groups: [Int: [Candidate]] = [:]
        var rootOrder: [Int] = []
        for i in candidates.indices {
            let root = find(i)
            if groups[root] == nil { rootOrder.append(root) }
            groups[root, default: []].append(candidates[i])
        }

        var result: [RecognizedLine] = []
        for root in rootOrder {
            let members = groups[root] ?? []
            let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
            let longest = max(box.width, box.height)
            guard longest >= minimumSize * lineHeight else { continue }
            if longest <= lineHeight, punctuationLines.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: box.midX, y: box.midY)) }) {
                continue
            }
            let color = page.strokes[members[0].index].color
            let rect = NormalizedRect(
                x: Double(box.minX) / width, y: Double(box.minY) / height,
                width: Double(box.width) / width, height: Double(box.height) / height)
            result.append(RecognizedLine(
                text: "", rect: rect, confidence: 0, words: [], status: .illegible,
                reviewReasons: [.unreadable], color: color))
        }
        return result
    }

    /// Nearly straight stroke (path barely longer than its chord) with a chord of at least `minimum` points.
    private static func isLongStraight(_ stroke: InkStroke, minimum: Double, pageHeight: Double) -> Bool {
        guard stroke.points.count >= 2, let first = stroke.points.first, let last = stroke.points.last else { return false }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord >= minimum else { return false }
        var length = 0.0
        var previous = first
        for p in stroke.points.dropFirst() {
            length += hypot(p.x - previous.x, p.y - previous.y)
            previous = p
        }
        return length <= 1.25 * chord
    }
}
