import Foundation

/// Builds the stored original text (SPEC §2: verbatim, in the order of the
/// original, Markdown with formatting) from recognized lines and highlights.
///
/// Markup used:
/// - heading meaning on a whole line → `## …`, `LineBlockKind.title` → `# …`
/// - list items → `- …`
/// - bold → `**…**`, highlighter → `==…==`, underline / double underline → `<u>…</u>`
/// - illegible words/lines → `[unleserlich]`
/// Colors, circles, boxes etc. are not encoded in Markdown; they live in the
/// highlight entries with positions.
/// Consecutive lines are separated by a hard line break; a vertical gap larger
/// than 1.5 line heights starts a new paragraph.
public enum OriginalTextMarkdown {
    public static let illegibleMarker = "[unleserlich]"

    public static func build(lines: [RecognizedLine], highlights: [RecognizedHighlight]) -> String {
        let sorted = lines.sorted { $0.order < $1.order }
        var kindsByWord: [WordReference: Set<HighlightKind>] = [:]
        var headingLines: Set<UUID> = []
        for highlight in highlights {
            for ref in highlight.words { kindsByWord[ref, default: []].insert(highlight.kind) }
            if highlight.suggestedMeaning == .heading {
                headingLines.formUnion(highlight.words.map(\.lineID))
            }
        }

        var output = ""
        var previous: RecognizedLine?
        for line in sorted {
            if let previous {
                let gap = line.rect.minY - previous.rect.maxY
                let height = max(previous.rect.height, line.rect.height, 0.0001)
                output += gap > 1.5 * height ? "\n\n" : "  \n"
            }
            output += render(line, kindsByWord: kindsByWord, isHeading: headingLines.contains(line.id))
            previous = line
        }
        return output
    }

    static func render(_ line: RecognizedLine, kindsByWord: [WordReference: Set<HighlightKind>], isHeading: Bool) -> String {
        var prefix = ""
        if line.blockKind == .title {
            prefix = "# "
        } else if isHeading {
            prefix = "## "
        } else if line.blockKind == .listItem {
            prefix = "- "
        }

        if line.status == .illegible, !line.isUserCorrected {
            return prefix + illegibleMarker
        }
        // User corrections replace the text; word-level markup no longer applies reliably.
        if line.isUserCorrected || line.words.isEmpty {
            return prefix + escape(line.text, atLineStart: prefix.isEmpty)
        }

        // The stored text is verbatim; words (which may be missing for punctuation-only tokens or failed boxes)
        // only decide where markup goes.
        let tokens = LineTextAlignment.tokens(of: line.text, words: line.words)
        guard !tokens.isEmpty else { return prefix }

        func visibleKinds(_ wordIndex: Int) -> Set<HighlightKind> {
            (kindsByWord[WordReference(lineID: line.id, wordIndex: wordIndex)] ?? [])
                .intersection([.bold, .highlighter, .underline, .doubleUnderline])
        }
        // Unmatched tokens ("–", "/", "?") take the markup that both neighbouring words share; leading and
        // trailing ones stay plain.
        var kinds: [Set<HighlightKind>] = []
        for (i, token) in tokens.enumerated() {
            if let index = token.wordIndex {
                kinds.append(visibleKinds(index))
            } else if let before = tokens[..<i].last(where: { $0.wordIndex != nil })?.wordIndex,
                      let after = tokens[(i + 1)...].first(where: { $0.wordIndex != nil })?.wordIndex,
                      visibleKinds(before) == visibleKinds(after) {
                kinds.append(visibleKinds(before))
            } else {
                kinds.append([])
            }
        }

        var parts: [String] = []
        var runText: [String] = []
        var runKinds: Set<HighlightKind> = []

        func flush() {
            guard !runText.isEmpty else { return }
            parts.append(wrap(runText.joined(separator: " "), kinds: runKinds))
            runText = []
        }

        for (index, token) in tokens.enumerated() {
            let isIllegible = token.wordIndex.map { line.words[$0].status == .illegible } ?? false
            let text = isIllegible
                ? illegibleMarker
                : escape(token.text, atLineStart: prefix.isEmpty && index == 0)
            if kinds[index] != runKinds { flush(); runKinds = kinds[index] }
            runText.append(text)
        }
        flush()
        return prefix + parts.joined(separator: " ")
    }

    static func wrap(_ text: String, kinds: Set<HighlightKind>) -> String {
        var result = text
        if kinds.contains(.underline) || kinds.contains(.doubleUnderline) { result = "<u>\(result)</u>" }
        if kinds.contains(.highlighter) { result = "==\(result)==" }
        if kinds.contains(.bold) { result = "**\(result)**" }
        return result
    }

    /// Escapes characters that would otherwise be read as Markdown markup.
    static func escape(_ text: String, atLineStart: Bool) -> String {
        var result = ""
        for character in text {
            if "\\*_<>[]`=".contains(character) { result.append("\\") }
            result.append(character)
        }
        if atLineStart, let first = result.first, "#-+".contains(first) {
            result = "\\" + result
        }
        return result
    }
}

/// Relates the verbatim text of a line to its word entries. Words come from tokenizers and recognizers that drop
/// punctuation-only tokens or words whose box could not be determined, so the text is the source of truth and the
/// words are located inside it in order.
public enum LineTextAlignment {
    public struct Token: Hashable, Sendable {
        /// One whitespace-separated piece of the line text.
        public var text: String
        /// Index into the line's words if a word has exactly this text; nil for tokens without a word entry.
        public var wordIndex: Int?
    }

    /// Splits `text` at whitespace and attaches words in order (a word that does not occur is skipped).
    public static func tokens(of text: String, words: [RecognizedWord]) -> [Token] {
        var result: [Token] = []
        var next = 0
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let string = String(piece)
            var found: Int?
            if next < words.count {
                for j in next..<words.count where words[j].text == string { found = j; break }
            }
            if let found { next = found + 1 }
            result.append(Token(text: string, wordIndex: found))
        }
        return result
    }
}
