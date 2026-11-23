import Foundation

/// One word of a text with two comparison forms.
public struct WordToken: Hashable, Sendable {
    /// The word as written (surrounding whitespace removed).
    public var original: String
    /// NFC, lowercased, leading/trailing punctuation removed. Umlauts are kept.
    public var normalized: String
    /// `normalized` with diacritics folded (ä→a) and ß→ss. Used for lenient matching.
    public var folded: String
    /// Range of `original` in the source string.
    public var range: Range<String.Index>
}

/// German-aware word splitting and normalization, shared by every comparison
/// (reduced-PDF cross-check, sorted-version completeness check, search).
public enum WordTokenizer {
    /// Characters trimmed from both ends of a word for comparisons.
    static let trimmed: CharacterSet = .punctuationCharacters
        .union(.symbols)
        .subtracting(CharacterSet(charactersIn: "%€$°+=<>→←"))

    /// Splits on whitespace. Hyphenated compounds ("Licht-Energie") stay one token.
    /// Tokens that consist only of punctuation are dropped.
    public static func tokens(in text: String) -> [WordToken] {
        var result: [WordToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let original = String(text[start..<index])
            let normalized = normalize(original)
            guard !normalized.isEmpty else { continue }
            result.append(WordToken(original: original, normalized: normalized, folded: fold(normalized), range: start..<index))
        }
        return result
    }

    /// NFC, lowercased (German locale), punctuation trimmed at both ends.
    public static func normalize(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "de_DE"))
            .trimmingCharacters(in: trimmed)
    }

    /// Removes diacritics and replaces ß with ss.
    public static func fold(_ normalizedWord: String) -> String {
        normalizedWord
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
    }
}
