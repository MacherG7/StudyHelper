import CoreGraphics
import Foundation
import StudyCore

// Kept free of `import Vision` because Vision also exports a type called `NormalizedRect`.

extension NormalizedRect {
    /// From a rect in Vision's normalized space (0…1, origin bottom-left) to the app convention (origin top-left).
    static func fromVision(_ rect: CGRect) -> NormalizedRect {
        .fromBottomLeft(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            width: Double(rect.size.width), height: Double(rect.size.height),
            spaceWidth: 1, spaceHeight: 1
        )
    }
}

extension NormalizedRect {
    /// The rect after the page is displayed rotated clockwise by `degrees` (0, 90, 180 or 270), for rects that
    /// were measured on the unrotated page (PDF user space). Origin stays top-left.
    func rotatedClockwise(_ degrees: Int) -> NormalizedRect {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return NormalizedRect(x: 1 - (y + height), y: x, width: height, height: width)
        case 180: return NormalizedRect(x: 1 - (x + width), y: 1 - (y + height), width: width, height: height)
        case 270: return NormalizedRect(x: y, y: 1 - (x + width), width: height, height: width)
        default: return self
        }
    }
}

/// Shared helpers of the two Vision code paths.
enum VisionLineBuilder {
    /// Below this confidence a line or word counts as uncertain.
    static let lowConfidenceThreshold = 0.5

    /// Status for a recognizer confidence value.
    static func status(for confidence: Double) -> (ConfidenceStatus, [ReviewReason]) {
        confidence < lowConfidenceThreshold ? (.uncertain, [.lowConfidence]) : (.confident, [])
    }

    /// Builds a line from the best candidate's text and per-word boxes.
    /// - Parameters:
    ///   - text: best reading.
    ///   - alternatives: other readings, best first (may contain `text`; it is removed).
    ///   - wordRect: normalized box (top-left origin) for a token range in `text`, if the recognizer knows it.
    static func makeLine(
        text: String, confidence: Double, alternatives: [String], lineRect: NormalizedRect,
        blockKind: LineBlockKind?, wordRect: (Range<String.Index>) -> NormalizedRect?
    ) -> RecognizedLine {
        let (lineStatus, lineReasons) = status(for: confidence)
        var seen: Set<String> = [text]
        var candidates: [String] = []
        for alternative in alternatives where seen.insert(alternative).inserted { candidates.append(alternative) }

        var words: [RecognizedWord] = []
        for token in WordTokenizer.tokens(in: text) {
            guard let rect = wordRect(token.range), !rect.isEmpty else { continue }
            words.append(RecognizedWord(
                text: token.original, rect: rect, confidence: confidence,
                status: lineStatus, reviewReasons: lineReasons
            ))
        }
        return RecognizedLine(
            text: text, rect: lineRect, confidence: confidence, candidates: candidates, words: words,
            status: lineStatus, reviewReasons: lineReasons, blockKind: blockKind
        )
    }

    /// Orders lines top to bottom, then left to right, and numbers them. Lines whose vertical centers lie
    /// within one line height are on the same row.
    static func sortAndNumber(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        var sorted = lines.sorted { a, b in
            let tolerance = 0.5 * min(a.rect.height, b.rect.height)
            if abs(a.rect.midY - b.rect.midY) <= tolerance { return a.rect.minX < b.rect.minX }
            return a.rect.midY < b.rect.midY
        }
        for index in sorted.indices { sorted[index].order = index }
        return sorted
    }
}

/// A block of the page structure found by `RecognizeDocumentsRequest`: where a text line is and what it is.
struct DocumentBlockLine: Hashable, Sendable {
    var rect: NormalizedRect
    var kind: LineBlockKind
}

enum DocumentStructure {
    /// Gives each line the kind of the structure block that covers most of it (at least half).
    static func classify(_ lines: [RecognizedLine], with blocks: [DocumentBlockLine]) -> [RecognizedLine] {
        lines.map { line in
            var best: (kind: LineBlockKind, coverage: Double)?
            for block in blocks {
                let coverage = line.rect.coverage(by: block.rect)
                if coverage >= 0.5, coverage > (best?.coverage ?? 0) { best = (block.kind, coverage) }
            }
            var result = line
            result.blockKind = best?.kind
            if best?.kind == .listItem { result = removingBulletMarker(from: result) }
            return result
        }
    }

    /// Bullet glyphs; the Markdown list prefix replaces them, so the line text starts after the marker.
    static let bulletMarkers: Set<String> = ["\u{2022}", "\u{25AA}", "\u{25E6}", "\u{2023}", "\u{00B7}", "-", "\u{2013}", "*", "\u{25CF}"]

    static func removingBulletMarker(from line: RecognizedLine) -> RecognizedLine {
        // The tokenizer drops punctuation-only tokens, so the marker is in the text but not in `words`.
        let parts = line.text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, bulletMarkers.contains(String(parts[0])) else { return line }
        var result = line
        result.text = String(parts[1])
        return result
    }
}
