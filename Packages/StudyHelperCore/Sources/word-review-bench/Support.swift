#if canImport(AppKit)
// Support code of word-review-bench: spell checker and alignment with the reference text.
import AppKit
import Foundation
import StudyCore

// MARK: Spell checker

/// German spell checking with NSSpellChecker, standing in for the app's UITextChecker on the Mac. NSSpellChecker is
/// main-thread only; calls from other threads hop to the main queue (the main actor is suspended while it awaits).
final class MacSpellChecker: SpellChecking, @unchecked Sendable {
    let language: String
    init(language: String = "de") { self.language = language }

    private func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
    }

    func isKnown(_ word: String) -> Bool {
        guard !word.isEmpty else { return true }
        let language = language
        return onMain {
            NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
    }

    func guesses(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let language = language
        return onMain {
            NSSpellChecker.shared.guesses(
                forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: language,
                inSpellDocumentWithTag: 0) ?? []
        }
    }
}

// MARK: Normalization

enum Text {
    /// Comparison form: NFC, lowercased, punctuation and quotes trimmed (`WordTokenizer.normalize`).
    static func norm(_ s: String) -> String { WordTokenizer.normalize(s) }
}

// MARK: Alignment with the reference

struct RefToken {
    var text: String
    var norm: String
    var folded: String
    var refLine: Int
}

/// Semi-global alignment of one recognized line's tokens against the page reference (free start and end in the
/// reference), so that lines in a different reading order or split lines still find their words.
enum ReferenceAligner {
    enum Step { case match(Int, Int), sub(Int, Int), extra(Int), missing(Int) }

    static func cost(_ a: WordToken, _ b: RefToken) -> Double {
        if a.normalized == b.norm { return 0 }
        let limit = max(1, max(a.folded.count, b.folded.count) / 2)
        let d = WordAlignment.characterDistance(a.folded, b.folded)
        if d == 0 { return 0.2 } // umlaut/ß difference only
        return d <= limit ? 1 : 1.7
    }

    /// Returns the steps and the cost. Ties (repeated passages) go to the end position closest to `expectedEnd`
    /// (reading order).
    static func align(_ rec: [WordToken], _ ref: [RefToken], expectedEnd: Int = 0) -> (steps: [Step], cost: Double) {
        let n = rec.count, m = ref.count
        guard n > 0 else { return ([], 0) }
        guard m > 0 else { return ((0..<n).map { .extra($0) }, Double(n)) }
        var d = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Double(i) }
        for i in 1...n {
            for j in 1...m {
                d[i][j] = min(d[i - 1][j - 1] + cost(rec[i - 1], ref[j - 1]), d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        var bestJ = 0
        for j in 0...m where d[n][j] < d[n][bestJ] { bestJ = j }
        let best = d[n][bestJ]
        for j in 0...m where d[n][j] <= best + 1e-9 && abs(j - expectedEnd) < abs(bestJ - expectedEnd) { bestJ = j }
        var steps: [Step] = []
        var i = n, j = bestJ
        while i > 0 {
            if j > 0, abs(d[i][j] - (d[i - 1][j - 1] + cost(rec[i - 1], ref[j - 1]))) < 1e-9 {
                steps.append(rec[i - 1].normalized == ref[j - 1].norm ? .match(i - 1, j - 1) : .sub(i - 1, j - 1))
                i -= 1; j -= 1
            } else if abs(d[i][j] - (d[i - 1][j] + 1)) < 1e-9 {
                steps.append(.extra(i - 1)); i -= 1
            } else {
                steps.append(.missing(j - 1)); j -= 1
            }
        }
        return (steps.reversed(), d[n][bestJ])
    }
}

#else
#endif
