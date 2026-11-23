import Foundation

/// One-to-one best-match assignment shared by every "find it again after
/// re-recognition" step (line corrections, highlight corrections, line id
/// carry-over), so that all of them behave the same.
public enum Matching {
    /// Greedy global best match: all eligible pairs are sorted by score
    /// (descending, ties by lower indices) and assigned while both sides are free.
    /// - Parameter score: nil = pair not eligible; larger = better.
    /// - Returns: left index → right index.
    public static func oneToOne(
        leftCount: Int, rightCount: Int, score: (Int, Int) -> Double?
    ) -> [Int: Int] {
        var pairs: [(left: Int, right: Int, score: Double)] = []
        for l in 0..<leftCount {
            for r in 0..<rightCount {
                if let s = score(l, r) { pairs.append((l, r, s)) }
            }
        }
        pairs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.left != b.left { return a.left < b.left }
            return a.right < b.right
        }
        var result: [Int: Int] = [:]
        var usedRight: Set<Int> = []
        for pair in pairs where result[pair.left] == nil && !usedRight.contains(pair.right) {
            result[pair.left] = pair.right
            usedRight.insert(pair.right)
        }
        return result
    }

    /// Case-, diacritic- and whitespace-insensitive form for comparing recognized text.
    public static func normalizedText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Keeps line ids stable across recognition runs, so that references to lines
/// (`WordReference`, topic entries) survive a re-recognition.
public enum LineIdentity {
    /// Minimum overlap (IoU) for a new line to inherit the id of an old line.
    public static let minimumOverlap = 0.5

    public struct Outcome: Sendable {
        public var lines: [RecognizedLine]
        /// Generated id of the new line → carried-over id of the old line.
        public var idMap: [UUID: UUID]
    }

    /// Gives every new line that geometrically matches an old line (best match,
    /// one-to-one, IoU ≥ `minimumOverlap`) the old line's id.
    public static func carryOver(from old: [RecognizedLine], to new: [RecognizedLine]) -> Outcome {
        let matching = Matching.oneToOne(leftCount: new.count, rightCount: old.count) { n, o in
            let iou = new[n].rect.iou(old[o].rect)
            return iou >= minimumOverlap ? iou : nil
        }
        var lines = new
        var idMap: [UUID: UUID] = [:]
        for (n, o) in matching {
            let oldID = old[o].id
            if lines[n].id != oldID {
                idMap[lines[n].id] = oldID
                lines[n].id = oldID
            }
        }
        return Outcome(lines: lines, idMap: idMap)
    }

    /// Rewrites word references of `highlights` according to `idMap`.
    public static func remap(_ highlights: [RecognizedHighlight], using idMap: [UUID: UUID]) -> [RecognizedHighlight] {
        guard !idMap.isEmpty else { return highlights }
        return highlights.map { highlight in
            var h = highlight
            h.words = h.words.map { ref in
                idMap[ref.lineID].map { WordReference(lineID: $0, wordIndex: ref.wordIndex) } ?? ref
            }
            return h
        }
    }
}
