import CoreGraphics
import Foundation
import StudyCore

/// Second chance for handwriting ("Nachlesen"). Vision on a whole dense page sometimes skips complete lines or
/// reads two rows as one. Ink that no recognized text explains, and recognized lines that look like such a
/// merge, are cut into text rows and horizontal segments; every segment is rendered alone, enlarged, and read
/// again. What is still unreadable afterwards is reported as illegible (`IllegibleInk`).
///
/// This file holds the planning (pure geometry on strokes, testable without a recognizer); the recognition
/// itself is `DigitizationPipeline.retryUnreadInk`.
enum HandwritingRetry {
    /// A recognized line taller than this many typical line heights may be several rows.
    static let suspiciousHeightFactor = 1.8
    /// Lines read from a segment need at least this confidence.
    static let minimumConfidence = 0.5
    /// Padding of a segment crop around its strokes, in line heights.
    static let verticalPadding = 0.5
    static let horizontalPadding = 1.0
    /// Segments of ink flatter than this (in line heights) are dashes, dots and stray tails, not writing.
    static let minimumSegmentHeight = 0.6
    /// Strokes of the layer whose center is this close (in line heights) to a row's projection belong to the row.
    static let rowTolerance = 0.2
    /// Scale factor of the second attempt on a segment.
    static let secondAttemptScale = 1.5
    /// Default for `PipelineSettings.retryCropLimit`.
    static let defaultCropLimit = 40
    /// Strokes of the segment's row this close (in line heights) to its ends join it, even if the imprecise box of
    /// a line in the row above or below claimed them ("Sch" of „Schädigungen“ under a tall first line).
    static let adjacentGap = 0.6

    /// Ink of one pen layer that is read again as one piece (one row, no wide gaps).
    struct Segment: Hashable {
        var layer: Int
        /// Stroke indices into `GoodnotesPage.strokes`.
        var strokes: [Int]
        /// Bounding box of the strokes in page points, origin top-left.
        var box: CGRect

        /// Vertical center of the ink row the segment was cut from, in page points (0: unknown).
        var rowMid: Double = 0
        /// The unexplained ink of the segment fits in one row (not a dense list split into rows later).
        var isSingleRow = true

        /// Reading priority: more strokes first.
        var weight: Int { strokes.count }
    }

    struct Plan {
        /// Per layer: lines that stay as they are.
        var remaining: [[RecognizedLine]]
        /// Per layer: suspicious lines taken out; they are replaced by the retry result or restored.
        var suspicious: [[RecognizedLine]]
        /// Suspicious lines whose only reason is an underline: they stay unchanged unless the retry reads them clearly
        /// differently (`keepsOriginal`).
        var underlinedOnly: Set<UUID> = []
        var segments: [Segment]
        /// Typical line height in points.
        var lineHeight: Double
    }

    // MARK: Planning

    /// - Parameters:
    ///   - page: the Goodnotes page.
    ///   - layerLines: the recognized lines of each pen layer (same order as `InkLayerRendering.clusters`).
    ///   - layerStrokes: the stroke indices of each layer.
    ///   - shapeRects: detected underlines, circles and the like; their strokes are not text.
    static func plan(
        page: GoodnotesPage, layerLines: [[RecognizedLine]], layerStrokes: [[Int]], shapeRects: [NormalizedRect],
        rereadsUnderlined: Bool = true
    ) -> Plan {
        let all = layerLines.flatMap { $0 }
        let lineHeight = IllegibleInk.lineHeight(page: page, recognized: all)
        let highlighters = page.highlighterFlags
        var plan = Plan(remaining: [], suspicious: [], segments: [], lineHeight: lineHeight)
        let underlines = rereadsUnderlined ? underlineStrokes(page: page, lineHeight: lineHeight) : []

        for (layer, lines) in layerLines.enumerated() {
            let strokes = layer < layerStrokes.count ? layerStrokes[layer] : []
            var remaining: [RecognizedLine] = []
            var suspicious: [RecognizedLine] = []
            for line in lines {
                let doubtful = isSuspicious(line, page: page, strokeIndices: strokes, highlighters: highlighters, lineHeight: lineHeight)
                if doubtful || isUnderlined(line, underlines: underlines, pageSize: page.size, lineHeight: lineHeight) {
                    suspicious.append(line)
                    if !doubtful { plan.underlinedOnly.insert(line.id) }
                } else {
                    remaining.append(line)
                }
            }
            plan.remaining.append(remaining)
            plan.suspicious.append(suspicious)

            let candidates = IllegibleInk.unexplainedStrokes(
                page: page, strokeIndices: strokes, recognized: remaining, shapeRects: shapeRects, lineHeight: lineHeight)
            guard !candidates.isEmpty else { continue }
            let all = IllegibleInk.textStrokes(page: page, strokeIndices: strokes, shapeRects: shapeRects, lineHeight: lineHeight)
            let boxes = candidates.map(\.box)
            let remainingRects = remaining.filter { !$0.rect.isEmpty }.map { line in
                CGRect(x: line.rect.x * page.size.width, y: line.rect.y * page.size.height,
                       width: line.rect.width * page.size.width, height: line.rect.height * page.size.height)
            }
            var layerSegments: [Segment] = []
            for row in InkRows.bands(of: boxes, lineHeight: lineHeight) {
                for segment in InkRows.segments(of: row.members, boxes: boxes, lineHeight: lineHeight) {
                    let box = InkRows.union(of: segment, boxes: boxes)
                    guard max(box.width, box.height) >= IllegibleInk.minimumSize * lineHeight,
                          box.height >= minimumSegmentHeight * lineHeight else { continue }
                    // The strokes of the row between the segment's ends belong to it even where a neighbouring
                    // line's (imprecise) word boxes had claimed them.
                    var members = Set(segment.map { candidates[$0].index })
                    let top = row.lo - rowTolerance * lineHeight, bottom = row.hi + rowTolerance * lineHeight
                    for stroke in all where !members.contains(stroke.index) {
                        let center = CGPoint(x: stroke.box.midX, y: stroke.box.midY)
                        if center.x >= box.minX, center.x <= box.maxX, center.y >= top, center.y <= bottom {
                            members.insert(stroke.index)
                        }
                    }
                    // Strokes right next to the segment in its row join it, unless a line of this row explains them.
                    let rowLines = remainingRects.filter { $0.midY >= top && $0.midY <= bottom }
                    var grown = box
                    // Only for segments of one row: tall segments (dense lists) are split into rows later and must keep
                    // exactly their own strokes.
                    let isSingleRow = box.height <= InkRows.tallBand * lineHeight
                    var changed = isSingleRow
                    while changed {
                        changed = false
                        for stroke in all where !members.contains(stroke.index) {
                            let center = CGPoint(x: stroke.box.midX, y: stroke.box.midY)
                            guard center.y >= top, center.y <= bottom,
                                  max(grown.minX - stroke.box.maxX, stroke.box.minX - grown.maxX) <= adjacentGap * lineHeight,
                                  !rowLines.contains(where: { $0.contains(center) }) else { continue }
                            members.insert(stroke.index)
                            grown = grown.union(stroke.box)
                            changed = true
                        }
                    }
                    let bounds = all.filter { members.contains($0.index) }.map(\.box)
                    let full = bounds.dropFirst().reduce(bounds.first ?? box) { $0.union($1) }
                    layerSegments.append(Segment(layer: layer, strokes: members.sorted(), box: full, rowMid: (row.lo + row.hi) / 2, isSingleRow: isSingleRow))
                }
            }
            plan.segments += exclusive(layerSegments, strokes: all)
        }
        return plan
    }

    /// Every stroke in one segment only: a stroke claimed by segments of two rows (a descender reaching into the
    /// row below) stays with the row whose center is closest to it. Boxes are recomputed from the strokes.
    /// Tall segments (several rows, split later) keep all their strokes and take no part.
    static func exclusive(_ segments: [Segment], strokes: [IllegibleInk.Candidate]) -> [Segment] {
        let boxes = Dictionary(strokes.map { ($0.index, $0.box) }, uniquingKeysWith: { first, _ in first })
        let single = segments.map(\.isSingleRow)
        var owner: [Int: Int] = [:]
        for (position, segment) in segments.enumerated() where single[position] {
            for index in segment.strokes {
                guard let box = boxes[index] else { continue }
                if let current = owner[index],
                   abs(segments[current].rowMid - box.midY) <= abs(segment.rowMid - box.midY) { continue }
                owner[index] = position
            }
        }
        return segments.enumerated().compactMap { position, segment in
            guard single[position] else { return segment }
            let kept = segment.strokes.filter { owner[$0] == position || boxes[$0] == nil }
            let bounds = kept.compactMap { boxes[$0] }
            guard let first = bounds.first else { return nil }
            var result = segment
            result.strokes = kept
            result.box = bounds.dropFirst().reduce(first) { $0.union($1) }
            return result
        }
    }

    /// A recognized line is suspicious if it is much taller than a normal line and either hardly trusted, read in
    /// a foreign script, or made of the ink of two or more text rows.
    static func isSuspicious(
        _ line: RecognizedLine, page: GoodnotesPage, strokeIndices: [Int], highlighters: [Bool], lineHeight: Double
    ) -> Bool {
        guard !line.isUserCorrected, !line.rect.isEmpty else { return false }
        let width = page.size.width, height = page.size.height
        guard line.rect.height * height > suspiciousHeightFactor * lineHeight else { return false }
        if line.confidence < minimumConfidence { return true }
        if !ScriptGuard.isPlausible(line.text) { return true }
        let rect = CGRect(
            x: line.rect.x * width, y: line.rect.y * height, width: line.rect.width * width, height: line.rect.height * height)
        var boxes: [CGRect] = []
        for index in strokeIndices where index < page.strokes.count && !highlighters[index] {
            let r = page.strokes[index].boundingBox(pageSize: page.size)
            let box = CGRect(x: r.x * width, y: r.y * height, width: r.width * width, height: r.height * height)
            if rect.contains(CGPoint(x: box.midX, y: box.midY)) { boxes.append(box) }
        }
        return InkRows.substantialRowCount(of: boxes, lineHeight: lineHeight) >= 2
    }

    /// Long, flat, straight pen strokes of the page (underlines drawn by hand), in page points.
    static func underlineStrokes(page: GoodnotesPage, lineHeight: Double) -> [CGRect] {
        let highlighters = page.highlighterFlags
        return page.strokes.indices.compactMap { index in
            let stroke = page.strokes[index]
            guard !highlighters[index],
                  IllegibleInk.isLongStraight(stroke, minimum: IllegibleInk.longStrokeLength * lineHeight, pageHeight: page.size.height)
            else { return nil }
            let r = stroke.boundingBox(pageSize: page.size)
            let box = CGRect(x: r.x * page.size.width, y: r.y * page.size.height, width: r.width * page.size.width, height: r.height * page.size.height)
            return box.height < 0.3 * lineHeight ? box : nil
        }
    }

    /// A line with a hand-drawn underline in its lower half or just below: on the whole page the recognizer often
    /// reads such words wrongly ("ikhdrom" for an underlined „Syndrom“). The line is read again row by row; the
    /// underline itself is no text stroke (`IllegibleInk.textStrokes`) and is left out of the crop.
    static func isUnderlined(_ line: RecognizedLine, underlines: [CGRect], pageSize: PageSize, lineHeight: Double) -> Bool {
        guard !line.isUserCorrected, !line.rect.isEmpty, !underlines.isEmpty else { return false }
        let rect = CGRect(
            x: line.rect.x * pageSize.width, y: line.rect.y * pageSize.height,
            width: line.rect.width * pageSize.width, height: line.rect.height * pageSize.height)
        return underlines.contains { stroke in
            let overlapX = min(stroke.maxX, rect.maxX) - max(stroke.minX, rect.minX)
            return overlapX >= 0.5 * stroke.width && stroke.midY >= rect.midY && stroke.midY <= rect.maxY + 0.3 * lineHeight
        }
    }

    /// Crop region of a segment in normalized page coordinates: the strokes plus padding, clamped to the page.
    static func cropRegion(of box: CGRect, lineHeight: Double, pageSize: PageSize) -> NormalizedRect {
        let padY = verticalPadding * lineHeight, padX = horizontalPadding * lineHeight
        let x0 = max(0, box.minX - padX), x1 = min(pageSize.width, box.maxX + padX)
        let y0 = max(0, box.minY - padY), y1 = min(pageSize.height, box.maxY + padY)
        return NormalizedRect(
            x: x0 / pageSize.width, y: y0 / pageSize.height,
            width: max(0, x1 - x0) / pageSize.width, height: max(0, y1 - y0) / pageSize.height)
    }

    // MARK: Merging the result

    /// Rect (and word rects) of a line read in a crop, mapped from crop to page coordinates.
    static func mapToPage(_ line: RecognizedLine, cropRect: NormalizedRect) -> RecognizedLine {
        func map(_ r: NormalizedRect) -> NormalizedRect {
            NormalizedRect(
                x: cropRect.x + r.x * cropRect.width, y: cropRect.y + r.y * cropRect.height,
                width: r.width * cropRect.width, height: r.height * cropRect.height)
        }
        var result = line
        result.rect = map(line.rect)
        for index in result.words.indices { result.words[index].rect = map(result.words[index].rect) }
        return result
    }

    /// Lines read from segments that are not near-duplicates of a line that stays.
    static func newLines(_ candidates: [RecognizedLine], besides existing: [RecognizedLine]) -> [RecognizedLine] {
        candidates.filter { candidate in
            !existing.contains { other in
                candidate.rect.iou(other.rect) > 0.4 || other.rect.coverage(by: candidate.rect) > 0.8
            }
        }
    }

    /// Edit distance of two readings over their letters and digits only (case, spacing and punctuation ignored).
    static func letterDistance(_ a: String, _ b: String) -> Int {
        func letters(_ text: String) -> [Character] { Array(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let x = letters(a), y = letters(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }

    /// Whether an underlined-only line stays: the lines read inside its box spell the same letters (one
    /// difference allowed), or nothing was read there.
    static func keepsOriginal(_ line: RecognizedLine, readings: [RecognizedLine]) -> Bool {
        let inside = readings.filter { line.rect.insetBy(dx: -0.005, dy: -0.005).contains(x: $0.rect.midX, y: $0.rect.midY) }
        guard !inside.isEmpty else { return true }
        let text = inside.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
        return letterDistance(text, line.text) <= 1
    }

    /// A suspicious line whose retry gave nothing stays, but is marked as uncertain.
    static func restored(_ line: RecognizedLine) -> RecognizedLine {
        var line = line
        line.status = line.status.atLeastUncertain
        if !line.reviewReasons.contains(.lowConfidence) { line.reviewReasons.append(.lowConfidence) }
        return line
    }

    /// A line read in a crop is shown as uncertain with reason `.reReadSeparately` (see docs/DECISIONS.md D-020);
    /// its words keep their own status, so only doubtful words are marked inside the line.
    static func markedAsReRead(_ line: RecognizedLine) -> RecognizedLine {
        var line = line
        line.status = line.status.atLeastUncertain
        if !line.reviewReasons.contains(.reReadSeparately) { line.reviewReasons.append(.reReadSeparately) }
        return line
    }

    /// Whether the retry of `segment` replaces `line` (the segment sits inside the line's box).
    static func segment(_ segment: Segment, belongsTo line: RecognizedLine, pageSize: PageSize) -> Bool {
        let rect = CGRect(
            x: line.rect.x * pageSize.width, y: line.rect.y * pageSize.height,
            width: line.rect.width * pageSize.width, height: line.rect.height * pageSize.height)
        return rect.contains(CGPoint(x: segment.box.midX, y: segment.box.midY))
    }
}

extension DigitizationPipeline {
    /// Reads unexplained ink and suspicious lines of a Goodnotes page again, segment by segment.
    /// - Parameters:
    ///   - layerLines: first-pass lines per pen layer (with the layer color), order as `InkLayerRendering.clusters`.
    ///   - shapeRects: detected underlines, circles and the like.
    /// - Returns: the lines per layer after the retry (kept lines, restored suspicious lines, newly read lines).
    func retryUnreadInk(
        page: GoodnotesPage, layerLines: [[RecognizedLine]], shapeRects: [NormalizedRect]
    ) async throws -> [[RecognizedLine]] {
        let limit = settings.retryCropLimit
        let clusters = InkLayerRendering.clusters(of: page)
        guard limit > 0, clusters.count == layerLines.count else { return layerLines }

        let plan = HandwritingRetry.plan(
            page: page, layerLines: layerLines, layerStrokes: clusters.map(\.strokeIndices), shapeRects: shapeRects,
            rereadsUnderlined: settings.rereadsUnderlinedLines)
        let hasSuspicious = plan.suspicious.contains { !$0.isEmpty }
        guard !plan.segments.isEmpty || hasSuspicious else { return layerLines }

        // Biggest pieces first; the number of recognizer calls per page is capped.
        let chosen = plan.segments.enumerated()
            .sorted { a, b in
                a.element.weight != b.element.weight ? a.element.weight > b.element.weight : a.offset < b.offset
            }
            .prefix(limit).map(\.element)
        var read: [[RecognizedLine]] = Array(repeating: [], count: chosen.count)
        var budget = limit

        let first = try await concurrentMap(chosen, maxConcurrent: 2) { segment in
            try await self.readSegment(segment, in: page, lineHeight: plan.lineHeight, color: clusters[segment.layer].representative, scale: self.settings.recognitionScale)
        }
        budget -= chosen.count
        for (index, lines) in first.enumerated() { read[index] = lines }

        // Second attempt, enlarged: segments that gave nothing, and segments read as one line over two rows
        // (dense rows like a numbered list); the attempt with more lines wins.
        let tallLimit = HandwritingRetry.suspiciousHeightFactor * plan.lineHeight / page.size.height
        let unreadIndices = read.indices.filter { index in
            read[index].isEmpty || read[index].contains { $0.rect.height > tallLimit }
        }.prefix(max(0, budget))
        if !unreadIndices.isEmpty {
            let second = try await concurrentMap(Array(unreadIndices), maxConcurrent: 2) { index in
                let segment = chosen[index]
                return try await self.readSegment(
                    segment, in: page, lineHeight: plan.lineHeight, color: clusters[segment.layer].representative,
                    scale: self.settings.recognitionScale * HandwritingRetry.secondAttemptScale)
            }
            for (position, index) in unreadIndices.enumerated() where second[position].count > read[index].count {
                read[index] = second[position]
            }
            budget -= unreadIndices.count
        }

        // Last resort for tall segments that are still unread: split at the thinnest places, read each row alone.
        let boxes = page.strokes.map { stroke -> CGRect in
            let r = stroke.boundingBox(pageSize: page.size)
            return CGRect(x: r.x * page.size.width, y: r.y * page.size.height, width: r.width * page.size.width, height: r.height * page.size.height)
        }
        for index in read.indices where read[index].isEmpty && budget > 0 {
            let segment = chosen[index]
            guard segment.box.height > InkRows.tallBand * plan.lineHeight else { continue }
            let rows = InkRows.forcedRows(of: segment.strokes, boxes: boxes, lineHeight: plan.lineHeight)
            guard rows.count > 1 else { continue }
            for row in rows.prefix(budget) {
                let part = HandwritingRetry.Segment(
                    layer: segment.layer, strokes: row.sorted(), box: InkRows.union(of: row, boxes: boxes))
                read[index] += try await readSegment(
                    part, in: page, lineHeight: plan.lineHeight, color: clusters[segment.layer].representative,
                    scale: settings.recognitionScale * HandwritingRetry.secondAttemptScale)
                budget -= 1
            }
        }

        var result: [[RecognizedLine]] = []
        for layer in layerLines.indices {
            var lines = plan.remaining[layer]
            var added: [RecognizedLine] = []
            var yielded = Set<Int>()  // chosen segments of this layer that produced lines
            for (index, segment) in chosen.enumerated() where segment.layer == layer {
                let fresh = HandwritingRetry.newLines(read[index], besides: plan.remaining[layer])
                if !fresh.isEmpty { yielded.insert(index) }
                added += fresh
            }
            for line in plan.suspicious[layer] {
                if plan.underlinedOnly.contains(line.id), HandwritingRetry.keepsOriginal(line, readings: added) {
                    // Read again only for its underline and nothing new came out: the first reading stays as it was.
                    added.removeAll { line.rect.insetBy(dx: -0.005, dy: -0.005).contains(x: $0.rect.midX, y: $0.rect.midY) }
                    lines.append(line)
                    continue
                }
                let replaced = yielded.contains { HandwritingRetry.segment(chosen[$0], belongsTo: line, pageSize: page.size) }
                if !replaced { lines.append(HandwritingRetry.restored(line)) }
            }
            result.append(lines + added)
        }
        return result
    }

    /// Renders the segment alone with padding, recognizes it and maps the usable lines back to page coordinates.
    private func readSegment(
        _ segment: HandwritingRetry.Segment, in page: GoodnotesPage, lineHeight: Double, color: RGBColor, scale: Double
    ) async throws -> [RecognizedLine] {
        try Task.checkCancellation()
        let region = HandwritingRetry.cropRegion(of: segment.box, lineHeight: lineHeight, pageSize: page.size)
        guard let crop = InkLayerRendering.renderStrokes(page: page, indices: segment.strokes, crop: region, scale: scale) else {
            return []
        }
        let options = settings.recognitionOptions(prefersDocumentRecognition: false)
        let output = try await recognizer.recognize(crop.image, options: options)
        return KnownMisreadings.apply(to: ScriptGuard.apply(to: output.lines))
            .filter { line in
                !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && line.confidence >= HandwritingRetry.minimumConfidence
                    && ScriptGuard.isPlausible(line.text)
                    && !line.rect.isEmpty
            }
            .map { HandwritingRetry.markedAsReRead(Self.colored(HandwritingRetry.mapToPage($0, cropRect: crop.rect), with: color)) }
    }
}
