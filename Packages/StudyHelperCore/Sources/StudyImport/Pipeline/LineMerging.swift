import Foundation
import StudyCore

/// Combining the lines of several sources on one page (ink color layers, worksheet text, text boxes)
/// into one list in reading order.
enum LineMerging {
    /// A line together with the ink layer it was recognized in.
    struct LayerLine {
        var line: RecognizedLine
        var layer: Int
    }

    /// Merges fragments of one handwritten line that were recognized in different color layers
    /// (a line in black with one word in red comes out as two lines, one per layer).
    /// Lines of different layers are merged if they share a baseline band and touch or interleave horizontally;
    /// clearly separated columns stay separate lines. The words of a merged line are ordered by position.
    static func mergeLayerFragments(_ items: [LayerLine]) -> [RecognizedLine] {
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in items.indices {
            for j in items.indices where j > i && items[i].layer != items[j].layer {
                if sameBand(items[i].line.rect, items[j].line.rect) { parent[find(j)] = find(i) }
            }
        }
        var groups: [Int: [RecognizedLine]] = [:]
        var order: [Int] = []
        for i in items.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(items[i].line)
        }
        return order.map { root in
            let members = groups[root] ?? []
            return members.count == 1 ? members[0] : combine(members)
        }
    }

    /// Same baseline band (vertical overlap of at least half the smaller height) and horizontally touching,
    /// overlapping or at most one line height apart.
    static func sameBand(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap >= 0.5 * min(a.height, b.height) else { return false }
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return gap <= max(a.height, b.height)
    }

    // MARK: Fragments of one row

    /// Two lines are on one row if their vertical centers differ by less than this share of the smaller height.
    /// Dense handwriting has a row pitch of about half a line box, so the centers of stacked rows differ by
    /// about 0.5 of the height; fragments of one row by less than 0.2.
    static let rowCenterTolerance = 0.35
    /// A small piece whose box lies vertically inside the other one (a short, flat word next to a tall line) may
    /// be off center by this much, as long as at least `rowNestedShare` of its height is inside the other box.
    /// Stacked rows of dense handwriting overlap by only about half a box.
    static let rowNestedCenterTolerance = 0.45
    static let rowNestedShare = 0.9
    /// Largest horizontal gap between two fragments of one row, in heights of the taller line …
    static let rowFragmentGap = 1.0
    /// … and when an arrow joins them ("Prozesse → für Klima"); a shape-tool arrow is no ink and leaves a gap.
    static let rowFragmentArrowGap = 2.5
    /// Fragments may overlap horizontally by at most this share of the smaller height (imprecise boxes).
    static let rowFragmentOverlap = 0.5

    /// Merges handwritten lines that are pieces of one row, read separately (typically a word the first pass
    /// skipped, read again in a crop, next to the rest of its row, see docs/DECISIONS.md D-041). Pieces of one
    /// row are side by side without overlapping, close together and of the same color; separate columns,
    /// stacked rows of dense handwriting and list entries of different rows stay separate lines. The merged
    /// line keeps the worst status and all review reasons (a re-read piece keeps the row uncertain).
    /// - Parameters:
    ///   - lines: handwritten lines of one page (not embedded text, text boxes or image text).
    ///   - pageSize: page size in points (normalized widths and heights are not comparable without it).
    static func mergeRowFragments(_ lines: [RecognizedLine], pageSize: PageSize) -> [RecognizedLine] {
        var result = lines
        while true {
            // The closest pair first, so that a row is assembled from its neighbours outwards.
            var best: (i: Int, j: Int, gap: Double)?
            for i in result.indices {
                for j in result.indices where j > i {
                    guard let gap = rowFragmentGap(result[i], result[j], pageSize: pageSize) else { continue }
                    if gap < (best?.gap ?? .infinity) { best = (i, j, gap) }
                }
            }
            guard let best else { return result }
            result[best.i] = combine([result[best.i], result[best.j]])
            result.remove(at: best.j)
        }
    }

    /// The gap (in points) between two lines that are fragments of one row; nil if they are not.
    static func rowFragmentGap(_ a: RecognizedLine, _ b: RecognizedLine, pageSize: PageSize) -> Double? {
        func mergeable(_ line: RecognizedLine) -> Bool {
            !line.isUserCorrected && line.status != .illegible && !line.rect.isEmpty && line.blockKind == nil
                && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard mergeable(a), mergeable(b) else { return nil }
        if let ca = a.color, let cb = b.color, ca != cb { return nil }
        let minHeight = min(a.rect.height, b.rect.height)
        let centerOffset = abs(a.rect.midY - b.rect.midY)
        let verticalOverlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
        let nested = verticalOverlap >= rowNestedShare * minHeight && centerOffset < rowNestedCenterTolerance * minHeight
        guard centerOffset < rowCenterTolerance * minHeight || nested else { return nil }

        let (left, right) = a.rect.minX <= b.rect.minX ? (a, b) : (b, a)
        let gap = (right.rect.minX - left.rect.maxX) * pageSize.width
        let minHeightPoints = minHeight * pageSize.height
        let maxHeightPoints = max(a.rect.height, b.rect.height) * pageSize.height
        let minWidthPoints = min(a.rect.width, b.rect.width) * pageSize.width
        // No real overlap: the right piece starts (nearly) where the left one ends, and does not end inside it.
        guard gap >= -min(rowFragmentOverlap * minHeightPoints, 0.3 * minWidthPoints),
              right.rect.maxX > left.rect.maxX else { return nil }
        let joinedByArrow = endsWithArrow(left.text) || startsWithArrow(right.text)
        let limit = (joinedByArrow ? rowFragmentArrowGap : rowFragmentGap) * maxHeightPoints
        return gap <= limit ? max(0, gap) : nil
    }

    private static let arrowSigns: Set<Character> = ["→", "←", "↔", "⇒", "⇐", "⇔", "↗", "↘", "↙", "↖", "↑", "↓"]

    static func endsWithArrow(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let last = text.last else { return false }
        return arrowSigns.contains(last) || text.hasSuffix("->") || text.hasSuffix("=>")
    }

    static func startsWithArrow(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return false }
        return arrowSigns.contains(first) || text.hasPrefix("->") || text.hasPrefix("=>") || text.hasPrefix("-->")
    }

    static func combine(_ members: [RecognizedLine]) -> RecognizedLine {
        var words = members.flatMap(\.words)
        words.sort { $0.rect.minX < $1.rect.minX }
        // The text is built from the verbatim text pieces of the fragments (never from the words: words miss
        // punctuation-only tokens and words whose box could not be found). Each piece sticks to its word.
        var chunks: [(x: Double, text: String)] = []
        for member in members { chunks += textChunks(of: member) }
        chunks.sort { $0.x < $1.x }
        var reasons: [ReviewReason] = []
        for reason in members.flatMap(\.reviewReasons) where !reasons.contains(reason) { reasons.append(reason) }
        let status: ConfidenceStatus = members.contains { $0.status == .illegible } ? .illegible
            : (members.contains { $0.status == .uncertain } ? .uncertain : .confident)
        let colors = Set(members.compactMap(\.color))
        let kinds = Set(members.compactMap(\.blockKind))
        return RecognizedLine(
            text: chunks.map(\.text).joined(separator: " "),
            rect: members.reduce(NormalizedRect.zero) { $0.union($1.rect) },
            confidence: members.map(\.confidence).min() ?? 1, candidates: [], words: words,
            status: status, reviewReasons: reasons,
            color: colors.count == 1 && members.allSatisfy({ $0.color != nil }) ? colors.first : nil,
            blockKind: kinds.count == 1 ? kinds.first : nil, origin: combinedOrigin(of: members))
    }

    /// The origin of a merged line: the members' common origin, else recognized (a line that is partly read by the
    /// recognizer is not exact).
    static func combinedOrigin(of members: [RecognizedLine]) -> LineOrigin {
        let origins = Set(members.map(\.origin))
        if origins.count == 1, let only = origins.first, let origin = only { return origin }
        return .recognizer
    }

    /// Lines from a recognizer: their origin is `.recognizer` unless the recognizer already set one.
    static func taggedAsRecognized(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.map { line in
            guard line.origin == nil else { return line }
            var line = line
            line.origin = .recognizer
            return line
        }
    }

    /// The text of a line cut into pieces that each start at a word (with the tokens that follow it and have no
    /// word, e.g. "–" or "/"); tokens before the first word belong to the first piece. A line without usable
    /// words stays one piece positioned by its rect.
    static func textChunks(of line: RecognizedLine) -> [(x: Double, text: String)] {
        let tokens = LineTextAlignment.tokens(of: line.text, words: line.words)
        guard tokens.contains(where: { $0.wordIndex != nil }) else {
            return line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [(line.rect.minX, line.text)]
        }
        var chunks: [(x: Double, parts: [String])] = []
        var leading: [String] = []
        for token in tokens {
            if let index = token.wordIndex {
                chunks.append((line.words[index].rect.minX, leading + [token.text]))
                leading = []
            } else if chunks.isEmpty {
                leading.append(token.text)
            } else {
                chunks[chunks.count - 1].parts.append(token.text)
            }
        }
        return chunks.map { ($0.x, $0.parts.joined(separator: " ")) }
    }

    /// Numbers lines in reading order: top to bottom by baseline band, left to right within a band.
    static func assignReadingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let sorted = lines.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let first = rows.last?.first,
               abs(line.rect.midY - first.rect.midY) <= 0.5 * min(line.rect.height, first.rect.height) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var result: [RecognizedLine] = []
        for row in rows {
            for var line in row.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                line.order = result.count
                result.append(line)
            }
        }
        return result
    }

    /// Reading order of a page with embedded text plus handwriting and text boxes. The embedded lines keep the
    /// order the text extractor gave them (a two-column worksheet is not interleaved by position); every other
    /// line is placed after the embedded line above it (preferring one in the same horizontal band) and keeps
    /// the row-wise order among the other lines.
    static func assignReadingOrder(embedded: [RecognizedLine], others: [RecognizedLine]) -> [RecognizedLine] {
        let fixed = embedded.sorted { $0.order < $1.order }
        guard !fixed.isEmpty else { return assignReadingOrder(others) }
        let free = assignReadingOrder(others)

        var after: [Int: [RecognizedLine]] = [:]  // -1 = before the first embedded line
        for line in free {
            // Anchor: the embedded line directly above (or beside) the line; on the same height the one that
            // overlaps horizontally (same column) wins, then the later one.
            var anchor = -1
            var anchorOverlaps = false
            for (index, candidate) in fixed.enumerated() {
                let tolerance = 0.5 * min(line.rect.height, candidate.rect.height)
                guard candidate.rect.midY <= line.rect.midY + tolerance else { continue }
                let overlap = min(line.rect.maxX, candidate.rect.maxX) - max(line.rect.minX, candidate.rect.minX)
                let overlaps = overlap >= 0.3 * min(line.rect.width, candidate.rect.width)
                if anchor < 0 {
                    anchor = index; anchorOverlaps = overlaps; continue
                }
                let current = fixed[anchor]
                let dy = candidate.rect.midY - current.rect.midY
                let sameBand = abs(dy) <= 0.5 * min(candidate.rect.height, current.rect.height)
                let better = sameBand ? (overlaps || !anchorOverlaps) : dy > 0
                if better { anchor = index; anchorOverlaps = overlaps }
            }
            after[anchor, default: []].append(line)
        }
        var result: [RecognizedLine] = []
        func append(_ line: RecognizedLine) {
            var line = line
            line.order = result.count
            result.append(line)
        }
        after[-1]?.forEach(append)
        for (index, line) in fixed.enumerated() {
            append(line)
            after[index]?.forEach(append)
        }
        return result
    }

    /// Lines for the exact text of Goodnotes text boxes: one line per paragraph (`/Contents` split at line
    /// breaks), stacked over the box height, with the words spread over the line in proportion to their length.
    static func freeTextLines(_ boxes: [FreeTextBox]) -> [RecognizedLine] {
        var result: [RecognizedLine] = []
        for box in boxes {
            let rawLines = box.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Blank lines keep their place so that the other lines sit where they are in the box.
            var first = 0, last = rawLines.count - 1
            while first <= last, rawLines[first].isEmpty { first += 1 }
            while last >= first, rawLines[last].isEmpty { last -= 1 }
            guard first <= last else { continue }
            let lineHeight = box.rect.height / Double(last - first + 1)
            for (position, index) in (first...last).enumerated() where !rawLines[index].isEmpty {
                let text = rawLines[index]
                let rect = NormalizedRect(
                    x: box.rect.x, y: box.rect.y + Double(position) * lineHeight, width: box.rect.width, height: lineHeight)
                let tokens = WordTokenizer.tokens(in: text)
                let total = max(1, tokens.reduce(0) { $0 + $1.original.count + 1 })
                var x = rect.minX
                var words: [RecognizedWord] = []
                for token in tokens {
                    let width = rect.width * Double(token.original.count + 1) / Double(total)
                    words.append(RecognizedWord(
                        text: token.original, rect: NormalizedRect(x: x, y: rect.y, width: width, height: rect.height)))
                    x += width
                }
                result.append(RecognizedLine(text: text, rect: rect, confidence: 1, words: words, origin: .freeText))
            }
        }
        return result
    }

    /// Marks words that the second recognition pass did not read the same way. A word is stable if the other
    /// pass has a word with the same normalized text at (nearly) the same place.
    static func markVariation(first: [RecognizedLine], second: [RecognizedLine]) -> (lines: [RecognizedLine], variedWords: Int) {
        let others = second.flatMap(\.words).map { (WordTokenizer.normalize($0.text), $0.rect) }
        var varied = 0
        var result = first
        for l in result.indices {
            var lineVaried = false
            for w in result[l].words.indices {
                let word = result[l].words[w]
                let normalized = WordTokenizer.normalize(word.text)
                let stable = others.contains { other in
                    other.0 == normalized && word.rect.coverage(by: other.1) >= 0.4 && other.1.coverage(by: word.rect) >= 0.4
                }
                if !stable {
                    varied += 1
                    lineVaried = true
                    result[l].words[w].status = result[l].words[w].status.atLeast(.uncertain)
                    if !result[l].words[w].reviewReasons.contains(.variesBetweenPasses) {
                        result[l].words[w].reviewReasons.append(.variesBetweenPasses)
                    }
                }
            }
            if lineVaried {
                result[l].status = result[l].status.atLeast(.uncertain)
                if !result[l].reviewReasons.contains(.variesBetweenPasses) {
                    result[l].reviewReasons.append(.variesBetweenPasses)
                }
            }
        }
        return (result, varied)
    }
}

extension ConfidenceStatus {
    /// Order for "worst of": confident < uncertain < illegible.
    fileprivate var severity: Int {
        switch self {
        case .confident: return 0
        case .uncertain: return 1
        case .illegible: return 2
        }
    }

    fileprivate func atLeast(_ other: ConfidenceStatus) -> ConfidenceStatus {
        severity >= other.severity ? self : other
    }
}
