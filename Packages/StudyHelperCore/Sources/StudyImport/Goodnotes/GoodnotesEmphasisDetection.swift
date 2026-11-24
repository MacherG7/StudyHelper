import CoreGraphics
import Foundation
import StudyCore

/// Emphasis detection from Goodnotes annotations (see `GoodnotesEmphasisDetector`).
///
/// Everything is computed in page points with the origin at the TOP-left (y grows downwards), so that stroke
/// geometry and the normalized recognition rects can be compared directly.
///
/// Thresholds (all relative to text size, because Vision boxes and pen sizes vary per note):
/// - highlighter: a word belongs to a stroke if >= 50 % of the word box is covered by the stroke band
///   (butt caps, band width = stroke width), or >= 50 % of its width is covered in the middle band of the word.
/// - underline: chord >= 2 x line height (1.2 x if the stroke covers most of a short word and lies fully below
///   the line, then `.uncertain`), angle < 8 deg, max deviation from chord <= 8 % of chord, path length
///   <= 1.25 x chord, stroke centre between -0.25 and +0.6 line heights below the bottom of the line box.
///   Words are chosen by horizontal overlap >= 50 % of the word width.
/// - table grid: a long flat stroke touching >= 2 long, nearly vertical strokes is never an underline.
/// - circle: sweep around the centre >= 320 deg (or >= 250 deg with the end near the start), the box contains the
///   enclosed words (centre inside the stroke polygon, >= 85 % of their box inside the stroke box) and extends
///   beyond them, so a glyph contour is never a circle.
enum GoodnotesEmphasisDetection {
    static let highlighterWordCoverage = 0.5
    static let underlineMinLengthInLineHeights = 2.0
    static let underlineRelaxedMinLengthInLineHeights = 1.2
    static let maxUnderlineAngleDegrees = 8.0
    static let maxLineGapInLineHeights = 0.6
    static let maxLineOverlapInLineHeights = 0.25
    static let maxEnclosedWords = 8

    // MARK: Working types

    private struct Word {
        var ref: WordReference
        var text: String
        var rect: CGRect
        var color: RGBColor?
        var line: Int
        var order: Int
    }

    private struct LineBox {
        var rect: CGRect
        var words: [Int]  // indices into `words`
        var order: Int
    }

    private struct Shape {
        var stroke: InkStroke
        var points: [CGPoint]
        var bbox: CGRect  // points only
        var pathLength: Double
        var chord: Double
        var yMean: Double

        var width: Double { stroke.width }
        var visualRect: CGRect { bbox.insetBy(dx: -width / 2, dy: -width / 2) }
    }

    // MARK: Entry point

    static func detect(page: GoodnotesPage, lines: [RecognizedLine]) -> [RecognizedHighlight] {
        let pageW = page.size.width, pageH = page.size.height
        guard pageW > 0, pageH > 0, !lines.isEmpty else { return [] }

        func toPoints(_ r: NormalizedRect) -> CGRect {
            CGRect(x: r.x * pageW, y: r.y * pageH, width: r.width * pageW, height: r.height * pageH)
        }

        var words: [Word] = []
        var boxes: [LineBox] = []
        for (lineIndex, line) in lines.enumerated() {
            var indices: [Int] = []
            var union = CGRect.null
            for (i, w) in line.words.enumerated() where !w.rect.isEmpty {
                let rect = toPoints(w.rect)
                union = union.union(rect)
                indices.append(words.count)
                words.append(Word(
                    ref: WordReference(lineID: line.id, wordIndex: i), text: w.text, rect: rect, color: w.color,
                    line: boxes.count, order: line.order * 10_000 + i))
            }
            guard !union.isNull, !indices.isEmpty else { continue }
            boxes.append(LineBox(rect: union, words: indices, order: line.order * 10_000 + lineIndex))
        }
        guard !boxes.isEmpty else { return [] }
        let medianHeight = boxes.map { Double($0.rect.height) }.sorted()[boxes.count / 2]

        var result: [RecognizedHighlight] = []
        result += highlighterHighlights(page: page, words: words, pageH: pageH, pageW: pageW)

        let shapes = penShapes(page: page)
        result += underlineHighlights(shapes: shapes, words: words, boxes: boxes, medianHeight: medianHeight, page: page)
        result += circleHighlights(shapes: shapes, words: words, medianHeight: medianHeight, page: page)
        result += coloredPenHighlights(words: words, boxes: boxes, page: page)

        return result.sorted {
            ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX)
        }
    }

    // MARK: Highlighter

    private static func highlighterHighlights(
        page: GoodnotesPage, words: [Word], pageH: Double, pageW: Double
    ) -> [RecognizedHighlight] {
        let strokes = page.highlighterStrokes
        guard !strokes.isEmpty else { return [] }

        var wordSets: [Set<Int>] = []
        for stroke in strokes {
            let points = stroke.points.map { CGPoint(x: $0.x, y: pageH - $0.y) }
            var covered = Set<Int>()
            for (index, word) in words.enumerated() {
                if coverage(of: word.rect, by: points, width: stroke.width) {
                    covered.insert(index)
                }
            }
            wordSets.append(covered)
        }

        // Merge strokes that cover at least one common word.
        var parent = Array(0..<strokes.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for a in 0..<strokes.count {
            for b in (a + 1)..<strokes.count where !wordSets[a].isDisjoint(with: wordSets[b]) {
                parent[find(a)] = find(b)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<strokes.count { groups[find(i), default: []].append(i) }

        var result: [RecognizedHighlight] = []
        for group in groups.values.sorted(by: { ($0.first ?? 0) < ($1.first ?? 0) }) {
            var covered = Set<Int>()
            var rect = NormalizedRect.zero
            for i in group {
                covered.formUnion(wordSets[i])
                rect = rect.union(strokes[i].boundingBox(pageSize: page.size))
            }
            guard !covered.isEmpty else { continue }
            let ordered = covered.sorted { words[$0].order < words[$1].order }
            result.append(RecognizedHighlight(
                text: ordered.map { words[$0].text }.joined(separator: " "), kind: .highlighter,
                color: strokes[group[0]].color, rect: rect, confidence: 1, status: .confident,
                suggestedMeaning: .important, source: .goodnotesAnnotation,
                words: ordered.map { words[$0].ref }))
        }
        return result
    }

    /// Samples the word box on a grid and checks how much of it lies inside the stroke band.
    private static func coverage(of rect: CGRect, by points: [CGPoint], width: Double) -> Bool {
        guard rect.width > 0, rect.height > 0, !points.isEmpty else { return false }
        // Quick reject: band bounding box.
        var band = CGRect.null
        for p in points { band = band.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        band = band.insetBy(dx: -width / 2, dy: -width / 2)
        guard band.intersects(rect) else { return false }

        let columns = 20, rows = 8
        var covered = 0, middleCovered = 0, middleTotal = 0
        for r in 0..<rows {
            let y = Double(rect.minY) + (Double(r) + 0.5) / Double(rows) * Double(rect.height)
            let isMiddle = r >= 2 && r < 6
            for c in 0..<columns {
                let x = Double(rect.minX) + (Double(c) + 0.5) / Double(columns) * Double(rect.width)
                let hit = isInsideBand(CGPoint(x: x, y: y), points: points, halfWidth: width / 2)
                if hit { covered += 1 }
                if isMiddle {
                    middleTotal += 1
                    if hit { middleCovered += 1 }
                }
            }
        }
        let area = Double(covered) / Double(columns * rows)
        let middle = middleTotal > 0 ? Double(middleCovered) / Double(middleTotal) : 0
        return area >= highlighterWordCoverage || middle >= highlighterWordCoverage
    }

    /// Distance to the polyline <= halfWidth. Butt caps at both ends, round joins inside.
    private static func isInsideBand(_ p: CGPoint, points: [CGPoint], halfWidth: Double) -> Bool {
        if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= halfWidth }
        let lastSegment = points.count - 2
        for i in 0...lastSegment {
            let a = points[i], b = points[i + 1]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let len2 = dx * dx + dy * dy
            if len2 == 0 { continue }
            var t = (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / len2
            if t < 0 { if i == 0 { continue } else { t = 0 } }
            if t > 1 { if i == lastSegment { continue } else { t = 1 } }
            let cx = Double(a.x) + t * dx, cy = Double(a.y) + t * dy
            if hypot(Double(p.x) - cx, Double(p.y) - cy) <= halfWidth { return true }
        }
        return false
    }

    // MARK: Shapes

    private static func penShapes(page: GoodnotesPage) -> [Shape] {
        let h = page.size.height
        return page.penStrokes.compactMap { stroke in
            guard stroke.points.count >= 2 else { return nil }
            let pts = stroke.points.map { CGPoint(x: $0.x, y: h - $0.y) }
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            var length = 0.0, ySum = 0.0
            for (i, p) in pts.enumerated() {
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
                ySum += p.y
                if i > 0 { length += hypot(p.x - pts[i - 1].x, p.y - pts[i - 1].y) }
            }
            let chord = hypot(pts[0].x - pts[pts.count - 1].x, pts[0].y - pts[pts.count - 1].y)
            return Shape(
                stroke: stroke, points: pts, bbox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                pathLength: length, chord: chord, yMean: ySum / Double(pts.count))
        }
    }

    /// Straight stroke: little deviation from its chord and not folded back on itself.
    private static func isStraight(_ s: Shape) -> Bool {
        guard s.chord > 0 else { return false }
        guard s.pathLength <= 1.25 * s.chord else { return false }
        let a = s.points[0], b = s.points[s.points.count - 1]
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        var maxDeviation = 0.0
        for p in s.points {
            let d = abs(dy * Double(p.x - a.x) - dx * Double(p.y - a.y)) / s.chord
            maxDeviation = max(maxDeviation, d)
        }
        return maxDeviation <= max(1.5, 0.08 * s.chord)
    }

    /// Angle of the chord against the horizontal axis, 0…90 degrees.
    private static func horizontalAngle(_ s: Shape) -> Double {
        let a = s.points[0], b = s.points[s.points.count - 1]
        let angle = atan2(abs(Double(b.y - a.y)), abs(Double(b.x - a.x))) * 180 / .pi
        return angle
    }

    private static func segmentDistance(_ s: Shape, _ t: Shape) -> Double {
        let a = s.points[0], b = s.points[s.points.count - 1]
        let c = t.points[0], d = t.points[t.points.count - 1]
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> Double {
            Double((p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x))
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return 0 }
        func pointToSegment(_ p: CGPoint, _ u: CGPoint, _ v: CGPoint) -> Double {
            let dx = Double(v.x - u.x), dy = Double(v.y - u.y)
            let len2 = dx * dx + dy * dy
            if len2 == 0 { return hypot(Double(p.x - u.x), Double(p.y - u.y)) }
            let t = max(0, min(1, (Double(p.x - u.x) * dx + Double(p.y - u.y) * dy) / len2))
            return hypot(Double(p.x) - (Double(u.x) + t * dx), Double(p.y) - (Double(u.y) + t * dy))
        }
        return min(pointToSegment(a, c, d), pointToSegment(b, c, d), pointToSegment(c, a, b), pointToSegment(d, a, b))
    }

    // MARK: Underlines

    private struct UnderlineCandidate {
        var shapeIndex: Int
        var line: Int
        var words: [Int]
        var gap: Double
        var relaxed: Bool
        var ambiguous: Bool
    }

    private static func underlineHighlights(
        shapes: [Shape], words: [Word], boxes: [LineBox], medianHeight: Double, page: GoodnotesPage
    ) -> [RecognizedHighlight] {
        let minLong = underlineRelaxedMinLengthInLineHeights * medianHeight
        let flat = shapes.indices.filter {
            shapes[$0].chord >= minLong && horizontalAngle(shapes[$0]) < maxUnderlineAngleDegrees && isStraight(shapes[$0])
        }
        guard !flat.isEmpty else { return [] }

        // Long, nearly vertical, straight strokes: the other half of a hand-drawn table grid.
        let verticals = shapes.indices.filter {
            let s = shapes[$0]
            return s.chord >= 2 * medianHeight && (90 - horizontalAngle(s)) < 12 && isStraight(s)
        }

        var candidates: [UnderlineCandidate] = []
        for index in flat {
            let s = shapes[index]
            let touching = verticals.filter {
                segmentDistance(s, shapes[$0]) <= 0.5 * (s.width + shapes[$0].width) + 3
            }
            if touching.count >= 2 { continue }  // table grid line
            if let candidate = underlineCandidate(for: index, shape: s, words: words, boxes: boxes, medianHeight: medianHeight) {
                candidates.append(candidate)
            }
        }

        // Pair parallel strokes under the same words into double underlines.
        var used = Set<Int>()
        var result: [RecognizedHighlight] = []
        let ordered = candidates.indices.sorted {
            (candidates[$0].line, candidates[$0].gap) < (candidates[$1].line, candidates[$1].gap)
        }
        for (position, ci) in ordered.enumerated() where !used.contains(ci) {
            let a = candidates[ci]
            var partner: Int?
            for cj in ordered[(position + 1)...] where !used.contains(cj) {
                let b = candidates[cj]
                guard b.line == a.line else { continue }
                if isParallelPair(a, b, shapes: shapes, lineHeight: Double(boxes[a.line].rect.height)) {
                    partner = cj
                    break
                }
            }
            used.insert(ci)
            let strokeShapes: [Shape]
            var wordIndices = Set(a.words)
            var uncertain = a.relaxed || a.ambiguous
            let kind: HighlightKind
            if let partner {
                used.insert(partner)
                let b = candidates[partner]
                wordIndices.formUnion(b.words)
                uncertain = uncertain || b.relaxed || b.ambiguous
                strokeShapes = [shapes[a.shapeIndex], shapes[b.shapeIndex]]
                kind = .doubleUnderline
            } else {
                strokeShapes = [shapes[a.shapeIndex]]
                kind = .underline
            }
            let ordered = wordIndices.sorted { words[$0].order < words[$1].order }
            // No meaning is guessed: an underline marks a heading as often as a term to learn. The user (or, from
            // phase 3, the AI) decides; the highlight stays "offen" until then (D-026).
            let meaning: HighlightMeaning? = nil
            var rect = NormalizedRect.zero
            for s in strokeShapes { rect = rect.union(s.stroke.boundingBox(pageSize: page.size)) }
            result.append(RecognizedHighlight(
                text: ordered.map { words[$0].text }.joined(separator: " "), kind: kind, color: strokeShapes[0].stroke.color,
                rect: rect, confidence: uncertain ? 0.6 : 0.9, status: uncertain ? .uncertain : .confident,
                suggestedMeaning: meaning, source: .goodnotesShape, words: ordered.map { words[$0].ref }))
        }
        return result
    }

    private static func underlineCandidate(
        for index: Int, shape s: Shape, words: [Word], boxes: [LineBox], medianHeight: Double
    ) -> UnderlineCandidate? {
        let sx0 = Double(s.bbox.minX), sx1 = Double(s.bbox.maxX)
        var best: UnderlineCandidate?
        for (lineIndex, line) in boxes.enumerated() {
            let h = Double(line.rect.height)
            guard h > 0 else { continue }
            let gap = s.yMean - Double(line.rect.maxY)
            guard gap >= -maxLineOverlapInLineHeights * h, gap <= maxLineGapInLineHeights * h else { continue }

            var covered: [Int] = []
            for wi in line.words {
                let w = words[wi].rect
                let overlap = min(sx1, Double(w.maxX)) - max(sx0, Double(w.minX))
                if overlap >= 0.5 * Double(w.width) { covered.append(wi) }
            }
            guard !covered.isEmpty else { continue }

            var relaxed = false
            if s.chord < underlineMinLengthInLineHeights * h {
                // Short underline of a short word: accept only fully below the line and spanning the words.
                let span = covered.map { words[$0].rect }.reduce(CGRect.null) { $0.union($1) }
                guard s.chord >= underlineRelaxedMinLengthInLineHeights * h, gap >= 0,
                      s.chord >= 0.7 * Double(span.width) else { continue }
                relaxed = true
            }
            if best == nil || abs(gap) < abs(best!.gap) {
                best = UnderlineCandidate(shapeIndex: index, line: lineIndex, words: covered, gap: gap, relaxed: relaxed, ambiguous: false)
            }
        }
        guard var candidate = best else { return nil }

        // A flat stroke through the body of another line is a strike-through or part of a drawing.
        for (lineIndex, other) in boxes.enumerated() where lineIndex != candidate.line {
            let h = Double(other.rect.height)
            let overlap = min(sx1, Double(other.rect.maxX)) - max(sx0, Double(other.rect.minX))
            guard overlap >= 0.3 * (sx1 - sx0) else { continue }
            let top = Double(other.rect.minY), bottom = Double(other.rect.maxY)
            if s.yMean > top + 0.25 * h, s.yMean < bottom - 0.25 * h { return nil }
            // Close above the next line: could as well be an overline of that line.
            if s.yMean <= top, top - s.yMean < 0.3 * h, top > Double(boxes[candidate.line].rect.maxY) {
                candidate.ambiguous = true
            }
        }
        return candidate
    }

    private static func isParallelPair(
        _ a: UnderlineCandidate, _ b: UnderlineCandidate, shapes: [Shape], lineHeight: Double
    ) -> Bool {
        let s = shapes[a.shapeIndex], t = shapes[b.shapeIndex]
        guard s.stroke.color.distance(to: t.stroke.color) < 0.25 else { return false }
        guard abs(s.yMean - t.yMean) <= maxLineGapInLineHeights * lineHeight else { return false }
        let wordsA = Set(a.words), wordsB = Set(b.words)
        let common = wordsA.intersection(wordsB).count
        guard common > 0, Double(common) >= 0.6 * Double(wordsA.union(wordsB).count) else { return false }
        let overlap = min(Double(s.bbox.maxX), Double(t.bbox.maxX)) - max(Double(s.bbox.minX), Double(t.bbox.minX))
        let shorter = min(Double(s.bbox.width), Double(t.bbox.width))
        return shorter > 0 && overlap >= 0.6 * shorter
    }

    // MARK: Circles

    private static func circleHighlights(
        shapes: [Shape], words: [Word], medianHeight: Double, page: GoodnotesPage
    ) -> [RecognizedHighlight] {
        var result: [RecognizedHighlight] = []
        let minSide = 0.8 * medianHeight
        for s in shapes where s.points.count >= 8 {
            let box = s.bbox
            let maxDim = Double(max(box.width, box.height))
            guard Double(box.height) >= minSide, Double(box.width) >= minSide, maxDim > 0 else { continue }

            // Cheap reject: no word centre inside the box.
            let candidates = words.indices.filter { box.insetBy(dx: -1, dy: -1).contains(CGPoint(x: words[$0].rect.midX, y: words[$0].rect.midY)) }
            guard !candidates.isEmpty else { continue }

            let endGap = Double(hypot(s.points[0].x - s.points[s.points.count - 1].x, s.points[0].y - s.points[s.points.count - 1].y))
            let sweep = angularSweepDegrees(s.points, around: CGPoint(x: box.midX, y: box.midY))
            let nearClosed = endGap <= 0.35 * maxDim && sweep >= 250
            guard nearClosed || sweep >= 320 else { continue }

            let enclosed = candidates.filter { pointInPolygon(CGPoint(x: words[$0].rect.midX, y: words[$0].rect.midY), s.points) }
            guard !enclosed.isEmpty, enclosed.count <= maxEnclosedWords else { continue }

            // The mark must surround the words, not be a part of them (glyph contour).
            let union = enclosed.map { words[$0].rect }.reduce(CGRect.null) { $0.union($1) }
            let outer = box.insetBy(dx: -s.width / 2, dy: -s.width / 2)
            let inside = outer.intersection(union)
            guard !inside.isNull, Double(inside.width * inside.height) >= 0.85 * Double(union.width * union.height) else { continue }
            let margin = max(1.0, 0.06 * medianHeight)
            let extendsLeft = Double(box.minX) <= Double(union.minX) - margin
            let extendsRight = Double(box.maxX) >= Double(union.maxX) + margin
            let extendsTop = Double(box.minY) <= Double(union.minY) - margin
            let extendsBottom = Double(box.maxY) >= Double(union.maxY) + margin
            guard [extendsLeft, extendsRight, extendsTop, extendsBottom].filter({ $0 }).count >= 3 else { continue }

            let clean = endGap <= 0.25 * maxDim && sweep >= 320 && Set(enclosed.map { words[$0].line }).count == 1
            let ordered = enclosed.sorted { words[$0].order < words[$1].order }
            result.append(RecognizedHighlight(
                text: ordered.map { words[$0].text }.joined(separator: " "), kind: .circled, color: s.stroke.color,
                rect: s.stroke.boundingBox(pageSize: page.size), confidence: clean ? 0.9 : 0.6,
                status: clean ? .confident : .uncertain, suggestedMeaning: .term, source: .goodnotesShape,
                words: ordered.map { words[$0].ref }))
        }
        return result
    }

    /// Total absolute angle the stroke winds around `center`, in degrees.
    private static func angularSweepDegrees(_ points: [CGPoint], around center: CGPoint) -> Double {
        var total = 0.0
        var previous = atan2(Double(points[0].y - center.y), Double(points[0].x - center.x))
        for p in points.dropFirst() {
            let angle = atan2(Double(p.y - center.y), Double(p.x - center.x))
            var delta = angle - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            total += delta
            previous = angle
        }
        return abs(total) * 180 / .pi
    }

    private static func pointInPolygon(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: Colored pen

    private static func coloredPenHighlights(words: [Word], boxes: [LineBox], page: GoodnotesPage) -> [RecognizedHighlight] {
        var result: [RecognizedHighlight] = []
        for line in boxes {
            var run: [Int] = []
            var runColor: RGBColor?

            func flush() {
                guard let color = runColor, !run.isEmpty else { run = []; runColor = nil; return }
                let rect = run.map { words[$0].rect }.reduce(CGRect.null) { $0.union($1) }
                result.append(RecognizedHighlight(
                    text: run.map { words[$0].text }.joined(separator: " "), kind: .coloredPen, color: color,
                    rect: NormalizedRect(
                        x: Double(rect.minX) / page.size.width, y: Double(rect.minY) / page.size.height,
                        width: Double(rect.width) / page.size.width, height: Double(rect.height) / page.size.height),
                    confidence: 1, status: .confident, suggestedMeaning: nil, source: .goodnotesAnnotation,
                    words: run.map { words[$0].ref }))
                run = []
                runColor = nil
            }

            for wi in line.words {
                guard let color = words[wi].color, !color.isNearlyBlack else { flush(); continue }
                if let current = runColor, current.distance(to: color) >= InkLayerRendering.clusterThreshold { flush() }
                if runColor == nil { runColor = color }
                run.append(wi)
            }
            flush()
        }
        return result
    }
}
