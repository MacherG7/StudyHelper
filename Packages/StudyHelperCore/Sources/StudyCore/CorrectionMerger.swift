import Foundation

/// A manual correction of one line, independent of storage.
public struct LineCorrectionValue: Codable, Hashable, Sendable {
    /// Where the corrected line was on the page when the user corrected it.
    public var rect: NormalizedRect
    /// Automatic text at the time of correction (for display / diagnostics).
    public var recognizedText: String
    public var correctedText: String

    public init(rect: NormalizedRect, recognizedText: String, correctedText: String) {
        self.rect = rect
        self.recognizedText = recognizedText
        self.correctedText = correctedText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        correctedText = try c.decode(String.self, forKey: .correctedText)
    }
}

/// Re-applies manual corrections to the result of a new recognition run
/// (SPEC §2: corrections take precedence over any automatic recognition and
/// survive re-recognition).
public enum CorrectionMerger {
    public struct Outcome: Hashable, Sendable {
        public var lines: [RecognizedLine]
        /// Corrections whose line could not be found again; the UI shows them to the user.
        public var unmatched: [LineCorrectionValue]
        /// Indices (into the `corrections` argument) of `unmatched`.
        public var unmatchedIndices: [Int]
    }

    /// Minimum overlap (IoU) between the corrected line's old rect and a line.
    /// The single threshold for every correction lookup (merge and repository).
    public static let minimumOverlap = 0.4

    /// One-to-one best match: correction index → line index.
    public static func matching(_ corrections: [LineCorrectionValue], _ lines: [RecognizedLine]) -> [Int: Int] {
        Matching.oneToOne(leftCount: corrections.count, rightCount: lines.count) { c, l in
            let iou = lines[l].rect.iou(corrections[c].rect)
            return iou >= minimumOverlap ? iou : nil
        }
    }

    public static func apply(_ corrections: [LineCorrectionValue], to lines: [RecognizedLine]) -> Outcome {
        var result = lines
        let matches = matching(corrections, lines)
        var unmatched: [LineCorrectionValue] = []
        var unmatchedIndices: [Int] = []

        for (index, correction) in corrections.enumerated() {
            guard let lineIndex = matches[index] else {
                unmatched.append(correction)
                unmatchedIndices.append(index)
                continue
            }
            var line = result[lineIndex]
            // Keep the raw automatic text; never overwrite it with an earlier correction.
            if line.recognizedText == nil, !line.isUserCorrected { line.recognizedText = line.text }
            if line.recognizedText == nil { line.recognizedText = correction.recognizedText }
            line.text = correction.correctedText
            line.isUserCorrected = true
            line.status = .confident
            line.reviewReasons = []
            let newWords = correction.correctedText.split(whereSeparator: \.isWhitespace).map(String.init)
            if newWords.count == line.words.count {
                for i in line.words.indices {
                    line.words[i].text = newWords[i]
                    line.words[i].status = .confident
                    line.words[i].reviewReasons = []
                }
            } else {
                for i in line.words.indices {
                    line.words[i].status = .confident
                    line.words[i].reviewReasons = []
                }
            }
            result[lineIndex] = line
        }
        return Outcome(lines: result, unmatched: unmatched, unmatchedIndices: unmatchedIndices)
    }
}
