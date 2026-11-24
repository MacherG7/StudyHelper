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

    /// Ink of one pen layer that is read again as one piece (one row, no wide gaps).
    struct Segment: Hashable {
        var layer: Int
        /// Stroke indices into `GoodnotesPage.strokes`.
        var strokes: [Int]
        /// Bounding box of the strokes in page points, origin top-left.
        var box: CGRect

        /// Reading priority: more strokes first.
        var weight: Int { strokes.count }
    }

    struct Plan {
        /// Per layer: lines that stay as they are.
        var remaining: [[RecognizedLine]]
        /// Per layer: suspicious lines taken out; they are replaced by the retry result or restored.
        var suspicious: [[RecognizedLine]]
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
        page: GoodnotesPage, layerLines: [[RecognizedLine]], layerStrokes: [[Int]], shapeRects: [NormalizedRect]
    ) -> Plan {
        let all = layerLines.flatMap { $0 }
        let lineHeight = IllegibleInk.lineHeight(page: page, recognized: all)
        let highlighters = page.highlighterFlags
        var plan = Plan(remaining: [], suspicious: [], segments: [], lineHeight: lineHeight)

        for (layer, lines) in layerLines.enumerated() {
            let strokes = layer < layerStrokes.count ? layerStrokes[layer] : []
            var remaining: [RecognizedLine] = []
            var suspicious: [RecognizedLine] = []
            for line in lines {
                if isSuspicious(line, page: page, strokeIndices: strokes, highlighters: highlighters, lineHeight: lineHeight) {
                    suspicious.append(line)
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
                    let indices = members.sorted()
                    let bounds = all.filter { members.contains($0.index) }.map(\.box)
                    let full = bounds.dropFirst().reduce(bounds.first ?? box) { $0.union($1) }
                    plan.segments.append(Segment(layer: layer, strokes: indices, box: full))
                }
            }
        }
        return plan
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

    /// A suspicious line whose retry gave nothing stays, but is marked as uncertain.
    static func restored(_ line: RecognizedLine) -> RecognizedLine {
        var line = line
        line.status = line.status.atLeastUncertain
        if !line.reviewReasons.contains(.lowConfidence) { line.reviewReasons.append(.lowConfidence) }
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
            page: page, layerLines: layerLines, layerStrokes: clusters.map(\.strokeIndices), shapeRects: shapeRects)
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

        let unreadIndices = read.indices.filter { read[$0].isEmpty }.prefix(max(0, budget))
        if !unreadIndices.isEmpty {
            let second = try await concurrentMap(Array(unreadIndices), maxConcurrent: 2) { index in
                let segment = chosen[index]
                return try await self.readSegment(
                    segment, in: page, lineHeight: plan.lineHeight, color: clusters[segment.layer].representative,
                    scale: self.settings.recognitionScale * HandwritingRetry.secondAttemptScale)
            }
            for (position, index) in unreadIndices.enumerated() { read[index] = second[position] }
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
        return ScriptGuard.apply(to: output.lines)
            .filter { line in
                !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && line.confidence >= HandwritingRetry.minimumConfidence
                    && ScriptGuard.isPlausible(line.text)
                    && !line.rect.isEmpty
            }
            .map { Self.colored(HandwritingRetry.mapToPage($0, cropRect: crop.rect), with: color) }
    }
}
