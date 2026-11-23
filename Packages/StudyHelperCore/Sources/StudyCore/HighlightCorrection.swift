import Foundation

/// Properties of a highlight a user edit can override.
public enum HighlightField: String, Codable, Hashable, Sendable {
    case kind, color, meaning
}

/// A manual edit of the highlights of a source, independent of storage. Identified
/// by position and text (not by the highlight's UUID, which changes with every
/// recognition run), so it can be re-applied after re-recognition (SPEC §2).
public struct HighlightCorrectionValue: Codable, Hashable, Sendable, Identifiable {
    public enum Action: String, Codable, Hashable, Sendable {
        /// The user created a highlight.
        case add
        /// The user changed kind/color/meaning of an automatic highlight.
        case modify
        /// The user removed an automatic highlight.
        case delete
    }

    /// Stable id of this correction (also the id of the highlight an `.add` creates).
    public var id: UUID
    public var action: Action
    /// Area of the highlight: of the automatic one (`modify`, `delete`) or of the
    /// created one (`add`, then covering the selected words).
    public var rect: NormalizedRect
    /// Text of the highlight when edited (automatic text for `modify`/`delete`).
    public var text: String
    /// Kind of the automatic highlight at the time of the edit (`modify`, `delete`).
    public var originalKind: HighlightKind?
    /// Fields the user changed (`modify`); `add` carries all three.
    public var changedFields: [HighlightField]
    public var kind: HighlightKind?
    public var color: RGBColor?
    public var meaning: HighlightMeaning?

    public init(
        id: UUID = UUID(), action: Action, rect: NormalizedRect, text: String,
        originalKind: HighlightKind? = nil, changedFields: [HighlightField] = [],
        kind: HighlightKind? = nil, color: RGBColor? = nil, meaning: HighlightMeaning? = nil
    ) {
        self.id = id
        self.action = action
        self.rect = rect
        self.text = text
        self.originalKind = originalKind
        self.changedFields = changedFields
        self.kind = kind
        self.color = color
        self.meaning = meaning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        action = try c.decode(Action.self, forKey: .action)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        originalKind = try c.decodeIfPresent(HighlightKind.self, forKey: .originalKind)
        changedFields = try c.decodeIfPresent([HighlightField].self, forKey: .changedFields) ?? []
        kind = try c.decodeIfPresent(HighlightKind.self, forKey: .kind)
        color = try c.decodeIfPresent(RGBColor.self, forKey: .color)
        meaning = try c.decodeIfPresent(HighlightMeaning.self, forKey: .meaning)
    }

    /// Records that `field` was changed to the value held in `kind`/`color`/`meaning`.
    public mutating func markChanged(_ field: HighlightField) {
        if !changedFields.contains(field) { changedFields.append(field) }
    }
}

/// Re-applies manual highlight edits to a recognition result.
public enum HighlightCorrectionMerger {
    public struct Outcome: Hashable, Sendable {
        public var highlights: [RecognizedHighlight]
        /// Indices (into the `corrections` argument) that found no counterpart.
        public var unmatchedIndices: [Int]
    }

    /// Minimum IoU of the highlight rects for a match.
    public static let minimumOverlap = 0.5
    /// Looser overlap that is accepted when the highlighted text is the same.
    public static let minimumOverlapWithSameText = 0.2
    /// Minimum share of a word's area that must lie inside an added highlight's rect.
    public static let minimumWordCoverage = 0.5

    /// One-to-one best match of `modify`/`delete` corrections to `highlights`:
    /// correction index → highlight index. Same original kind wins over a bigger overlap.
    public static func matching(
        _ corrections: [HighlightCorrectionValue], _ highlights: [RecognizedHighlight]
    ) -> [Int: Int] {
        Matching.oneToOne(leftCount: corrections.count, rightCount: highlights.count) { c, h in
            let correction = corrections[c]
            guard correction.action != .add else { return nil }
            let highlight = highlights[h]
            let iou = highlight.rect.iou(correction.rect)
            let sameText = Matching.normalizedText(highlight.text) == Matching.normalizedText(correction.text)
            guard iou >= minimumOverlap || (sameText && iou >= minimumOverlapWithSameText) else { return nil }
            let sameKind = correction.originalKind == highlight.kind
            return iou + (sameKind ? 1 : 0) + (sameText ? 0.1 : 0)
        }
    }

    /// - Parameters:
    ///   - highlights: the automatic highlights (raw recognition result).
    ///   - lines: the final lines (ids already carried over), used to resolve words of added highlights.
    public static func apply(
        _ corrections: [HighlightCorrectionValue], to highlights: [RecognizedHighlight],
        lines: [RecognizedLine]
    ) -> Outcome {
        // Never duplicate a highlight a correction created earlier.
        let addIDs = Set(corrections.filter { $0.action == .add }.map(\.id))
        var result = highlights.filter { !addIDs.contains($0.id) }
        let matches = matching(corrections, result)
        var unmatched: [Int] = []
        var removed: Set<Int> = []
        var additions: [RecognizedHighlight] = []

        for (index, correction) in corrections.enumerated() {
            switch correction.action {
            case .add:
                guard let highlight = makeHighlight(from: correction, lines: lines) else {
                    unmatched.append(index)
                    continue
                }
                additions.append(highlight)
            case .modify, .delete:
                guard let h = matches[index] else {
                    unmatched.append(index)
                    continue
                }
                if correction.action == .delete {
                    removed.insert(h)
                    continue
                }
                var highlight = result[h]
                for field in correction.changedFields {
                    switch field {
                    case .kind: if let kind = correction.kind { highlight.kind = kind }
                    case .color: highlight.color = correction.color
                    case .meaning: highlight.suggestedMeaning = correction.meaning
                    }
                }
                highlight.source = .user
                highlight.status = .confident
                highlight.correctionID = correction.id
                result[h] = highlight
            }
        }
        let kept = result.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        return Outcome(highlights: kept + additions, unmatchedIndices: unmatched)
    }

    private static func makeHighlight(
        from correction: HighlightCorrectionValue, lines: [RecognizedLine]
    ) -> RecognizedHighlight? {
        guard let kind = correction.kind else { return nil }
        var refs: [WordReference] = []
        var texts: [String] = []
        for line in lines.sorted(by: { $0.order < $1.order }) {
            for (index, word) in line.words.enumerated()
            where word.rect.coverage(by: correction.rect) >= minimumWordCoverage {
                refs.append(WordReference(lineID: line.id, wordIndex: index))
                texts.append(word.text)
            }
        }
        guard !refs.isEmpty else { return nil }
        return RecognizedHighlight(
            id: correction.id, text: texts.joined(separator: " "), kind: kind, color: correction.color,
            rect: correction.rect, status: .confident, suggestedMeaning: correction.meaning,
            source: .user, words: refs, correctionID: correction.id)
    }
}
