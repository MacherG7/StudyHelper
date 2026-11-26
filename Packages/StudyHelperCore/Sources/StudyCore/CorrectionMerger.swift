import Foundation

/// A manual correction of one line, independent of storage.
public struct LineCorrectionValue: Codable, Hashable, Sendable {
    /// Where the corrected line was on the page when the user corrected it.
    public var rect: NormalizedRect
    /// Automatic text at the time of correction (for display / diagnostics).
    public var recognizedText: String
    public var correctedText: String
    /// Word-level review: indexes (into the line's words, see `WordReview.tokens(of:)`) of the words the user
    /// corrected or confirmed one by one; the other words keep their recognition status and marks.
    /// nil: the whole line was corrected or confirmed (every word counts as checked).
    public var confirmedWordIndexes: [Int]?

    public init(
        rect: NormalizedRect, recognizedText: String, correctedText: String, confirmedWordIndexes: [Int]? = nil
    ) {
        self.rect = rect
        self.recognizedText = recognizedText
        self.correctedText = correctedText
        self.confirmedWordIndexes = confirmedWordIndexes
    }

    /// Whether this is a word-level correction (`confirmedWordIndexes` set).
    public var isWordLevel: Bool { confirmedWordIndexes != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        correctedText = try c.decode(String.self, forKey: .correctedText)
        confirmedWordIndexes = try? c.decodeIfPresent([Int].self, forKey: .confirmedWordIndexes)
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
            let before = line
            // Keep the raw automatic text; never overwrite it with an earlier correction.
            if line.recognizedText == nil, !line.isUserCorrected { line.recognizedText = line.text }
            if line.recognizedText == nil { line.recognizedText = correction.recognizedText }
            line.text = correction.correctedText
            line.isUserCorrected = true
            line.status = .confident
            line.reviewReasons = []
            if let confirmed = correction.confirmedWordIndexes,
               let merged = wordLevel(correction.correctedText, confirmed: Set(confirmed), line: before) {
                line.text = merged.text
                line.words = merged.words
                result[lineIndex] = line
                continue
            }
            let newWords = correction.correctedText.split(whereSeparator: \.isWhitespace).map(String.init)
            if newWords.count == line.words.count {
                for i in line.words.indices {
                    line.words[i].text = newWords[i]
                }
            }
            for i in line.words.indices {
                line.words[i].status = .confident
                line.words[i].reviewReasons = []
                line.words[i].isUserConfirmed = false
            }
            result[lineIndex] = line
        }
        return Outcome(lines: result, unmatched: unmatched, unmatchedIndices: unmatchedIndices)
    }

    /// Word-level variant: the text and one word per token of it (`WordReview.tokens(of:)` indexes). Only the
    /// confirmed words become confident (and `isUserConfirmed`); every other word keeps its status, so the word
    /// review still marks it.
    ///
    /// - If `line` (the current or newly recognized line) has as many tokens as the corrected text, the words
    ///   correspond one to one: confirmed words get the user's text, every other word keeps the line's reading and
    ///   status (after a re-recognition: the new one).
    /// - Otherwise the corrected text wins; its tokens are aligned with the line's tokens from both ends (equal
    ///   words), and the tokens in between (e.g. "zum Beispiel" for "zumBeispiel") are spread over the area of the
    ///   line tokens they replace.
    ///
    /// Words are rebuilt from the tokens when the line has fewer or more words than tokens (missing word boxes).
    /// Returns nil only if the corrected text has no word.
    static func wordLevel(
        _ correctedText: String, confirmed: Set<Int>, line: RecognizedLine
    ) -> (text: String, words: [RecognizedWord])? {
        let corrected = WordTokenizer.tokens(in: correctedText)
        guard !corrected.isEmpty else { return nil }
        let base = WordReview.tokens(of: line)

        var text = correctedText
        var tokens = corrected
        var mapping: [Int?]
        if base.count == corrected.count, let merged = mergedText(line.text, base: base, corrected: corrected, confirmed: confirmed) {
            text = merged.text
            tokens = merged.tokens
            mapping = Array(base.indices)
        } else {
            mapping = alignEnds(base: base, final: tokens)
        }

        let finalLine: RecognizedLine = {
            var copy = line
            copy.text = text
            return copy
        }()
        let rects = spreadRects(tokens: tokens, mapping: mapping, base: base, line: finalLine)
        let inherited = WordReview.inheritedStatus(of: line)
        var words: [RecognizedWord] = []
        for (index, token) in tokens.enumerated() {
            var word: RecognizedWord
            if let b = mapping[index], let wordIndex = base[b].wordIndex {
                word = line.words[wordIndex]
            } else {
                let status = mapping[index].map { base[$0].status } ?? inherited
                word = RecognizedWord(
                    text: token.original, rect: rects[index], confidence: line.confidence, color: line.color,
                    status: status, reviewReasons: status == .confident ? [] : line.reviewReasons)
            }
            word.text = token.original
            if confirmed.contains(index) {
                word.status = .confident
                word.reviewReasons = []
                word.isUserConfirmed = true
            } else {
                word.isUserConfirmed = false
            }
            words.append(word)
        }
        return (text, words)
    }

    /// The line's text with the confirmed tokens replaced by the user's (same token count); nil if the result does
    /// not tokenize like the line.
    private static func mergedText(
        _ lineText: String, base: [ReviewToken], corrected: [WordToken], confirmed: Set<Int>
    ) -> (text: String, tokens: [WordToken])? {
        var text = ""
        var cursor = lineText.startIndex
        for (index, token) in base.enumerated() {
            text += lineText[cursor..<token.range.lowerBound]
            text += confirmed.contains(index) ? corrected[index].original : token.text
            cursor = token.range.upperBound
        }
        text += lineText[cursor...]
        let tokens = WordTokenizer.tokens(in: text)
        return tokens.count == base.count ? (text, tokens) : nil
    }

    /// Final token index → line token index for the equal words at the start and the end; nil in between.
    private static func alignEnds(base: [ReviewToken], final: [WordToken]) -> [Int?] {
        func same(_ a: ReviewToken, _ b: WordToken) -> Bool { WordTokenizer.normalize(a.text) == b.normalized }
        var mapping = [Int?](repeating: nil, count: final.count)
        var prefix = 0
        while prefix < base.count, prefix < final.count, same(base[prefix], final[prefix]) {
            mapping[prefix] = prefix
            prefix += 1
        }
        var suffix = 0
        while suffix < base.count - prefix, suffix < final.count - prefix,
              same(base[base.count - 1 - suffix], final[final.count - 1 - suffix]) {
            mapping[final.count - 1 - suffix] = base.count - 1 - suffix
            suffix += 1
        }
        return mapping
    }

    /// Rects for every final token: the line token's rect where mapped; unmapped runs share the area of the line
    /// tokens they replace in proportion to their length, or, without such tokens, a proportional slice of the line.
    private static func spreadRects(
        tokens: [WordToken], mapping: [Int?], base: [ReviewToken], line: RecognizedLine
    ) -> [NormalizedRect] {
        let total = max(1, line.text.count)
        var rects = tokens.map { WordReview.slice(of: line, range: $0.range, total: total) }
        var index = 0
        while index < tokens.count {
            if let b = mapping[index] {
                rects[index] = base[b].rect
                index += 1
                continue
            }
            var end = index
            while end < tokens.count, mapping[end] == nil { end += 1 }
            // Line tokens between the mapped neighbours are the ones this run replaces.
            let lower = (index > 0 ? mapping[index - 1].map { $0 + 1 } : 0) ?? 0
            let upper = (end < tokens.count ? mapping[end] : base.count) ?? base.count
            if lower < upper {
                let area = base[lower..<upper].map(\.rect).reduce(base[lower].rect) { $0.union($1) }
                let lengths = tokens[index..<end].map { Double($0.original.count + 1) }
                let sum = lengths.reduce(0, +)
                var x = area.minX
                for (offset, length) in lengths.enumerated() {
                    let width = area.width * length / sum
                    rects[index + offset] = NormalizedRect(x: x, y: area.minY, width: width, height: area.height)
                    x += width
                }
            }
            index = end
        }
        return rects
    }

    /// Indexes of the words that differ between two versions of a line (`WordTokenizer` tokens, compared as
    /// written). nil if the number of words differs, i.e. the change is not a word-for-word replacement.
    public static func changedWordIndexes(from old: String, to new: String) -> [Int]? {
        let a = WordTokenizer.tokens(in: old).map(\.original)
        let b = WordTokenizer.tokens(in: new).map(\.original)
        guard a.count == b.count else { return nil }
        return a.indices.filter { a[$0] != b[$0] }
    }
}
