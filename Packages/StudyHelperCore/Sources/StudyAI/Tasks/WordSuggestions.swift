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

    /// The request for one marked word (free suggestions).
    ///
    /// Deprecated for the app: the on-device model invented words here (28 % top-1 on a real export). The app reads
    /// the word again from the ink (`VisionWordCandidateProvider`) and lets the model only reorder those readings
    /// (`rerankRequest`, D-046). Kept for comparisons in `word-review-bench`.
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

    // MARK: Reordering

    /// Most candidates offered for reordering.
    public static let maximumRerankCount = 6
    /// Room for the candidates as a JSON list.
    public static let rerankMaxOutputTokens = 160

    /// Fixed instruction for reordering (not editable). The model only orders readings the text recognition found
    /// in the image; it adds nothing (basic rule: only what is written in the learning material).
    public static let rerankInstruction = """
        Du hilfst beim Prüfen einer Handschrifterkennung. An einer Stelle eines Textes ist ein Wort unsicher \
        gelesen. Du bekommst die Wörter davor und danach und eine nummerierte Liste von Lesarten, die die \
        Texterkennung im Bild gefunden hat.
        Ordne die Lesarten danach, wie gut sie an dieser Stelle in den Satz passen (am besten passende zuerst).
        Regeln:
        - Verwende nur die Lesarten aus der Liste, genau so geschrieben wie dort.
        - Keine anderen Wörter, keine Änderungen, keine Erklärungen.
        Antworte nur mit JSON in genau dieser Form: {"reihenfolge": ["Lesart1", "Lesart2"]}
        """

    /// The request to reorder the candidates of one marked word (at most `maximumRerankCount` are offered).
    /// - Parameters:
    ///   - candidates: readings, best first (`WordCandidate.text`).
    ///   - before, after: neighbouring words (`WordReview.context`).
    ///   - subject: name of the subject, if known.
    public static func rerankRequest(
        candidates: [String], before: String, after: String, subject: String?
    ) -> ModelRequest {
        var lines: [String] = []
        if let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            lines.append("Fach: \(subject)")
        }
        let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = after.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Text davor: \(before.isEmpty ? "–" : before)")
        lines.append("Text danach: \(after.isEmpty ? "–" : after)")
        lines.append("Lesarten:")
        for (index, candidate) in candidates.prefix(maximumRerankCount).enumerated() {
            lines.append("\(index + 1). \(candidate.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return ModelRequest(
            task: .wordSuggestions, system: PromptParts(fixed: rerankInstruction),
            messages: [.user(lines.joined(separator: "\n"))], reasoning: .off, maxOutputTokens: rerankMaxOutputTokens)
    }

    /// The model's ordering: a JSON object (`{"reihenfolge": [...]}` or another key holding a list) or a bare JSON
    /// list, also inside code fences or prose. Items may be the readings or their numbers (1-based). Only readings of
    /// `candidates` are kept (exact, else case-insensitive, in the spelling of `candidates`), each once; invented or
    /// changed words are dropped. Candidates the model left out are not appended. Anything malformed gives [].
    public static func parseRerank(_ text: String, candidates: [String]) -> [String] {
        guard case .success(let json) = StructuredOutput.extractJSON(from: text),
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        else { return [] }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let object = value as? [String: Any] {
            let keys = ["reihenfolge", "Reihenfolge", "lesarten", "Lesarten", "vorschlaege", "vorschläge", "order"]
            guard let array = keys.lazy.compactMap({ object[$0] as? [Any] }).first
                ?? object.values.lazy.compactMap({ $0 as? [Any] }).first
            else { return [] }
            items = array
        } else {
            return []
        }
        let offered = Array(candidates.prefix(maximumRerankCount))
        var result: [String] = []
        for item in items {
            var match: String?
            if let number = item as? Int ?? (item as? NSNumber)?.intValue, !(item is String) {
                if offered.indices.contains(number - 1) { match = offered[number - 1] }
            } else if let string = item as? String {
                // "2. Erde" or "Erde" → "Erde".
                var answer = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = answer.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) {
                    answer.removeSubrange(range)
                }
                match = offered.first { $0 == answer }
                    ?? offered.first { $0.lowercased() == answer.lowercased() }
            }
            if let match, !result.contains(match) { result.append(match) }
        }
        return result
    }

    /// Asks `provider` to reorder `candidates` and parses the answer (`parseRerank`). Provider errors are thrown.
    public static func rerank(
        candidates: [String], before: String, after: String, subject: String?, provider: any ModelProvider
    ) async throws -> [String] {
        let request = rerankRequest(candidates: candidates, before: before, after: after, subject: subject)
        let response = try await provider.respond(to: request)
        return parseRerank(response.text, candidates: candidates)
    }

    /// Asks `provider` and parses the answer (`parse`). Provider errors are thrown; a malformed answer gives [].
    public static func suggest(
        word: String, before: String, after: String, subject: String?, provider: any ModelProvider
    ) async throws -> [String] {
        let response = try await provider.respond(to: request(word: word, before: before, after: after, subject: subject))
        return parse(response.text, original: word)
    }
}
