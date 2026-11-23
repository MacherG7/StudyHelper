import StudyCore
import SwiftUI

/// Builds the visible and spoken representation of a recognized line with its highlights.
enum LineText {
    /// Line text with highlights shown visibly (bold, colored, underlined, marker background) and
    /// uncertain words in orange.
    static func attributed(line: RecognizedLine, highlights: [RecognizedHighlight]) -> AttributedString {
        let own = highlights.filter { $0.applies(to: line) }
        let wordsJoined = line.words.map(\.text).joined(separator: " ")
        if !line.words.isEmpty, wordsJoined == line.text {
            var result = AttributedString()
            for (index, word) in line.words.enumerated() {
                var piece = AttributedString(word.text)
                if !line.isUserCorrected, word.needsReview { piece.foregroundColor = .orange }
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
    /// VoiceOver label: "Zeile 3: Ort: Chloroplasten. Unsicher. Hervorhebung: Chloroplasten, Textmarker, gelb."
    func spokenLabel(highlights: [RecognizedHighlight]) -> String {
        var parts = ["Zeile \(order + 1): \(text.isEmpty ? "leer" : text)."]
        let status = displayStatus
        if status != .confident {
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
