import Foundation
import Testing

@testable import StudyCore

/// Spell checker with a fixed word list (exact spelling), like a dictionary that knows "Erde" but not "erde".
private struct FakeSpellChecker: SpellChecking {
    var words: Set<String>
    var guessTable: [String: [String]] = [:]

    func isKnown(_ word: String) -> Bool { words.contains(word) }
    func guesses(for word: String) -> [String] { guessTable[word] ?? [] }
}

private let checker = FakeSpellChecker(words: [
    "Die", "die", "Folgen", "der", "Eingriffe", "des", "Menschen", "in", "das", "System", "Erde", "kommt", "es",
    "zu", "Schäden", "Diese", "fasst", "man", "unter", "dem", "Begriff", "Umwelt", "Boden", "Bildung", "Prozesse",
    "Ressourcen", "Verbrauch", "Klima", "für", "verantwortlich", "Global", "Globalen", "Wandel", "und", "Mensch",
    "sich", "Teil", "Pflanzen", "Tiere", "Sphäre", "beschreibung", "von",
], guessTable: ["Klimg": ["Klima", "Kling"], "Eingrifte": ["Eingriffe"]])

private func line(
    _ text: String, y: Double = 0.1, order: Int = 0, status: ConfidenceStatus = .confident,
    reasons: [ReviewReason] = [], wordStatus: [Int: ConfidenceStatus] = [:], withWords: Bool = true,
    candidates: [String] = []
) -> RecognizedLine {
    let tokens = WordTokenizer.tokens(in: text)
    let words = withWords ? tokens.enumerated().map { i, token in
        RecognizedWord(
            text: token.original, rect: NormalizedRect(x: 0.1 * Double(i), y: y, width: 0.09, height: 0.03),
            status: wordStatus[i] ?? .confident)
    } : []
    return RecognizedLine(
        text: text, rect: NormalizedRect(x: 0, y: y, width: 1, height: 0.03), candidates: candidates, words: words,
        status: status, reviewReasons: reasons, order: order)
}

private func markedWords(_ lines: [RecognizedLine], terms: Set<String> = [],
                         isEmbedded: (RecognizedLine) -> Bool = { _ in false }) -> [String] {
    let result = WordReview.review(lines, checker: checker, terms: terms, isEmbedded: isEmbedded)
    return lines.sorted { $0.order < $1.order }.flatMap { line -> [String] in
        let tokens = WordReview.tokens(of: line)
        return (result.marks[line.id] ?? []).map { tokens[$0].core }
    }
}

@Suite("Wortprüfung: Wörter einer Zeile")
struct WordReviewTokenTests {
    @Test("Wörter passen zu RecognizedLine.words; Aufzählungszeichen sind kein Wort")
    func alignedWithWords() {
        let l = line("• Lithosphäre der Erde", wordStatus: [1: .uncertain])
        let tokens = WordReview.tokens(of: l)
        #expect(tokens.map(\.text) == ["Lithosphäre", "der", "Erde"])
        #expect(tokens.map(\.wordIndex) == [0, 1, 2])
        #expect(tokens[1].status == .uncertain)
        #expect(tokens[2].rect == l.words[2].rect)
        #expect(String(l.text[tokens[0].range]) == "Lithosphäre")
    }

    @Test("Ohne Wortrahmen: anteiliger Ausschnitt der Zeile")
    func proportionalRects() {
        let l = line("ab cd", withWords: false)
        let tokens = WordReview.tokens(of: l)
        #expect(tokens.count == 2)
        #expect(tokens[0].wordIndex == nil)
        #expect(abs(tokens[0].rect.minX - 0) < 1e-9 && abs(tokens[0].rect.width - 0.4) < 1e-9)
        #expect(abs(tokens[1].rect.minX - 0.6) < 1e-9)
    }

    @Test("Fehlende Wörter: der Rest wird der Reihe nach zugeordnet")
    func partialAlignment() {
        var l = line("Die Folgen der Eingriffe", wordStatus: [3: .uncertain])
        l.words.remove(at: 1)
        let tokens = WordReview.tokens(of: l)
        #expect(tokens.map(\.wordIndex) == [0, nil, 1, 2])
        #expect(tokens[3].status == .uncertain)
    }

    @Test("Satzzeichen und Anführungszeichen werden abgetrennt")
    func punctuation() {
        #expect(WordReview.splitPunctuation("„System") == ("„", "System", ""))
        #expect(WordReview.splitPunctuation("(medz)") == ("(", "medz", ")"))
        #expect(WordReview.splitPunctuation("Glo-") == ("", "Glo", "-"))
        #expect(WordReview.splitPunctuation("→").core.isEmpty)
    }
}

@Suite("Wortprüfung: Markierungen")
struct WordReviewMarkTests {
    @Test("Unsichere Wörter und unbekannte Wörter werden markiert, bekannte nicht")
    func basicMarks() {
        let lines = [
            line("Durch die Eingrifte des Menschen", order: 0, wordStatus: [4: .uncertain]),
            line("Diese tasst man unter dem Begriff", y: 0.2, order: 1),
        ]
        let result = WordReview.review(lines, checker: checker)
        #expect(result.marks[lines[0].id] == [0, 2, 4])
        #expect(result.marks[lines[1].id] == [1])
        #expect(result.reasons[WordReference(lineID: lines[0].id, wordIndex: 4)] == .recognizer)
        #expect(result.reasons[WordReference(lineID: lines[1].id, wordIndex: 1)] == .spelling)
        #expect(result.openCount == 4)
        #expect(WordReview.marks(for: lines, checker: checker) == result.marks)
    }

    @Test("Groß-/Kleinschreibung am Satzanfang und bei Nomen wird toleriert, Fachbegriffe gelten als bekannt")
    func caseAndTerms() {
        let l = line("umwelt Prozesse Lithosphäre Pedosphäre", order: 0)
        #expect(markedWords([l]) == ["Lithosphäre", "Pedosphäre"])
        #expect(markedWords([l], terms: ["lithosphäre", "PEDOSPHÄRE"]).isEmpty)
    }

    @Test("Kurze Wörter nur in der geschriebenen Form: „za“ ist nicht „Za“")
    func shortWordsExact() {
        let za = FakeSpellChecker(words: ["Za", "rückgängig"])
        let result = WordReview.review([line("rückgängig za")], checker: za)
        #expect(result.openCount == 1)
    }

    @Test("Zusammengesetzte Wörter aus bekannten Teilen gelten als bekannt")
    func compounds() {
        #expect(markedWords([line("Bodenbildungsprozesse Ressourcenverbrauch Teilberreichen")]) == ["Teilberreichen"])
        #expect(markedWords([line("Erde-Mensch Tiere/Pflanzen Erde-Klimg")]) == ["Erde-Klimg"])
    }

    @Test("Nie markiert: Zahlen, Satzzeichen, Pfeile, Aufzählungszeichen, einzelne Buchstaben, Abkürzungen, Ziffern, Großbuchstaben")
    func exclusions() {
        let l = line("1. 2) 3,5 → -> => • - a z.B. medz. sog. CO2 DNA USA (Tiere, Pflanzen)",
                     wordStatus: [0: .uncertain, 3: .uncertain])
        #expect(markedWords([l]).isEmpty)
    }

    @Test("Ausschlüsse gelten nur für die Rechtschreibung: ein unsicheres Kürzel bleibt markiert")
    func exclusionsOnlyForSpelling() {
        let l = line("CO2 DNA", wordStatus: [0: .uncertain])
        #expect(markedWords([l]) == ["CO2"])
    }

    @Test("Silbentrennung am Zeilenende: zusammengesetzt bekannt → beide Teile unmarkiert")
    func hyphenation() {
        let lines = [line("durch den Glo-", order: 0), line("balen Wandel", y: 0.2, order: 1)]
        let custom = FakeSpellChecker(words: ["durch", "den", "Globalen", "Wandel"])
        #expect(WordReview.review(lines, checker: custom).openCount == 0)
        // Unknown joined word with a short stem: unmarked; the continuation is checked on its own.
        let other = [line("durch den Glo-", order: 0), line("xyzen Wandel", y: 0.2, order: 1)]
        let result = WordReview.review(other, checker: custom)
        #expect(result.marks[other[0].id] == nil)
        #expect(result.marks[other[1].id] == [0])
        // A long unknown stem before a hyphen is marked.
        #expect(WordReview.review([line("Klimgxx-")], checker: custom).openCount == 1)
    }

    @Test("Eingebettete PDF-Zeilen werden nie markiert")
    func embedded() {
        let typed = line("Eingrifte tasst", wordStatus: [0: .uncertain])
        #expect(markedWords([typed], isEmbedded: { $0.id == typed.id }).isEmpty)
    }

    @Test("Leere unleserliche Zeilen zählen getrennt als je eine offene Stelle")
    func illegibleLines() {
        let empty = RecognizedLine(text: " ", rect: .zero, status: .illegible, order: 0)
        let word = line("Klimg", y: 0.2, order: 1)
        let result = WordReview.review([empty, word], checker: checker)
        #expect(result.illegibleLines == [empty.id])
        #expect(result.openCount == 2)
    }

    @Test("Nachgelesene Zeilen ohne Wortinformation: nur die Rechtschreibung zählt (D-020)")
    func reReadLineWithoutWords() {
        let reRead = line("Die Folgen der Eingrifte", status: .uncertain, reasons: [.reReadSeparately], withWords: false)
        #expect(markedWords([reRead]) == ["Eingrifte"])
        // Low confidence of the whole line: every word is doubted, except short known words (D-047).
        let low = line("Die Folgen", status: .uncertain, reasons: [.lowConfidence], withWords: false)
        #expect(markedWords([low]) == ["Folgen"])
    }
}

@Suite("Wortprüfung: Fehlalarme senken (D-047)")
struct WordReviewFalseAlarmTests {
    /// A line whose words carry their own status and reasons.
    private func doubted(_ text: String, order: Int = 0, _ doubts: [Int: (ConfidenceStatus, [ReviewReason])]) -> RecognizedLine {
        var l = line(text, y: 0.1 + 0.1 * Double(order), order: order)
        for (index, doubt) in doubts {
            l.words[index].status = doubt.0
            l.words[index].reviewReasons = doubt.1
        }
        return l
    }

    @Test("Häufige Wörter gelten als gewollt: zweimal auf der Seite oder auch auf einer anderen Seite des Fachs")
    func repeatedWords() {
        let lines = [
            line("Das Aralsee-Syndrom kommt", order: 0),
            line("Aralsee-Syndrom: Lithosphäre za za", y: 0.2, order: 1),
        ]
        // Default (used by the term suggestions): repeated words stay marked.
        #expect(markedWords(lines) == ["Aralsee-Syndrom", "Aralsee-Syndrom", "Lithosphäre", "za", "za"])

        let on = WordReview.review(lines, checker: checker, acceptsRepeatedWords: true)
        let tokens = lines.map { WordReview.tokens(of: $0) }
        let marked = lines.enumerated().flatMap { i, l in (on.marks[l.id] ?? []).map { tokens[i][$0].core } }
        // "za" repeats too, but short words never count as intended (a short misreading repeats easily).
        #expect(marked == ["Lithosphäre", "za", "za"])

        // Once here, once on another page of the subject.
        let other = WordReview.repetitionKeys(of: [line("Die Lithosphäre der Erde")])
        #expect(other.contains("lithosphäre") && !other.contains("die") && other.contains("erde"))
        let across = WordReview.review(lines, checker: checker, acceptsRepeatedWords: true, otherPageWords: other)
        #expect(across.openCount == 2)
        // Embedded text does not count.
        let typed = WordReview.repetitionKeys(of: [line("Lithosphäre")], isEmbedded: { _ in true })
        #expect(typed.isEmpty)
    }

    @Test("Bestätigbar sind Rechtschreibmarken und unsichere bekannte Wörter, nicht unsichere unbekannte")
    func confirmable() {
        let l = doubted("Menschen Klimg Eingrifte Begriff", [
            0: (.uncertain, [.variesBetweenPasses]), 2: (.uncertain, [.lowConfidence]), 3: (.illegible, [.unreadable]),
        ])
        let result = WordReview.review([l], checker: checker)
        let ref = { WordReference(lineID: l.id, wordIndex: $0) }
        #expect(result.marks[l.id] == [0, 1, 2, 3])
        #expect(result.reasons[ref(0)] == .recognizer && result.reasons[ref(1)] == .spelling)
        #expect(result.confirmable == [ref(0), ref(1)])

        let confirmed = result.removing(confirmed: [ref(0), ref(1), ref(2)])
        #expect(confirmed.marks[l.id] == [2, 3])
        #expect(confirmed.reasons[ref(0)] == nil && confirmed.openCount == 2)
        #expect(confirmed.confirmable.isEmpty)
        #expect(result.removing(confirmed: []) == result)
    }

    @Test("Kurze bekannte Wörter mit schwachem Zweifel (Mehrfacherkennung, Zeilensicherheit) bleiben unmarkiert")
    func weaklyDoubtedShortWords() {
        let short = FakeSpellChecker(words: ["baut", "ab", "Das", "es"])
        let l = doubted("baut ab Das Gle es", [
            1: (.uncertain, [.variesBetweenPasses]), 2: (.uncertain, [.lowConfidence]),
            3: (.uncertain, [.variesBetweenPasses]), 4: (.uncertain, [.mismatchWithReducedPDF]),
        ])
        let result = WordReview.review([l], checker: short)
        // "Gle" is no word; "es" differs from the reduced PDF, a doubt about the word itself.
        #expect(result.marks[l.id] == [3, 4])
        #expect(result.confirmable == [WordReference(lineID: l.id, wordIndex: 4)])
    }

    @Test("Bekannte Wörter ohne Kontext: Wörterbuch, Fachbegriffe, Bindestrich-Teile; keine Kürzel oder Ziffern")
    func knownWords() {
        #expect(WordReview.isKnownWord("„Erde,", checker: checker))
        #expect(WordReview.isKnownWord("Boden-Klima", checker: checker))
        #expect(WordReview.isKnownWord("Pedosphäre", checker: checker, terms: ["pedosphäre"]))
        #expect(!WordReview.isKnownWord("Erdeii", checker: checker))
        #expect(!WordReview.isKnownWord("CO2", checker: checker))
        #expect(!WordReview.isKnownWord("DNA", checker: checker))
        #expect(!WordReview.isKnownWord("Erde-x", checker: checker))
    }
}

@Suite("Wortprüfung: Korrekturen einzelner Wörter")
struct WordReviewCorrectionTests {
    @Test("Ganze Zeile korrigiert: nichts mehr markiert")
    func wholeLineCorrection() {
        let original = line("Durch die Eingrifte tasst", wordStatus: [0: .uncertain])
        let value = LineCorrectionValue(rect: original.rect, recognizedText: original.text,
                                        correctedText: "Durch die Eingrifte tasst")
        let corrected = CorrectionMerger.apply([value], to: [original]).lines[0]
        #expect(corrected.isUserCorrected)
        #expect(corrected.words.allSatisfy { $0.status == .confident && !$0.isUserConfirmed })
        #expect(WordReview.review([corrected], checker: checker).openCount == 0)
    }

    @Test("Ein Wort korrigiert: nur dieses Wort ist erledigt, die anderen bleiben markiert")
    func wordCorrection() {
        let original = line("Durch die Eingrifte tasst", wordStatus: [0: .uncertain, 2: .uncertain])
        let text = WordReview.replacing(wordIndex: 2, in: original, with: "Eingriffe")
        #expect(CorrectionMerger.changedWordIndexes(from: original.text, to: text) == [2])
        let value = LineCorrectionValue(rect: original.rect, recognizedText: original.text, correctedText: text,
                                        confirmedWordIndexes: [2])
        let corrected = CorrectionMerger.apply([value], to: [original]).lines[0]
        #expect(corrected.text == "Durch die Eingriffe tasst")
        #expect(corrected.isUserCorrected && !corrected.needsReview)
        #expect(corrected.words[2].text == "Eingriffe" && corrected.words[2].isUserConfirmed)
        #expect(corrected.words[2].status == .confident)
        #expect(corrected.words[0].status == .uncertain && !corrected.words[0].isUserConfirmed)
        let result = WordReview.review([corrected], checker: checker)
        #expect(result.marks[corrected.id] == [0, 3])
        #expect(result.reasons[WordReference(lineID: corrected.id, wordIndex: 3)] == .spelling)
    }

    @Test("Ein Wort bestätigt (gleicher Text): es bleibt unmarkiert, auch bei unbekannter Schreibung")
    func wordConfirmation() {
        let original = line("Klimg Erde")
        let value = LineCorrectionValue(rect: original.rect, recognizedText: original.text, correctedText: original.text,
                                        confirmedWordIndexes: [0])
        let corrected = CorrectionMerger.apply([value], to: [original]).lines[0]
        #expect(WordReview.review([corrected], checker: checker).openCount == 0)
    }

    @Test("Wortkorrektur nach neuer Erkennung mit anderer Wortanzahl: korrigierter Text gilt, übrige Markierungen bleiben")
    func wordCorrectionOtherWordCount() {
        let fresh = line("Durch dieEingrifte tasst", wordStatus: [0: .uncertain])
        let value = LineCorrectionValue(rect: fresh.rect, recognizedText: "Durch die Eingrifte tasst",
                                        correctedText: "Durch die Eingriffe tasst", confirmedWordIndexes: [2])
        let corrected = CorrectionMerger.apply([value], to: [fresh]).lines[0]
        #expect(corrected.text == "Durch die Eingriffe tasst")
        #expect(corrected.words.map(\.text) == ["Durch", "die", "Eingriffe", "tasst"])
        #expect(corrected.words[2].isUserConfirmed && corrected.words[0].status == .uncertain)
        // "die" and "Eingriffe" share the box of "dieEingrifte".
        #expect(abs(corrected.words[1].rect.minX - fresh.words[1].rect.minX) < 1e-9)
        #expect(abs(corrected.words[2].rect.maxX - fresh.words[1].rect.maxX) < 1e-9)
        #expect(WordReview.review([corrected], checker: checker).marks[corrected.id] == [0, 3])
    }

    @Test("Neue Erkennung: nicht bestätigte Wörter behalten neuen Text und neuen Status, bestätigte den Text des Nutzers")
    func reRecognitionKeepsNewReading() {
        let fresh = line("Durch die Eingrifte fasst", wordStatus: [2: .uncertain, 3: .uncertain])
        let value = LineCorrectionValue(rect: fresh.rect, recognizedText: "Durch die Eingrifte tasst",
                                        correctedText: "Durch die Eingriffe tasst", confirmedWordIndexes: [2])
        let corrected = CorrectionMerger.apply([value], to: [fresh]).lines[0]
        #expect(corrected.text == "Durch die Eingriffe fasst")
        #expect(corrected.words[2].text == "Eingriffe" && corrected.words[2].isUserConfirmed)
        #expect(corrected.words[3].text == "fasst" && corrected.words[3].status == .uncertain)
        let result = WordReview.review([corrected], checker: checker)
        // "Durch" is not in the test dictionary.
        #expect(result.marks[corrected.id] == [0, 3])
        #expect(result.reasons[WordReference(lineID: corrected.id, wordIndex: 3)] == .recognizer)
    }

    @Test("Fehlende Wortrahmen: Wörter werden aus dem Text neu gebildet, die übrigen Markierungen bleiben")
    func missingWordBoxes() {
        var original = line("Durch die Eingrifte tasst", wordStatus: [0: .uncertain, 2: .uncertain])
        original.words.remove(at: 1)
        let text = WordReview.replacing(wordIndex: 2, in: original, with: "Eingriffe")
        let value = LineCorrectionValue(rect: original.rect, recognizedText: original.text, correctedText: text,
                                        confirmedWordIndexes: [2])
        let corrected = CorrectionMerger.apply([value], to: [original]).lines[0]
        #expect(corrected.words.map(\.text) == ["Durch", "die", "Eingriffe", "tasst"])
        #expect(corrected.words[2].isUserConfirmed && corrected.words[2].rect == original.words[1].rect)
        #expect(corrected.words[0].status == .uncertain)
        #expect(WordReview.review([corrected], checker: checker).marks[corrected.id] == [0, 3])
    }

    @Test("Wortkorrektur übersteht eine neue Erkennung: neue Unsicherheiten der anderen Wörter bleiben")
    func wordCorrectionSurvivesReRecognition() {
        let fresh = line("Durch die Eingrifte tasst", wordStatus: [1: .uncertain, 2: .uncertain])
        let value = LineCorrectionValue(rect: fresh.rect, recognizedText: fresh.text,
                                        correctedText: "Durch die Eingriffe tasst", confirmedWordIndexes: [2])
        let corrected = CorrectionMerger.apply([value], to: [fresh]).lines[0]
        #expect(WordReview.review([corrected], checker: checker).marks[corrected.id] == [0, 1, 3])
    }

    @Test("Kodierung: Wortindizes und Wortbestätigung nur wenn gesetzt; alte Blobs bleiben lesbar")
    func encoding() throws {
        let plain = LineCorrectionValue(rect: .zero, recognizedText: "a", correctedText: "b")
        #expect(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("confirmedWordIndexes") == false)
        let word = LineCorrectionValue(rect: .zero, recognizedText: "a", correctedText: "b", confirmedWordIndexes: [1, 3])
        #expect(try JSONDecoder().decode(LineCorrectionValue.self, from: JSONEncoder().encode(word)) == word)
        #expect(word.isWordLevel && !plain.isWordLevel)

        var recognized = RecognizedWord(text: "x", rect: .zero)
        #expect(String(decoding: try JSONEncoder().encode(recognized), as: UTF8.self).contains("userConfirmed") == false)
        recognized.isUserConfirmed = true
        #expect(try JSONDecoder().decode(RecognizedWord.self, from: JSONEncoder().encode(recognized)).isUserConfirmed)
        let legacy = #"{"text":"x","rect":{"x":0,"y":0,"width":1,"height":1}}"#
        #expect(try JSONDecoder().decode(RecognizedWord.self, from: Data(legacy.utf8)).isUserConfirmed == false)
    }
}

@Suite("Wortprüfung: Ersetzen, Kontext und Vorschläge")
struct WordReviewSuggestionTests {
    @Test("Ersetzen behält Satzzeichen des Originals, außer der Vorschlag bringt eigene mit")
    func replacing() {
        let l = line("Das „Sistem Erdel“ ist (medz).")
        #expect(WordReview.replacing(wordIndex: 1, in: l, with: "System") == "Das „System Erdel“ ist (medz).")
        #expect(WordReview.replacing(wordIndex: 2, in: l, with: "Erde") == "Das „Sistem Erde“ ist (medz).")
        #expect(WordReview.replacing(wordIndex: 4, in: l, with: "med.") == "Das „Sistem Erdel“ ist (med.")
        #expect(WordReview.replacing(wordIndex: 4, in: l, with: "(med.)") == "Das „Sistem Erdel“ ist (med.)")
        #expect(WordReview.replacing(wordIndex: 3, in: l, with: "") == "Das „Sistem Erdel“ (medz).")
        #expect(WordReview.replacing(wordIndex: 9, in: l, with: "x") == l.text)
    }

    @Test("Kontext über Zeilengrenzen in Lesereihenfolge")
    func context() {
        let a = line("eins zwei drei", order: 0)
        let b = line("vier fünf", y: 0.2, order: 1)
        let c = line("sechs sieben acht", y: 0.3, order: 2)
        let context = WordReview.context(of: 1, in: b.id, lines: [c, a, b], radius: 2)
        #expect(context.before == "drei vier")
        #expect(context.after == "sechs sieben")
        let wide = WordReview.context(of: 0, in: a.id, lines: [a, b, c])
        #expect(wide.before.isEmpty && wide.after == "zwei drei vier fünf sechs sieben acht")
        #expect(WordReview.context(of: 7, in: a.id, lines: [a]) == ("", ""))
    }

    @Test("Alternativen der Zeile: nur gleiche Wortanzahl, ohne das Wort selbst")
    func lineCandidates() {
        let l = line("für Klimg verantwortlich", candidates: [
            "für Klima verantwortlich", "für Kling, verantwortlich", "fürKlima verantwortlich", "für Klimg verantwortlich",
        ])
        #expect(WordReview.lineCandidateWords(line: l, wordIndex: 1) == ["Klima", "Kling"])
        #expect(WordReview.lineCandidateWords(line: l, wordIndex: 5).isEmpty)
    }

    @Test("Ähnliche Fachbegriffe mit kleinem Abstand, nächste zuerst")
    func similarTerms() {
        let terms: Set<String> = ["Lithosphäre", "Atmosphäre", "Hydrosphäre", "Klima"]
        #expect(WordReview.similarTerms(word: "Lithosphare", terms: terms) == ["Lithosphäre"])
        #expect(WordReview.similarTerms(word: "lihtosphäre,", terms: terms) == ["Lithosphäre"])
        #expect(WordReview.similarTerms(word: "Klimg", terms: terms) == ["Klima"])
        #expect(WordReview.similarTerms(word: "Erde", terms: terms).isEmpty)
        #expect(WordReview.editDistance(Array("ab"), Array("ba")) == 1)
        #expect(WordReview.editDistance(Array("Kitten"), Array("Sitting")) == 3)
    }

    @Test("Vorschläge zusammenführen: Reihenfolge, ohne Duplikate und Original, begrenzt")
    func merge() {
        let merged = WordReview.mergeSuggestions(
            [["Klima", " "], ["klima", "Klimg", "Kling"], ["Klimt", "Klimm"]], original: "Klimg", limit: 3)
        #expect(merged == ["Klima", "Kling", "Klimt"])
        #expect(WordReview.mergeSuggestions([["Umwelt"]], original: "umwelt") == ["Umwelt"])
    }

    @Test("Lokale Vorschläge: Fachbegriffe, Alternativen der Erkennung, Rechtschreibprüfung")
    func localSuggestions() {
        let l = line("für Klimg verantwortlich", candidates: ["für Kling verantwortlich"])
        let suggestions = WordReview.localSuggestions(line: l, wordIndex: 1, checker: checker, terms: ["Klimt", "Klimax"])
        #expect(suggestions == ["Klimt", "Kling", "Klima"])
    }
}

@Suite("Wortprüfung: Herkunft der Zeilen")
struct WordReviewOriginTests {
    @Test("Nur PDF-Text und Textfelder gelten als exakt; Erkanntes und Zeilen ohne Herkunft werden geprüft")
    func isEmbedded() {
        var l = line("Eingrifte tasst", wordStatus: [0: .uncertain])
        #expect(!WordReview.isEmbedded(l))
        #expect(markedWords([l], isEmbedded: WordReview.isEmbedded) == ["Eingrifte", "tasst"])
        for origin in [LineOrigin.pdfText, .freeText] {
            l.origin = origin
            #expect(WordReview.isEmbedded(l))
            #expect(WordReview.review([l], checker: checker).openCount == 0)
        }
        for origin in [LineOrigin.recognizer, .ai] {
            l.origin = origin
            #expect(!WordReview.isEmbedded(l))
        }
    }

    @Test("Handschrift mit Sicherheit 1 wird trotzdem geprüft")
    func confidentHandwriting() {
        var l = line("Eingrifte tasst")
        l.confidence = 1
        l.origin = .recognizer
        #expect(WordReview.review([l], checker: checker).openCount == 2)
    }

    @Test("Kodierung: Herkunft nur wenn gesetzt; unbekannte Werte und alte Blobs werden ohne Herkunft gelesen")
    func encoding() throws {
        let plain = RecognizedLine(text: "a", rect: .zero)
        #expect(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("origin") == false)
        let typed = RecognizedLine(text: "a", rect: .zero, origin: .pdfText)
        #expect(try JSONDecoder().decode(RecognizedLine.self, from: JSONEncoder().encode(typed)).origin == .pdfText)
        let future = #"{"text":"a","rect":{"x":0,"y":0,"width":1,"height":1},"origin":"hologram"}"#
        #expect(try JSONDecoder().decode(RecognizedLine.self, from: Data(future.utf8)).origin == nil)
        let wrongType = #"{"text":"a","rect":{"x":0,"y":0,"width":1,"height":1},"origin":3}"#
        #expect(try JSONDecoder().decode(RecognizedLine.self, from: Data(wrongType.utf8)).origin == nil)
    }
}

/// Counts the questions to the wrapped checker.
private final class CountingChecker: SpellChecking, @unchecked Sendable {
    let base: FakeSpellChecker
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    init(_ base: FakeSpellChecker) { self.base = base }

    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
    var distinct: Int { lock.withLock { counts.count } }

    func isKnown(_ word: String) -> Bool {
        lock.withLock { counts[word, default: 0] += 1 }
        return base.isKnown(word)
    }

    func guesses(for word: String) -> [String] { base.guesses(for: word) }
}

@Suite("Wortprüfung: Aufwand")
struct WordReviewPerformanceTests {
    /// 300 lines of 10 words with repetitions, unknown words and long unknown compounds.
    private func page() -> [RecognizedLine] {
        let vocabulary = ["Die", "Folgen", "der", "Eingrifte", "Bodenbildungsprozesse", "Ressourcenverbrauch",
                          "Teilberreichen", "Xyzqwertzuiopasdfghjklyxcvbnmq", "Klimg", "Menschen", "tasst", "Erde"]
        return (0..<300).map { row in
            let words = (0..<10).map { column in
                vocabulary[(row * 7 + column * 3) % vocabulary.count] + (column == 9 ? "\(row % 40)" : "")
            }
            return line(words.joined(separator: " "), y: Double(row) / 300, order: row)
        }
    }

    @Test("300 Zeilen × 10 Wörter: begrenzte Anfragen, mit Zwischenspeicher beim zweiten Mal keine")
    func boundedCheckerCalls() {
        let lines = page()
        let counting = CountingChecker(checker)
        let cached = CachingSpellChecker(counting)
        let first = WordReview.review(lines, checker: cached)
        let afterFirst = counting.total
        // Every distinct string is asked once; compounds are split a bounded number of times per word.
        #expect(afterFirst == counting.distinct)
        #expect(afterFirst < 1_000)
        let second = WordReview.review(lines, checker: cached)
        #expect(second == first)
        #expect(counting.total == afterFirst)
    }

    @Test("Ohne eigenen Zwischenspeicher: jede Schreibweise höchstens einmal pro Prüfung gefragt")
    func perReviewCache() {
        let counting = CountingChecker(checker)
        _ = WordReview.review(page(), checker: counting)
        #expect(counting.total == counting.distinct)
    }

    @Test("Zwischenspeicher ändert keine Ergebnisse")
    func sameResults() {
        let lines = [line("Bodenbildungsprozesse Ressourcenverbrauch Teilberreichen Klimg Erde")]
        #expect(WordReview.review(lines, checker: CachingSpellChecker(checker)) == WordReview.review(lines, checker: checker))
        #expect(markedWords(lines) == ["Teilberreichen", "Klimg"])
    }
}
