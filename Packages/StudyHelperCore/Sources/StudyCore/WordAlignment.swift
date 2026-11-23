import Foundation

/// One step of an alignment between two word sequences.
public enum AlignmentStep: Hashable, Sendable {
    /// Words at `left` and `right` are considered equal.
    case match(left: Int, right: Int)
    /// Word at `left` was read as word at `right` (differs).
    case substitution(left: Int, right: Int)
    /// Word at `left` has no counterpart on the right.
    case deletion(left: Int)
    /// Word at `right` has no counterpart on the left.
    case insertion(right: Int)
}

/// Minimal-edit alignment of word sequences (Levenshtein on tokens).
///
/// Used to compare our recognition with the Goodnotes text layer (Phase 1) and
/// the original text with the sorted version (Phase 4).
public enum WordAlignment {
    /// Aligns `left` with `right`. `equal` decides when two words count as the same;
    /// `similar` decides when two different words are a misreading of each other.
    /// A substitution of similar words costs 1, of unrelated words 2 (same as
    /// deleting one and inserting the other), so unrelated words are not paired up.
    public static func align<T>(
        _ left: [T], _ right: [T],
        equal: (T, T) -> Bool,
        similar: (T, T) -> Bool = { _, _ in false }
    ) -> [AlignmentStep] {
        func substitutionCost(_ a: T, _ b: T) -> Int {
            equal(a, b) ? 0 : (similar(a, b) ? 1 : 2)
        }
        let n = left.count, m = right.count
        // cost[i][j] = edit distance between left[..<i] and right[..<j]
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    cost[i][j] = min(
                        cost[i - 1][j - 1] + substitutionCost(left[i - 1], right[j - 1]),
                        cost[i - 1][j] + 1,
                        cost[i][j - 1] + 1
                    )
                }
            }
        }
        var steps: [AlignmentStep] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let same = equal(left[i - 1], right[j - 1])
                if cost[i][j] == cost[i - 1][j - 1] + substitutionCost(left[i - 1], right[j - 1]) {
                    steps.append(same ? .match(left: i - 1, right: j - 1) : .substitution(left: i - 1, right: j - 1))
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(.deletion(left: i - 1))
                i -= 1
            } else {
                steps.append(.insertion(right: j - 1))
                j -= 1
            }
        }
        return steps.reversed()
    }

    /// Aligns two token lists by their `normalized` form. Words count as similar
    /// (a misreading) when their folded forms differ by at most a third of their length.
    public static func align(_ left: [WordToken], _ right: [WordToken]) -> [AlignmentStep] {
        align(left, right, equal: { $0.normalized == $1.normalized }, similar: areSimilar)
    }

    /// True if two tokens are probably the same word read differently.
    public static func areSimilar(_ a: WordToken, _ b: WordToken) -> Bool {
        let limit = max(1, max(a.folded.count, b.folded.count) / 3)
        return characterDistance(a.folded, b.folded) <= limit
    }

    /// Character-level Levenshtein distance.
    public static func characterDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
