import Foundation
import StudyCore

/// Cross-check of recognized words with the text layer of the reduced Goodnotes PDF.
enum ReducedPDFComparison {
    /// A text-layer word counts as "the counterpart" of a recognized word if their boxes overlap clearly.
    private static let minIoU = 0.25

    static func crossCheck(lines: [RecognizedLine], against reducedPage: GoodnotesPage) -> [RecognizedLine] {
        let layer = reducedPage.textLayer.map { (word: $0, normalized: WordTokenizer.normalize($0.text)) }
        guard !layer.isEmpty else { return lines }

        return lines.map { line in
            var line = line
            var anyMismatch = false
            for index in line.words.indices {
                let word = line.words[index]
                let expected = WordTokenizer.normalize(word.text)
                guard !expected.isEmpty else { continue }
                let counterparts = counterparts(of: word.rect, in: layer)
                guard !counterparts.isEmpty else { continue }

                // Equal to one counterpart, or to the concatenation of several (word split differently).
                let joined = counterparts.map(\.normalized).joined()
                let confirmed = counterparts.contains { $0.normalized == expected } || joined == expected
                if confirmed {
                    append(.confirmedByReducedPDF, to: &line.words[index].reviewReasons)
                } else {
                    anyMismatch = true
                    append(.mismatchWithReducedPDF, to: &line.words[index].reviewReasons)
                    line.words[index].status = .uncertain
                }
            }
            if anyMismatch {
                append(.mismatchWithReducedPDF, to: &line.reviewReasons)
                if !line.isUserCorrected, line.status == .confident { line.status = .uncertain }
            }
            return line
        }
    }

    private static func counterparts(
        of rect: NormalizedRect, in layer: [(word: TextLayerWord, normalized: String)]
    ) -> [(word: TextLayerWord, normalized: String)] {
        let hits = layer.filter { entry in
            let r = entry.word.rect
            if r.contains(x: rect.midX, y: rect.midY) || rect.contains(x: r.midX, y: r.midY) { return true }
            return rect.iou(r) >= minIoU
        }
        return hits.sorted { $0.word.rect.minX < $1.word.rect.minX }
    }

    private static func append(_ reason: ReviewReason, to reasons: inout [ReviewReason]) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }
}
