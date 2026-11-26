import Foundation
import StudyCore

/// Reading suggestions for one word the review marked (`WordReview`), from a model that sees the neighbouring words.
/// Meant for the on-device Apple model (plain text answer), works with every provider.
public enum WordSuggestions {
    /// Most suggestions taken from an answer.
    public static let maximumCount = 5
    /// The answer is a short JSON list; this leaves room without inviting explanations.
    public static let maxOutputTokens = 120

    /// Fixed instruction (not editable). Keeps the basic rule: only what is written in the learning material, the
    /// model proposes readings of the written word and adds nothing.
    public static let instruction = """
        Du hilfst beim Prüfen einer Handschrifterkennung. Du bekommst ein Wort, das die Texterkennung unsicher \
        gelesen hat, die Wörter davor und danach und das Fach.
        Schlage bis zu 5 Lesarten vor, die an dieser Stelle wahrscheinlich geschrieben wurden.
        Regeln:
        - Nur Schreib- und Lesevarianten genau dieses einen Wortes, so wie es geschrieben wurde.
        - Keine neuen Inhalte, keine zusätzlichen Wörter, keine Ergänzungen aus eigenem Wissen.
        - Keine Erklärungen.
        - Wenn dir keine passende Lesart einfällt, gib eine leere Liste zurück.
        Antworte nur mit JSON in genau dieser Form: {"vorschlaege": ["Wort1", "Wort2"]}
        """

    /// The request for one marked word.
    /// - Parameters:
    ///   - word: the marked word as recognized.
    ///   - before, after: neighbouring words (`WordReview.context`).
    ///   - subject: name of the subject, if known.
    public static func request(word: String, before: String, after: String, subject: String?) -> ModelRequest {
        var lines: [String] = []
        if let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            lines.append("Fach: \(subject)")
        }
        let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = after.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Text davor: \(before.isEmpty ? "–" : before)")
        lines.append("Unsicheres Wort: \(word.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("Text danach: \(after.isEmpty ? "–" : after)")
        return ModelRequest(
            task: .wordSuggestions, system: PromptParts(fixed: instruction), messages: [.user(lines.joined(separator: "\n"))],
            reasoning: .off, maxOutputTokens: maxOutputTokens)
    }

    /// The suggestions of an answer: a JSON object `{"vorschlaege": [...]}` or a bare JSON array, also inside code
    /// fences or prose. Keeps only plausible readings of the original word (one word, similar length, mostly
    /// letters), without duplicates and without the original, at most `maximumCount`. Anything malformed gives [].
    public static func parse(_ text: String, original: String) -> [String] {
        guard case .success(let json) = StructuredOutput.extractJSON(from: text),
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        else { return [] }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let object = value as? [String: Any] {
            let keys = ["vorschlaege", "vorschläge", "Vorschlaege", "Vorschläge", "suggestions"]
            guard let array = keys.lazy.compactMap({ object[$0] as? [Any] }).first else { return [] }
            items = array
        } else {
            return []
        }

        let originalWord = WordReview.splitPunctuation(original.trimmingCharacters(in: .whitespacesAndNewlines)).core
        let allowsTwoWords = originalWord.contains(where: \.isWhitespace)
        var seen: Set<String> = []
        var result: [String] = []
        for case let item as String in items {
            let candidate = WordReview.splitPunctuation(item.trimmingCharacters(in: .whitespacesAndNewlines)).core
            guard isPlausible(candidate, original: originalWord, allowsTwoWords: allowsTwoWords),
                  candidate != originalWord,
                  seen.insert(candidate.lowercased()).inserted
            else { continue }
            result.append(candidate)
            if result.count >= maximumCount { break }
        }
        return result
    }

    static func isPlausible(_ candidate: String, original: String, allowsTwoWords: Bool) -> Bool {
        guard !candidate.isEmpty, !candidate.contains(where: \.isNewline) else { return false }
        let words = candidate.split(whereSeparator: \.isWhitespace)
        guard words.count == 1 || (allowsTwoWords && words.count == 2) else { return false }
        for word in words {
            let joiners = word.filter { "-'’".contains($0) }.count
            guard joiners <= 1 else { return false }
            guard word.allSatisfy({ $0.isLetter || $0.isNumber || "-'’.".contains($0) }) else { return false }
        }
        let characters = candidate.filter { !$0.isWhitespace }
        let letters = characters.filter(\.isLetter).count
        guard letters > 0, Double(letters) >= 0.75 * Double(characters.count) else { return false }
        // Similar length: within ±50 % of the original (at least ±1 character).
        let length = original.filter { !$0.isWhitespace }.count
        if length > 0 {
            let tolerance = max(1, Int((Double(length) * 0.5).rounded(.up)))
            guard abs(characters.count - length) <= tolerance else { return false }
        }
        return true
    }

    /// Asks `provider` and parses the answer (`parse`). Provider errors are thrown; a malformed answer gives [].
    public static func suggest(
        word: String, before: String, after: String, subject: String?, provider: any ModelProvider
    ) async throws -> [String] {
        let response = try await provider.respond(to: request(word: word, before: before, after: after, subject: subject))
        return parse(response.text, original: word)
    }
}
