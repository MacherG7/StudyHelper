import CoreGraphics
import Foundation
import StudyCore

/// Finds handwriting that the recognizer did not read at all (Vision drops regions it cannot read) and turns each
/// such ink area into an empty line with status `.illegible`, so that the review shows it and the user types the
/// text (SPEC §2: illegible spots are marked, never guessed).
///
/// The same "ink that nobody explains" is what the second chance (`HandwritingRetry`) tries to read again before
/// anything is reported as illegible.
enum IllegibleInk {
    /// Strokes whose center lies this far (in line heights) outside a recognized word still belong to it
    /// (descenders, dots, crossbars).
    static let wordMargin = 0.3
    /// Vertical share of that margin: smaller, so that ink of the neighbouring row of dense handwriting is not
    /// swallowed by the (imprecise) word boxes of this row.
    static let wordVerticalMargin = 0.15
    /// Strokes inside a recognized line box (grown by this many line heights) are explained as well …
    static let lineMargin = 0.15
    /// … unless they are further than this (in line heights) from every word of the line (a word the recognizer
    /// skipped in the middle of a line).
    static let lineGapAllowance = 0.5
    /// Unexplained strokes closer than this (in line heights) form one area.
    static let clusterGap = 0.5
    /// Smaller areas are specks, not writing.
    static let minimumSize = 0.4
    /// Straight strokes at least this long (in line heights) are lines (underline, table border, arrow), not writing.
    static let longStrokeLength = 1.5
    static let fallbackLineHeight = 14.0

    /// A pen stroke that no recognized text explains.
    struct Candidate {
        var index: Int
        /// Bounding box in page points, origin top-left.
        var box: CGRect
    }

    /// Typical line height in points: the median height of the recognized lines (without illegible ones).
    static func lineHeight(page: GoodnotesPage, recognized: [RecognizedLine]) -> Double {
        let heights = recognized.filter { !$0.words.isEmpty && $0.status != .illegible }
            .map { $0.rect.height * page.size.height }.sorted()
        return heights.isEmpty ? fallbackLineHeight : max(6, heights[heights.count / 2])
    }

    /// Strokes that can be handwriting: pen strokes without highlighters, long straight strokes (underlines, table
    /// borders, arrows) and strokes inside detected shapes.
    static func textStrokes(
        page: GoodnotesPage, strokeIndices: [Int]? = nil, shapeRects: [NormalizedRect], lineHeight: Double
    ) -> [Candidate] {
        let width = page.size.width, height = page.size.height
        guard width > 0, height > 0, !page.strokes.isEmpty else { return [] }
        func points(_ r: NormalizedRect) -> CGRect {
            CGRect(x: r.x * width, y: r.y * height, width: r.width * width, height: r.height * height)
        }
        let shapes = shapeRects.map(points)
        let highlighters = page.highlighterFlags
        var result: [Candidate] = []
        for index in strokeIndices ?? Array(page.strokes.indices) where index < page.strokes.count {
            let stroke = page.strokes[index]
            guard !highlighters[index], !stroke.points.isEmpty else { continue }
            let box = points(stroke.boundingBox(pageSize: page.size))
            if isLongStraight(stroke, minimum: longStrokeLength * lineHeight, pageHeight: height) { continue }
            if shapes.contains(where: { rect in
                let overlap = box.intersection(rect)
                return !overlap.isNull && overlap.width * overlap.height >= 0.8 * max(1, box.width * box.height)
            }) { continue }
            result.append(Candidate(index: index, box: box))
        }
        return result
    }

    /// Pen strokes (highlighters, long straight strokes and shapes excluded) that neither a recognized word nor a
    /// recognized line explains.
    /// - Parameters:
    ///   - page: the Goodnotes page (strokes in rotated page space).
    ///   - strokeIndices: strokes to look at; nil means all strokes of the page.
    ///   - recognized: recognized lines that explain ink.
    ///   - shapeRects: areas of detected underlines, circles and the like (normalized); strokes inside are shapes.
    ///   - lineHeight: typical line height in points.
    static func unexplainedStrokes(
        page: GoodnotesPage, strokeIndices: [Int]? = nil, recognized: [RecognizedLine], shapeRects: [NormalizedRect],
        lineHeight: Double
    ) -> [Candidate] {
        let width = page.size.width, height = page.size.height
        guard width > 0, height > 0, !page.strokes.isEmpty else { return [] }

        func points(_ r: NormalizedRect) -> CGRect {
            CGRect(x: r.x * width, y: r.y * height, width: r.width * width, height: r.height * height)
        }

        // Areas that explain ink: word boxes (the line box for lines without word boxes) and line boxes.
        var wordRects: [CGRect] = []
        struct LineArea {
            var rect: CGRect
            var wordRects: [CGRect]
        }
        var lineAreas: [LineArea] = []
        /// Lines with text tokens that have no word entry (punctuation): small marks inside them are explained.
        var punctuationLines: [CGRect] = []
        for line in recognized where line.status != .illegible {
            if line.words.isEmpty {
                if !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    wordRects.append(points(line.rect))
                    lineAreas.append(LineArea(rect: points(line.rect), wordRects: []))
                }
                continue
            }
            let words = line.words.filter { !$0.rect.isEmpty }.map { points($0.rect) }
            wordRects += words
            lineAreas.append(LineArea(rect: points(line.rect), wordRects: words))
            let tokens = LineTextAlignment.tokens(of: line.text, words: line.words)
            if tokens.contains(where: { $0.wordIndex == nil }) { punctuationLines.append(points(line.rect)) }
        }
        let margin = wordMargin * lineHeight
        let verticalMargin = wordVerticalMargin * lineHeight
        let lineGrow = lineMargin * lineHeight
        let allowance = lineGapAllowance * lineHeight

        var candidates: [Candidate] = []
        for stroke in textStrokes(page: page, strokeIndices: strokeIndices, shapeRects: shapeRects, lineHeight: lineHeight) {
            let index = stroke.index, box = stroke.box
            let center = CGPoint(x: box.midX, y: box.midY)
            if wordRects.contains(where: { $0.insetBy(dx: -margin, dy: -verticalMargin).contains(center) }) { continue }
            let overlap = wordRects.contains { rect in
                let o = box.intersection(rect)
                return !o.isNull && o.width * o.height >= 0.5 * max(1, box.width * box.height)
            }
            if overlap { continue }
            // Vision's word boxes are imprecise: ink inside the line box and near one of its words is explained.
            let inLine = lineAreas.contains { area in
                guard area.rect.insetBy(dx: -lineGrow, dy: -lineGrow).contains(center) else { return false }
                if area.wordRects.isEmpty { return true }
                return area.wordRects.contains { word in
                    center.x >= word.minX - allowance && center.x <= word.maxX + allowance
                }
            }
            if inLine { continue }
            candidates.append(Candidate(index: index, box: box))
        }
        return candidates
    }

    /// - Parameters:
    ///   - page: the Goodnotes page (strokes in rotated page space).
    ///   - recognized: all recognized lines of the page.
    ///   - shapeRects: areas of detected underlines, circles and the like (normalized); strokes inside are shapes.
    /// - Returns: lines with empty text, status `.illegible`, reason `.unreadable`, the ink area as rect and the pen color.
    ///   An area never spans more than one text row.
    static func lines(page: GoodnotesPage, recognized: [RecognizedLine], shapeRects: [NormalizedRect]) -> [RecognizedLine] {
        let width = page.size.width, height = page.size.height
        guard width > 0, height > 0, !page.strokes.isEmpty else { return [] }

        let lineHeight = lineHeight(page: page, recognized: recognized)
        let punctuationLines: [CGRect] = recognized.filter { $0.status != .illegible && !$0.words.isEmpty }.compactMap { line in
            let tokens = LineTextAlignment.tokens(of: line.text, words: line.words)
            guard tokens.contains(where: { $0.wordIndex == nil }) else { return nil }
            return CGRect(x: line.rect.x * width, y: line.rect.y * height, width: line.rect.width * width, height: line.rect.height * height)
        }
        let candidates = unexplainedStrokes(
            page: page, recognized: recognized, shapeRects: shapeRects, lineHeight: lineHeight)
        guard !candidates.isEmpty else { return [] }

        // Connected areas of the unexplained strokes, separately within each text row.
        var parent = Array(candidates.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let gap = clusterGap * lineHeight
        let boxes = candidates.map(\.box)
        let rows = InkRows.rows(of: boxes, lineHeight: lineHeight)
        for row in rows {
            for (position, i) in row.enumerated() {
                for j in row[(position + 1)...] {
                    if boxes[i].insetBy(dx: -gap / 2, dy: -gap / 2).intersects(boxes[j].insetBy(dx: -gap / 2, dy: -gap / 2)) {
                        parent[find(j)] = find(i)
                    }
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
