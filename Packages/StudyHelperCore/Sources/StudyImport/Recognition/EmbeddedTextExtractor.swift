import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Text and emphasis taken from the text layer of one PDF page.
public struct EmbeddedTextPage: Hashable, Sendable {
    public var lines: [RecognizedLine]
    /// Bold, colored, underlined and double underlined text from the PDF formatting (`source == .embeddedPDF`).
    public var highlights: [RecognizedHighlight]
    /// Media box in points (rotation applied).
    public var pageSize: PageSize
    /// Share of the page area (0…1) covered by raster images. Text inside images is not part of the text layer.
    public var imageCoverage: Double = 0
}

/// Reads *visible* embedded text of a PDF page (digital worksheets, web exports) including its formatting,
/// instead of recognizing it (SPEC §1 and §2: "Bei eingebettetem PDF-Text werden Fett, Farbe und
/// Unterstreichung direkt aus der PDF-Formatierung übernommen").
///
/// - Text drawn with render mode 3 (invisible; an OCR layer such as the one in reduced Goodnotes PDFs) is ignored.
/// - Lines, words and word rectangles come from PDFKit; the content stream (`PDFContentScanner`) adds what PDFKit
///   does not tell: render mode, font weight, fill color and thin horizontal paths below text (underlines).
/// - Everything is `.confident` with source `.embeddedPDF`.
public enum EmbeddedTextExtractor {
    /// True if the page draws at least one visible, non-blank text run.
    public static func hasVisibleText(in page: PDFPage) -> Bool {
        guard let cgPage = page.pageRef else { return false }
        return PDFContentScanner.scan(page: cgPage).runs.contains { $0.isVisible && $0.visibleByteCount > 0 }
    }

    /// Extracts the visible text of `page`, or nil if the page has none.
    public static func extract(from page: PDFPage) -> EmbeddedTextPage? {
        guard let cgPage = page.pageRef else { return nil }
        let scan = PDFContentScanner.scan(page: cgPage)
        guard scan.runs.contains(where: { $0.isVisible && $0.visibleByteCount > 0 }) else { return nil }

        let box = page.bounds(for: .mediaBox)
        var words = pageWords(page).map { word in
            ExtractedWord(text: word.text, rect: word.rect)
        }
        assignFormatting(&words, runs: scan.runs)
        words.removeAll { !$0.visible }
        words = deduplicated(words)
        guard !words.isEmpty else { return nil }

        let rows = groupIntoLines(words)
        var result = build(rows: rows, segments: scan.segments, box: box, rotation: page.rotation, size: PageRenderer.pageSize(of: page))
        result.imageCoverage = imageCoverage(scan.images, in: box)
        return result
    }

    /// Fraction of the media box covered by `images` (rough: sum of the clipped areas, at most 1).
    static func imageCoverage(_ images: [CGRect], in box: CGRect) -> Double {
        guard box.width > 0, box.height > 0 else { return 0 }
        let area = images.reduce(0.0) { $0 + Double(box.intersection($1).isNull ? 0 : box.intersection($1).width * box.intersection($1).height) }
        return min(1, area / Double(box.width * box.height))
    }

    // MARK: Words from PDFKit

    struct PageWord {
        var text: String
        /// PDFKit page space (points, origin bottom-left).
        var rect: CGRect
    }

    /// Splits the page string at whitespace; every word's rectangle is the bounds of the PDFKit selection for its
    /// character range. (`characterBounds(at:)` is not used: its index space drifts from the string's after line
    /// breaks.)
    static func pageWords(_ page: PDFPage) -> [PageWord] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        var result: [PageWord] = []
        var start: Int?
        func flush(upTo end: Int) {
            guard let s = start else { return }
            start = nil
            let range = NSRange(location: s, length: end - s)
            guard let rect = page.selection(for: range)?.bounds(for: page), rect.width > 0, rect.height > 0 else { return }
            result.append(PageWord(text: text.substring(with: range), rect: rect))
        }
        for index in 0..<text.length {
            let unit = text.character(at: index)
            let isSpace = unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0 || unit == 0x2028
                || unit == 0x2029 || unit == 0xFFFC
            if isSpace { flush(upTo: index) } else if start == nil { start = index }
        }
        flush(upTo: text.length)
        return result
    }

    // MARK: Formatting from the content stream

    struct ExtractedWord {
        var text: String
        var rect: CGRect
        var size: Double
        var baseline: Double
        var isBold = false
        var color = StudyColor.black
        var visible = true

        init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
            size = Double(rect.height)
            baseline = Double(rect.minY) + 0.22 * Double(rect.height)
        }
    }

    /// Gives every word the formatting of the text run it belongs to: the last run that starts on the word's
    /// baseline at or before the word. Words whose run is invisible are marked invisible.
    static func assignFormatting(_ words: inout [ExtractedWord], runs: [ScannedTextRun]) {
        // Bucket runs by baseline (1 pt rows).
        var rows: [Int: [Int]] = [:]
        for (index, run) in runs.enumerated() { rows[Int(run.origin.y.rounded(.down)), default: []].append(index) }

        for w in words.indices {
            let rect = words[w].rect
            let height = Double(rect.height)
            let lowRow = Int((Double(rect.minY) - 0.15 * height).rounded(.down))
            let highRow = Int((Double(rect.minY) + 0.65 * height).rounded(.up))
            var best: Int?
            for row in lowRow...max(lowRow, highRow) {
                for index in rows[row] ?? [] {
                    let run = runs[index]
                    guard Double(run.origin.x) <= Double(rect.minX) + 0.35 * height else { continue }
                    if let current = best {
                        let other = runs[current]
                        let delta = Double(run.origin.x) - Double(other.origin.x)
                        if delta > 1 || (abs(delta) <= 1 && run.isVisible && !other.isVisible) { best = index }
                    } else {
                        best = index
                    }
                }
            }
            guard let best else { continue }
            let run = runs[best]
            words[w].isBold = run.isBold
            words[w].color = run.color
            words[w].visible = run.isVisible
            words[w].baseline = Double(run.origin.y)
            if run.size > 0 { words[w].size = run.size }
        }
    }

    /// An invisible text layer can repeat visible words at the same place; keep one of each.
    static func deduplicated(_ words: [ExtractedWord]) -> [ExtractedWord] {
        var result: [ExtractedWord] = []
        for word in words {
            let duplicate = result.contains { other in
                other.text == word.text && other.rect.intersection(word.rect).width > 0.5 * min(other.rect.width, word.rect.width)
                    && abs(other.rect.midY - word.rect.midY) < 0.3 * Double(word.rect.height)
            }
            if !duplicate { result.append(word) }
        }
        return result
    }

    // MARK: Lines

    /// Groups words into lines: same baseline, left to right, split where the horizontal gap is far larger than
    /// a word space (table columns, side-by-side boxes). Lines run top to bottom.
    static func groupIntoLines(_ words: [ExtractedWord]) -> [[ExtractedWord]] {
        let sorted = words.sorted { $0.baseline > $1.baseline }
        var clusters: [[ExtractedWord]] = []
        for word in sorted {
            if var last = clusters.last, let reference = last.first,
               abs(reference.baseline - word.baseline) <= 0.45 * max(word.size, reference.size) {
                last.append(word)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([word])
            }
        }
        var lines: [[ExtractedWord]] = []
        for cluster in clusters {
            let row = cluster.sorted { $0.rect.minX < $1.rect.minX }
            var current: [ExtractedWord] = []
            for word in row {
                if let previous = current.last {
                    let gap = Double(word.rect.minX - previous.rect.maxX)
                    if gap > 1.8 * max(word.size, previous.size) {
                        lines.append(current)
                        current = []
                    }
                }
                current.append(word)
            }
            if !current.isEmpty { lines.append(current) }
        }
        // Rows were top to bottom; split columns of one row stay left to right. Re-sort stably by baseline band.
        return lines
    }

    // MARK: Result

    private static let bulletMarkers: Set<String> = ["\u{2022}", "\u{25AA}", "\u{25E6}", "\u{2023}", "\u{2043}", "-", "\u{2013}", "*", "\u{25CF}"]

    private static func build(
        rows: [[ExtractedWord]], segments: [ScannedSegment], box: CGRect, rotation: Int, size pageSize: PageSize
    ) -> EmbeddedTextPage {
        func normalized(_ r: CGRect) -> NormalizedRect {
            .fromBottomLeft(
                x: Double(r.minX - box.minX), y: Double(r.minY - box.minY),
                width: Double(r.width), height: Double(r.height),
                spaceWidth: Double(box.width), spaceHeight: Double(box.height)
            ).rotatedClockwise(rotation)
        }

        let sizes = rows.flatMap { $0.map(\.size) }.sorted()
        let bodySize = sizes.isEmpty ? 12 : sizes[sizes.count / 2]
        let allWords = rows.flatMap { $0 }
        let boldFraction = Double(allWords.filter(\.isBold).count) / Double(max(1, allWords.count))
        let skipBold = allWords.count >= 5 && boldFraction > 0.9
        let colored = allWords.filter { Self.isColored($0.color) }
        let coloredFraction = Double(colored.count) / Double(max(1, allWords.count))
        let skipColor = allWords.count >= 5 && coloredFraction > 0.9

        var lines: [RecognizedLine] = []
        var highlights: [RecognizedHighlight] = []
        /// Per line: the extracted words kept (marker words removed) for highlight construction.
        var keptRows: [[ExtractedWord]] = []

        for (rowIndex, row) in rows.enumerated() {
            var kept = row
            var blockKind: LineBlockKind?
            if kept.count >= 2, bulletMarkers.contains(kept[0].text) {
                blockKind = .listItem
                kept.removeFirst()
            }
            let recognizedWords = kept.map { word in
                RecognizedWord(text: word.text, rect: normalized(word.rect), confidence: 1, color: word.color)
            }
            let text = kept.map(\.text).joined(separator: " ")
            let rect = kept.reduce(NormalizedRect.zero) { $0.union(normalized($1.rect)) }
            let colorsEqual = kept.dropFirst().allSatisfy { $0.color.distance(to: kept[0].color) < 0.05 }
            let isWholeBold = kept.allSatisfy(\.isBold)
            let lineSize = kept.map(\.size).max() ?? bodySize
            if blockKind == nil, rowIndex == 0, isWholeBold, lineSize >= 1.4 * bodySize { blockKind = .title }
            lines.append(RecognizedLine(
                text: text, rect: rect, confidence: 1, words: recognizedWords, status: .confident,
                color: colorsEqual ? kept.first?.color : nil, blockKind: blockKind, order: rowIndex))
            keptRows.append(kept)
        }

        func reference(_ line: RecognizedLine, _ indices: [Int]) -> [WordReference] {
            indices.map { WordReference(lineID: line.id, wordIndex: $0) }
        }

        func meaning(wholeLine: Bool, wordCount: Int, lineSize: Double) -> HighlightMeaning? {
            if wholeLine, lineSize >= 1.15 * bodySize { return .heading }
            if !wholeLine, wordCount <= 4 { return .term }
            return nil
        }

        for (rowIndex, kept) in keptRows.enumerated() {
            let line = lines[rowIndex]
            // Runs of consecutive words with the same attribute.
            func runs(where predicate: (ExtractedWord) -> Bool, sameKey: (ExtractedWord, ExtractedWord) -> Bool = { _, _ in true }) -> [[Int]] {
                var result: [[Int]] = []
                var current: [Int] = []
                for (i, word) in kept.enumerated() {
                    if predicate(word), current.isEmpty || sameKey(kept[current[current.count - 1]], word) {
                        current.append(i)
                    } else {
                        if !current.isEmpty { result.append(current) }
                        current = predicate(word) ? [i] : []
                    }
                }
                if !current.isEmpty { result.append(current) }
                return result
            }

            func highlight(_ kind: HighlightKind, indices: [Int], color: StudyColor?, rect: NormalizedRect? = nil) {
                let words = indices.map { kept[$0] }
                let lineSize = words.map(\.size).max() ?? bodySize
                highlights.append(RecognizedHighlight(
                    text: words.map(\.text).joined(separator: " "), kind: kind, color: color,
                    rect: rect ?? words.reduce(NormalizedRect.zero) { $0.union(normalized($1.rect)) },
                    confidence: 1, status: .confident,
                    suggestedMeaning: meaning(wholeLine: indices.count == kept.count, wordCount: indices.count, lineSize: lineSize),
                    source: .embeddedPDF, words: reference(line, indices)))
            }

            if !skipBold {
                for indices in runs(where: \.isBold) { highlight(.bold, indices: indices, color: nil) }
            }
            if !skipColor {
                for indices in runs(
                    where: { Self.isColored($0.color) },
                    sameKey: { $0.color.distance(to: $1.color) < 0.12 }
                ) {
                    highlight(.coloredPen, indices: indices, color: kept[indices[0]].color)
                }
            }
        }

        highlights += underlineHighlights(
            segments: segments, rows: keptRows, lines: lines, normalized: normalized, bodySize: bodySize)
        return EmbeddedTextPage(lines: lines, highlights: highlights, pageSize: pageSize)
    }

    static func isColored(_ color: StudyColor) -> Bool {
        if color.isNearlyBlack { return false }
        // Near-white text is invisible on white paper, and gray is not a pen color.
        let spread = max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        return spread > 0.15
    }

    // MARK: Underlines

    /// A thin horizontal path directly below a run of words, not much wider than that run, is an underline.
    /// Two such paths under the same words make a double underline. Table borders (not below the baseline band)
    /// and rules that are wider than the text above them are not underlines.
    private static func underlineHighlights(
        segments: [ScannedSegment], rows: [[ExtractedWord]], lines: [RecognizedLine],
        normalized: (CGRect) -> NormalizedRect, bodySize: Double
    ) -> [RecognizedHighlight] {
        struct Candidate {
            var row: Int
            var indices: [Int]
            var segment: ScannedSegment
        }
        var candidates: [Candidate] = []
        for segment in segments where segment.thickness <= 2.5 {
            for (rowIndex, row) in rows.enumerated() {
                var covered: [Int] = []
                for (i, word) in row.enumerated() {
                    let rect = word.rect
                    let height = Double(rect.height)
                    let bandLow = Double(rect.minY) - 0.35 * height, bandHigh = Double(rect.minY) + 0.30 * height
                    guard segment.y >= bandLow, segment.y <= bandHigh else { continue }
                    let overlap = min(segment.maxX, Double(rect.maxX)) - max(segment.minX, Double(rect.minX))
                    if overlap >= 0.5 * Double(rect.width) { covered.append(i) }
                }
                guard !covered.isEmpty else { continue }
                let first = row[covered[0]].rect, last = row[covered[covered.count - 1]].rect
                let tolerance = 0.8 * Double(first.height) + 2
                guard segment.minX >= Double(first.minX) - tolerance,
                      segment.maxX <= Double(last.maxX) + tolerance else { continue }
                candidates.append(Candidate(row: rowIndex, indices: covered, segment: segment))
            }
        }

        // Merge candidates with identical word sets: two lines make a double underline.
        var result: [RecognizedHighlight] = []
        var used: Set<Int> = []
        for (i, candidate) in candidates.enumerated() where !used.contains(i) {
            var group = [candidate]
            for (j, other) in candidates.enumerated() where j > i && !used.contains(j) {
                if other.row == candidate.row, other.indices == candidate.indices,
                   abs(other.segment.y - candidate.segment.y) > 0.8 { group.append(other); used.insert(j) }
            }
            used.insert(i)
            let row = rows[candidate.row]
            let words = candidate.indices.map { row[$0] }
            let line = lines[candidate.row]
            let box = CGRect(
                x: group.map(\.segment.minX).min() ?? 0, y: (group.map(\.segment.y).min() ?? 0) - 1,
                width: (group.map(\.segment.maxX).max() ?? 0) - (group.map(\.segment.minX).min() ?? 0),
                height: (group.map(\.segment.y).max() ?? 0) - (group.map(\.segment.y).min() ?? 0) + 2)
            let color = candidate.segment.color
            let wholeLine = candidate.indices.count == row.count
            let size = words.map(\.size).max() ?? bodySize
            // Word indices refer to `kept` rows, which are the rows of `lines`.
            result.append(RecognizedHighlight(
                text: words.map(\.text).joined(separator: " "),
                kind: group.count > 1 ? .doubleUnderline : .underline,
                color: color.isNearlyBlack ? nil : color, rect: normalized(box), confidence: 1, status: .confident,
                suggestedMeaning: wholeLine && size >= 1.15 * bodySize ? .heading : (wholeLine ? nil : .term),
                source: .embeddedPDF,
                words: candidate.indices.map { WordReference(lineID: line.id, wordIndex: $0) }))
        }
        return result
    }
}
