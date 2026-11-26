import StudyCore
import SwiftUI

/// Builds the visible and spoken representation of a recognized line with its highlights.
enum LineText {
    /// Line text with highlights shown visibly (bold, colored, underlined, marker background); the marked words
    /// (`PageWordReview.markedTokens`) are orange and underlined, nothing else of the line. Without `marked` (views
    /// that have no word review, e.g. the topic source panel) the recognizer's uncertain words are orange.
    static func attributed(
        line: RecognizedLine, highlights: [RecognizedHighlight], marked: [ReviewToken]? = nil
    ) -> AttributedString {
        var result = highlighted(line: line, highlights: highlights, legacyUncertain: marked == nil)
        for token in marked ?? [] {
            let start = line.text.distance(from: line.text.startIndex, to: token.range.lowerBound)
            let length = line.text.distance(from: token.range.lowerBound, to: token.range.upperBound)
            guard length > 0, start + length <= result.characters.count else { continue }
            let lower = result.characters.index(result.startIndex, offsetBy: start)
            let upper = result.characters.index(lower, offsetBy: length)
            result[lower..<upper].foregroundColor = .orange
            result[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: .orange)
        }
        return result
    }

    private static func highlighted(
        line: RecognizedLine, highlights: [RecognizedHighlight], legacyUncertain: Bool
    ) -> AttributedString {
        let own = highlights.filter { $0.applies(to: line) }
        let wordsJoined = line.words.map(\.text).joined(separator: " ")
        if !line.words.isEmpty, wordsJoined == line.text {
            var result = AttributedString()
            for (index, word) in line.words.enumerated() {
                var piece = AttributedString(word.text)
                if legacyUncertain, !line.isUserCorrected, word.needsReview { piece.foregroundColor = .orange }
                for highlight in own where highlight.words.contains(WordReference(lineID: line.id, wordIndex: index)) {
                    style(&piece, for: highlight)
                }
                result += piece
                if index < line.words.count - 1 { result += AttributedString(" ") }
            }
            return result
        }
        // The text was corrected (or has no word boxes): find the highlighted text inside the line.
        var result = AttributedString(line.text)
        for highlight in own where !highlight.text.isEmpty {
            if let range = result.range(of: highlight.text) {
                var slice = AttributedString(result[range])
                style(&slice, for: highlight)
                result.replaceSubrange(range, with: slice)
            }
        }
        return result
    }

    private static func style(_ piece: inout AttributedString, for highlight: RecognizedHighlight) {
        let color = highlight.displayColor
        switch highlight.kind {
        case .underline:
            piece.underlineStyle = Text.LineStyle(pattern: .solid, color: color)
        case .doubleUnderline:
            piece.underlineStyle = Text.LineStyle(pattern: .solid, color: color)
            piece.inlinePresentationIntent = .stronglyEmphasized
        case .bold, .uppercase:
            piece.inlinePresentationIntent = .stronglyEmphasized
        case .coloredPen:
            piece.foregroundColor = color
        case .highlighter:
            // Black text on the marker color stays readable in dark mode, too.
            piece.backgroundColor = color.opacity(0.7)
            piece.foregroundColor = .black
        case .boxed:
            piece.backgroundColor = Color.accentColor.opacity(0.22)
            piece.inlinePresentationIntent = .stronglyEmphasized
        case .circled:
            piece.backgroundColor = Color.purple.opacity(0.22)
            piece.inlinePresentationIntent = .stronglyEmphasized
        }
    }
}

extension RecognizedLine {
    /// VoiceOver label: "Zeile 3: Ort: Chloroplasten. Unsichere Wörter: Chlorophyl, grune. Hervorhebung: …".
    /// `markedWords` are the words of the word review (`PageWordReview.markedTokens`); `isIllegible` is an open
    /// illegible line.
    func spokenLabel(
        highlights: [RecognizedHighlight], markedWords: [String]? = nil, isIllegible: Bool = false
    ) -> String {
        var parts = ["Zeile \(order + 1): \(text.isEmpty ? "leer" : text)."]
        // Without word review info (nil) the recognizer's line status is spoken.
        let status = markedWords == nil
            ? displayStatus : displayStatus(hasMarks: !(markedWords ?? []).isEmpty, isIllegible: isIllegible)
        let markedWords = markedWords ?? []
        if !markedWords.isEmpty {
            parts.append((markedWords.count == 1 ? "Unsicheres Wort: " : "Unsichere Wörter: ") + markedWords.joined(separator: ", ") + ".")
        } else if status != .confident {
            let name = status.germanName
            parts.append(name.prefix(1).uppercased() + name.dropFirst() + ".")
        }
        let own = highlights.filter { $0.applies(to: self) }
        if !own.isEmpty {
            parts.append((own.count == 1 ? "Hervorhebung: " : "Hervorhebungen: ") + own.map(\.spokenDescription).joined(separator: "; ") + ".")
        }
        return parts.joined(separator: " ")
    }
}
