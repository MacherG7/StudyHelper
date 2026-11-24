import Foundation
import StudyCore

/// Fixed misreadings of Vision on German handwriting that are unambiguous in context. The original reading is
/// kept as the first alternative (`candidates`), so nothing is lost.
enum KnownMisreadings {
    /// "z.B." read with ß for B ("z.ß", "2.ß."): an ß never follows "z." in German.
    private static let zumBeispiel = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\d])[zZ2]\\.\\s?ß(?=[\\s.,;:)]|$)")

    /// Page reference "B.S.35" (Buch, Seite 35) read with 5 for S: after a single capital and a dot, "5." followed
    /// by a number is the abbreviation "S." (not after "z.B.", where a number may follow).
    private static let pageReference = try! NSRegularExpression(
        pattern: "(?<=(?<![\\p{L}.])\\p{Lu}\\.)5\\.(?=\\s?\\d)")

    static func fix(_ text: String) -> String {
        var result = zumBeispiel.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "z.B")
        result = pageReference.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "S.")
        return result
    }

    static func apply(to line: RecognizedLine) -> RecognizedLine {
        guard !line.isUserCorrected else { return line }
        let fixed = fix(line.text)
        guard fixed != line.text else { return line }
        var result = line
        result.candidates = [line.text] + line.candidates.filter { $0 != line.text && $0 != fixed }
        result.text = fixed
        for index in result.words.indices { result.words[index].text = fix(result.words[index].text) }
        return result
    }

    static func apply(to lines: [RecognizedLine]) -> [RecognizedLine] { lines.map(apply(to:)) }
}
