import Foundation
import Testing
@testable import StudyCore

@Suite("Geometrie")
struct GeometryTests {
    @Test("Umrechnung von unten-links nach oben-links und zurück")
    func bottomLeftRoundTrip() {
        let rect = NormalizedRect.fromBottomLeft(x: 100, y: 700, width: 200, height: 40, spaceWidth: 600, spaceHeight: 800)
        #expect(abs(rect.x - 100.0 / 600) < 1e-9)
        #expect(abs(rect.y - (1 - 740.0 / 800)) < 1e-9)
        let back = rect.toBottomLeft(spaceWidth: 600, spaceHeight: 800)
        #expect(abs(back.x - 100) < 1e-9 && abs(back.y - 700) < 1e-9)
        #expect(abs(back.width - 200) < 1e-9 && abs(back.height - 40) < 1e-9)
    }

    @Test("Schnitt, Vereinigung, IoU und Abdeckung")
    func overlapMeasures() {
        let a = NormalizedRect(x: 0, y: 0, width: 0.4, height: 0.2)
        let b = NormalizedRect(x: 0.2, y: 0, width: 0.4, height: 0.2)
        #expect(abs(a.intersection(b).area - 0.04) < 1e-9)
        #expect(abs(a.union(b).width - 0.6) < 1e-9)
        #expect(abs(a.iou(b) - 0.04 / 0.12) < 1e-9)
        #expect(abs(a.coverage(by: b) - 0.5) < 1e-9)
        #expect(a.intersection(NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)).isEmpty)
    }
}

@Suite("Farben")
struct ColorTests {
    @Test("Hex-Werte werden gelesen und geschrieben")
    func hexRoundTrip() throws {
        let color = try #require(RGBColor(hex: "#D32F2F"))
        #expect(color.hex == "#D32F2F")
        #expect(RGBColor(hex: "zzz") == nil)
    }

    @Test("Textmarker-Gelb und Schwarz werden erkannt")
    func classification() throws {
        #expect(try #require(RGBColor(hex: "#FFEB3B")).isYellowish)
        #expect(!(try #require(RGBColor(hex: "#1565C0")).isYellowish))
        #expect(RGBColor.black.isNearlyBlack)
    }
}

@Suite("Wortzerlegung")
struct TokenizerTests {
    @Test("Satzzeichen werden entfernt, Umlaute bleiben erhalten")
    func normalization() {
        let tokens = WordTokenizer.tokens(in: "Chlorophyll ist der „grüne“ Blattfarbstoff.")
        #expect(tokens.map(\.normalized) == ["chlorophyll", "ist", "der", "grüne", "blattfarbstoff"])
        #expect(tokens[3].folded == "grune")
    }

    @Test("ß wird beim Falten zu ss, Bindestrich-Wörter bleiben ein Wort")
    func foldingAndCompounds() {
        let tokens = WordTokenizer.tokens(in: "große Licht-Energie – Ort:")
        #expect(tokens.map(\.normalized) == ["große", "licht-energie", "ort"])
        #expect(tokens[0].folded == "grosse")
    }

    @Test("Zerlegte Umlaute (NFD) werden wie zusammengesetzte behandelt")
    func unicodeNormalization() {
        let decomposed = "O\u{0308}kosystem"
        #expect(WordTokenizer.normalize(decomposed) == WordTokenizer.normalize("Ökosystem"))
    }
}

@Suite("Wortabgleich")
struct AlignmentTests {
    @Test("Fehlerhafte Wörter werden ihrem Gegenstück zugeordnet")
    func substitutions() {
        let left = WordTokenizer.tokens(in: "Chlorophyll ist der grüne Blattfarbstoff")
        let right = WordTokenizer.tokens(in: "Chlorophyl ist der grune Blattfarbstoff")
        let steps = WordAlignment.align(left, right)
        #expect(steps == [
            .substitution(left: 0, right: 0), .match(left: 1, right: 1), .match(left: 2, right: 2),
            .substitution(left: 3, right: 3), .match(left: 4, right: 4),
        ])
    }

    @Test("Fehlende und zusätzliche Wörter werden erkannt")
    func insertionsAndDeletions() {
        let steps = WordAlignment.align(["a", "b", "c"], ["a", "c", "d"]) { $0 == $1 }
        #expect(steps.contains(.deletion(left: 1)))
        #expect(steps.contains(.insertion(right: 2)))
        #expect(steps.filter { if case .match = $0 { true } else { false } }.count == 2)
    }

    @Test("Zeichenabstand nach Levenshtein")
    func characterDistance() {
        #expect(WordAlignment.characterDistance("Mitochondrien", "Mitochondnen") == 2)
        #expect(WordAlignment.characterDistance("", "abc") == 3)
        #expect(WordAlignment.characterDistance("grüne", "grüne") == 0)
    }
}

@Suite("Originaltext als Markdown")
struct MarkdownTests {
    func line(_ text: String, order: Int, y: Double, status: ConfidenceStatus = .confident) -> RecognizedLine {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = parts.enumerated().map { index, part in
            RecognizedWord(text: part, rect: NormalizedRect(x: 0.1 + Double(index) * 0.1, y: y, width: 0.08, height: 0.03))
        }
        return RecognizedLine(text: text, rect: NormalizedRect(x: 0.1, y: y, width: 0.6, height: 0.03), words: words, status: status, order: order)
    }

    @Test("Überschrift, Textmarker und Unterstreichung werden ausgezeichnet")
    func markup() {
        let title = line("Fotosynthese", order: 0, y: 0.05)
        let body = line("Ort: Chloroplasten", order: 1, y: 0.09)
        let highlights = [
            RecognizedHighlight(text: "Fotosynthese", kind: .underline, rect: .zero, suggestedMeaning: .heading,
                                source: .goodnotesShape, words: [WordReference(lineID: title.id, wordIndex: 0)]),
            RecognizedHighlight(text: "Chloroplasten", kind: .highlighter, rect: .zero, suggestedMeaning: .important,
                                source: .goodnotesAnnotation, words: [WordReference(lineID: body.id, wordIndex: 1)]),
        ]
        let markdown = OriginalTextMarkdown.build(lines: [body, title], highlights: highlights)
        #expect(markdown == "## <u>Fotosynthese</u>  \nOrt: ==Chloroplasten==")
    }

    @Test("Großer Abstand beginnt einen neuen Absatz, Unleserliches wird markiert")
    func paragraphsAndIllegible() {
        let first = line("Erste Zeile", order: 0, y: 0.1)
        let second = line("xyz", order: 1, y: 0.3, status: .illegible)
        let markdown = OriginalTextMarkdown.build(lines: [first, second], highlights: [])
        #expect(markdown == "Erste Zeile\n\n[unleserlich]")
    }

    @Test("Markdown-Zeichen im Text werden maskiert")
    func escaping() {
        let markdown = OriginalTextMarkdown.build(lines: [line("# 2*3 = 6", order: 0, y: 0.1)], highlights: [])
        #expect(markdown == "\\# 2\\*3 \\= 6")
    }
}

@Suite("Originaltext als Markdown: wortgetreu auch ohne Wortrechtecke")
struct MarkdownVerbatimTests {
    func word(_ text: String, _ index: Int) -> RecognizedWord {
        RecognizedWord(text: text, rect: NormalizedRect(x: 0.1 + Double(index) * 0.1, y: 0.1, width: 0.08, height: 0.03))
    }

    func ref(_ line: RecognizedLine, _ index: Int) -> WordReference { WordReference(lineID: line.id, wordIndex: index) }

    @Test("Satzzeichen-Token ohne Wort (– / ≈ × ?) bleiben im Markdown erhalten")
    func punctuationOnlyTokens() {
        let tokens = ["a", "–", "b", "x", "/", "y", "≈", "3", "×", "4", "?"]
        let words = ["a", "b", "x", "y", "3", "4"].enumerated().map { word($1, $0) }
        let line = RecognizedLine(
            text: tokens.joined(separator: " "), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.03), words: words)
        #expect(OriginalTextMarkdown.build(lines: [line], highlights: []) == "a – b x / y ≈ 3 × 4 ?")
    }

    @Test("Markierung umschließt auch Satzzeichen-Token zwischen markierten Wörtern")
    func markupSpansPunctuation() {
        let line = RecognizedLine(
            text: "a – b ?", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.03),
            words: [word("a", 0), word("b", 1)])
        let underline = RecognizedHighlight(
            text: "a b", kind: .underline, rect: .zero, source: .goodnotesShape, words: [ref(line, 0), ref(line, 1)])
        #expect(OriginalTextMarkdown.build(lines: [line], highlights: [underline]) == "<u>a – b</u> ?")
    }

    @Test("Fehlt ein Wort in der Liste (Rechteck nicht bestimmbar), steht es trotzdem im Text und die Markierung sitzt richtig")
    func missingWordBox() {
        let line = RecognizedLine(
            text: "eins zwei drei", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.03),
            words: [word("eins", 0), word("drei", 1)])
        let highlight = RecognizedHighlight(
            text: "drei", kind: .highlighter, rect: .zero, source: .goodnotesAnnotation, words: [ref(line, 1)])
        #expect(OriginalTextMarkdown.build(lines: [line], highlights: [highlight]) == "eins zwei ==drei==")
    }

    @Test("Mehrfach vorkommende Wörter werden der Reihe nach zugeordnet")
    func repeatedWords() {
        let line = RecognizedLine(
            text: "ja – ja", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.03),
            words: [word("ja", 0), word("ja", 1)])
        let bold = RecognizedHighlight(text: "ja", kind: .bold, rect: .zero, source: .embeddedPDF, words: [ref(line, 1)])
        #expect(OriginalTextMarkdown.build(lines: [line], highlights: [bold]) == "ja – **ja**")
    }

    @Test("Zeile ohne einziges Wort wird trotzdem wortgetreu ausgegeben")
    func noWordsAtAll() {
        let line = RecognizedLine(text: "– / –", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03))
        #expect(OriginalTextMarkdown.build(lines: [line], highlights: []) == "– / –")
    }

    @Test("Unleserliche Zeile ohne Text ergibt die Marke, auch neben normalen Zeilen")
    func illegibleEmptyLine() {
        let first = RecognizedLine(text: "Erste", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03), words: [word("Erste", 0)], order: 0)
        let unreadable = RecognizedLine(
            text: "", rect: NormalizedRect(x: 0.1, y: 0.14, width: 0.2, height: 0.03), confidence: 0,
            status: .illegible, reviewReasons: [.unreadable], order: 1)
        #expect(OriginalTextMarkdown.build(lines: [first, unreadable], highlights: []) == "Erste  \n[unleserlich]")
    }

    @Test("Zuordnung von Text und Wörtern: Tokens ohne Wort haben keinen Index")
    func alignment() {
        let tokens = LineTextAlignment.tokens(of: "a – b", words: [word("a", 0), word("b", 1)])
        #expect(tokens.map(\.text) == ["a", "–", "b"])
        #expect(tokens.map(\.wordIndex) == [0, nil, 1])
    }
}

@Suite("Korrekturen bei Neuerkennung")
struct CorrectionMergerTests {
    @Test("Korrektur wird auf die leicht verschobene Zeile übertragen")
    func reapply() {
        let moved = RecognizedLine(
            text: "Chlorophyl ist grun", rect: NormalizedRect(x: 0.11, y: 0.2, width: 0.5, height: 0.03),
            words: [], status: .uncertain, reviewReasons: [.mismatchWithReducedPDF]
        )
        let other = RecognizedLine(text: "Andere Zeile", rect: NormalizedRect(x: 0.1, y: 0.5, width: 0.5, height: 0.03))
        let correction = LineCorrectionValue(
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.03),
            recognizedText: "Chlorophyl ist grun", correctedText: "Chlorophyll ist grün"
        )
        let outcome = CorrectionMerger.apply([correction], to: [other, moved])
        #expect(outcome.unmatched.isEmpty)
        #expect(outcome.lines[1].text == "Chlorophyll ist grün")
        #expect(outcome.lines[1].isUserCorrected)
        #expect(outcome.lines[1].status == .confident)
        #expect(!outcome.lines[1].needsReview)
        #expect(outcome.lines[0].text == "Andere Zeile")
    }

    @Test("Korrektur ohne passende Zeile wird gemeldet")
    func unmatched() {
        let correction = LineCorrectionValue(rect: NormalizedRect(x: 0.1, y: 0.9, width: 0.2, height: 0.02), recognizedText: "a", correctedText: "b")
        let outcome = CorrectionMerger.apply([correction], to: [RecognizedLine(text: "x", rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02))])
        #expect(outcome.unmatched == [correction])
    }
}
