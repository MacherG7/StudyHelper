import Foundation
import StudyCore

/// Plausibility check of recognized text for German school notes. Vision sometimes reads scribbles as
/// Cyrillic, Greek, Arabic or CJK letters, or as Turkish letters (dotted/dotless i, Ş, Ğ) when the language
/// is German. Such text is never what the student wrote, so it is replaced by an alternative reading that
/// passes, or flagged as uncertain.
enum ScriptGuard {
    /// Turkish letters that do not occur in German notes (the German reading of these shapes is i/s/g).
    private static let turkishLetters: Set<UInt32> = [0x0130, 0x0131, 0x015E, 0x015F, 0x011E, 0x011F]

    /// True if the scalar is a letter of a script other than Latin, or one of the Turkish letters.
    static func isSuspiciousLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            break
        default:
            return false
        }
        let v = scalar.value
        if turkishLetters.contains(v) { return true }
        switch v {
        case 0x41...0x5A, 0x61...0x7A:  // ASCII
            return false
        case 0xAA, 0xB5, 0xBA:  // ª µ º
            return false
        case 0xC0...0xFF:  // Latin-1 letters (umlauts, ß, accents)
            return false
        case 0x100...0x24F:  // Latin Extended-A/B
            return false
        case 0x1E00...0x1EFF:  // Latin Extended Additional
            return false
        case 0xFB00...0xFB06:  // ligatures (ﬁ, ﬂ)
            return false
        default:
            return true
        }
    }

    /// True if the text has no letter from a foreign script (digits, punctuation, symbols and all Latin
    /// letters incl. umlauts are fine).
    static func isPlausible(_ text: String) -> Bool {
        !text.unicodeScalars.contains(where: isSuspiciousLetter)
    }

    /// Whether the word contains a suspicious letter.
    static func isPlausible(word: String) -> Bool { isPlausible(word) }

    /// Replaces a line that reads in an implausible script by its first alternative reading that passes. Without
    /// such an alternative the line stays but becomes `.uncertain` with reason `.lowConfidence` (the words with
    /// foreign letters too). Lines that pass, and lines the user corrected, are returned unchanged.
    static func apply(to line: RecognizedLine) -> RecognizedLine {
        guard !line.isUserCorrected, !isPlausible(line.text) else { return line }
        var result = line
        if let alternative = line.candidates.first(where: { isPlausible($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            result.candidates = ([line.text] + line.candidates.filter { $0 != alternative })
            result.text = alternative
            result.words = spreadWords(of: alternative, over: line)
            return result
        }
        result.status = result.status.atLeastUncertain
        if !result.reviewReasons.contains(.lowConfidence) { result.reviewReasons.append(.lowConfidence) }
        for index in result.words.indices where !isPlausible(result.words[index].text) {
            result.words[index].status = result.words[index].status.atLeastUncertain
            if !result.words[index].reviewReasons.contains(.lowConfidence) {
                result.words[index].reviewReasons.append(.lowConfidence)
            }
        }
        return result
    }

    static func apply(to lines: [RecognizedLine]) -> [RecognizedLine] { lines.map(apply(to:)) }

    /// Word boxes for a replacement text: spread over the line box in proportion to the word lengths (the
    /// recognizer gave boxes only for its first reading).
    private static func spreadWords(of text: String, over line: RecognizedLine) -> [RecognizedWord] {
        let tokens = WordTokenizer.tokens(in: text)
        let total = max(1, tokens.reduce(0) { $0 + $1.original.count + 1 })
        var x = line.rect.minX
        var words: [RecognizedWord] = []
        for token in tokens {
            let width = line.rect.width * Double(token.original.count + 1) / Double(total)
            words.append(RecognizedWord(
                text: token.original, rect: NormalizedRect(x: x, y: line.rect.y, width: width, height: line.rect.height),
                confidence: line.confidence, color: line.color, status: line.status, reviewReasons: line.reviewReasons))
            x += width
        }
        return words
    }
}

extension ConfidenceStatus {
    /// `.uncertain` unless the status is already worse.
    var atLeastUncertain: ConfidenceStatus { self == .illegible ? .illegible : .uncertain }
}
