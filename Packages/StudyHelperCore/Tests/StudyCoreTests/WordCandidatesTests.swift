import Foundation
import Testing

@testable import StudyCore

/// Spell checker with a fixed word list (exact spelling) and fixed guesses.
private struct ListSpellChecker: SpellChecking {
    var words: Set<String>
    var guessTable: [String: [String]] = [:]

    func isKnown(_ word: String) -> Bool { words.contains(word) }
    func guesses(for word: String) -> [String] { guessTable[word] ?? [] }
}

private let checker = ListSpellChecker(words: [
    "Die", "die", "Eingriffe", "Eingriff", "des", "Menschen", "in", "das", "System", "Erde", "Erdo", "fasst", "passt",
    "man", "Atmosphäre", "Hydrosphäre", "Biosphäre", "und", "der", "Lithosphäre", "auch", "Lauch", "Wandel",
    "Globaler", "Baumwollplantage", "zu", "Folgen", "Klima", "Wasser", "sich",
], guessTable: ["Wandeli": ["Wandel", "Wandeln"], "Klimg": ["Klima"]])

private func vision(_ word: [String], _ line: [String] = [], wordOff: [String] = [], lineOff: [String] = [])
    -> [WordCandidateRanking.VisionList]
{
    [
        .init(candidates: word, weight: 1, crop: .word), .init(candidates: wordOff, weight: 0.7, crop: .word),
        .init(candidates: line, weight: 1, crop: .line), .init(candidates: lineOff, weight: 0.7, crop: .line),
    ]
}

@Suite("Wortvorschläge: Rangfolge aus mehreren Lesungen")
struct WordCandidateRankingTests {
    @Test("Übereinstimmung von Wort- und Zeilenausschnitt und bekannte Wörter gewinnen; das geschriebene Wort fehlt")
    func consensus() {
        let ranked = WordCandidateRanking.rank(
            written: "Eingrifte",
            vision: vision(["Eingrife", "Eingriffe", "Eingrifte"], ["Eingriffe", "Eingrift"], wordOff: ["Eingrite"]),
            local: .init(spelling: ["Eingriffe"]), checker: checker)
        #expect(ranked.first?.text == "Eingriffe")
        #expect(ranked.first?.sources == [.vision, .spelling])
        #expect(ranked.first?.score == 1)
        #expect(!ranked.contains { $0.text == "Eingrifte" })
        #expect(ranked.count <= 8)
        #expect(zip(ranked, ranked.dropFirst()).allSatisfy { $0.score >= $1.score })
    }

    @Test("Ohne Lesungen bleiben die lokalen Vorschläge: Fachbegriffe vor Zeilenalternativen vor Rechtschreibung")
    func localOnly() {
        let ranked = WordCandidateRanking.rank(
            written: "Klimg", vision: [],
            local: .init(terms: ["Klimax"], lineAlternatives: ["Kling"], spelling: ["Klima"]), checker: checker)
        #expect(ranked.map(\.text) == ["Klimax", "Kling", "Klima"])
        #expect(ranked.map(\.sources) == [[.term], [.lineAlternative], [.spelling]])
    }

    @Test("Unsinn fällt weg: fremde Schrift, zusammengeklebte Wörter, Satzzeichen im Wort, einzelne Buchstaben")
    func garbage() {
        #expect(WordCandidateRanking.clean("„Erde,") == "Erde")
        #expect(WordCandidateRanking.clean("Kleine-Tiger-Syndrom") == "Kleine-Tiger-Syndrom")
        #expect(WordCandidateRanking.clean("Pedosphäręąś") == nil)
        #expect(WordCandidateRanking.clean("Земля") == nil)
        #expect(WordCandidateRanking.clean("SchädiEingrifte") == nil)
        #expect(WordCandidateRanking.clean("nTeil,coiti") == nil)
        #expect(WordCandidateRanking.clean("zwei Wörter") == nil)
        #expect(WordCandidateRanking.clean("1234") == nil)
        let ranked = WordCandidateRanking.rank(
            written: "an", vision: vision(["a", "am", "n"]), local: .init(), checker: checker)
        #expect(ranked.map(\.text) == ["am"])
    }

    @Test("Nähe-Filter: weit entfernte Lesung nur eines Ausschnitts fällt weg, vom anderen Ausschnitt gestützt bleibt sie")
    func closenessFilter() {
        // "Baumwollplantage" is a neighbouring word in the word crop: far from the written word, no support.
        let neighbour = WordCandidateRanking.rank(
            written: "wusserbauliche",
            vision: vision(["wasserbauliche", "Baumwollplantage"], ["wasserbauliche"]),
            local: .init(lineAlternatives: ["Baumwolle"]), checker: checker)
        #expect(neighbour.map(\.text) == ["wasserbauliche"])

        // Far from the written word, but the line crop reads almost the same: kept.
        let supported = WordCandidateRanking.rank(
            written: "dereiderungen", vision: vision(["Veränderungen"], ["Veranderungen"]), local: .init(),
            checker: checker)
        #expect(WordCandidateRanking.distance("Veränderungen", "dereiderungen") <= 0.5)
        let farWritten = WordCandidateRanking.rank(
            written: "xyzq", vision: vision(["Menschen"], ["Menschon"]), local: .init(spelling: ["Mensch"]),
            checker: checker)
        #expect(farWritten.map(\.text) == ["Menschen", "Mensch", "Menschon"])
        #expect(supported.first?.text == "Veränderungen")
    }

    @Test("Lesungen aus Wort- und Zeilenausschnitt werden dem Wort zugeordnet")
    func readingsToWord() {
        // Word crop: the word lies in the middle; a fragment of the neighbour stands left of it.
        let word = TextReading(observations: [
            .init(minX: 0.0, width: 0.15, candidates: ["ie"]),
            .init(minX: 0.2, width: 0.75, candidates: ["Eingriffe", "die Eingrifte", "Eingrife."]),
        ])
        #expect(WordCandidateRanking.wordCropCandidates(word, wordSpan: 0.25...0.9)
                == ["Eingriffe", "Eingrifte", "Eingrife"])
        #expect(WordCandidateRanking.wordCropCandidates(word, wordSpan: 0.96...0.99).isEmpty)

        // Line crop: two observations; the word at index 2 of the recognized line.
        let line = TextReading(observations: [
            .init(minX: 0.55, width: 0.4, candidates: ["des Menschen"]),
            .init(minX: 0.0, width: 0.5, candidates: ["Durch die Eingriffe", "Durch die Eingrife", "Durch Eingriff"]),
        ])
        #expect(WordCandidateRanking.lineCropCandidates(line, line: "Durch die Eingrifte des Menschen", wordIndex: 2)
                == ["Eingriffe", "Eingrife", "Eingriff"])
    }
}

@Suite("Wortvorschläge: Umordnen durch das Modell")
struct WordCandidateRerankTests {
    private let candidates = [
        WordCandidate(text: "Lauch", score: 1, sources: [.vision]),
        WordCandidate(text: "auch", score: 0.8, sources: [.vision, .spelling]),
        WordCandidate(text: "Cauch", score: 0.5, sources: [.vision]),
        WordCandidate(text: "lach", score: 0.2, sources: [.spelling]),
    ]

    @Test("Nur die gegebenen Kandidaten zählen; erfundene Wörter werden ignoriert, Fehlende folgen")
    func applyOrder() {
        let result = WordCandidateRanking.applyOrder(["Bauch", "AUCH", "auch", "Lauch"], to: candidates, count: 3)
        #expect(result.map(\.text) == ["auch", "Lauch", "Cauch", "lach"])
        #expect(result[0].sources == [.vision, .spelling, .model])
        #expect(result[1].sources == [.vision, .model])
        #expect(result[2].sources == [.vision])
        #expect(result.map(\.score) == [1, 0.8, 0.5, 0.2])

        #expect(WordCandidateRanking.applyOrder(["Bauch", "Rauch"], to: candidates, count: 3) == candidates)
        #expect(WordCandidateRanking.applyOrder([], to: candidates, count: 3) == candidates)
        // "lach" is outside the offered prefix.
        #expect(WordCandidateRanking.applyOrder(["lach"], to: candidates, count: 3) == candidates)
    }

    @Test("Umordnen nur an den angebotenen Stellen; die übrigen bleiben, Bewertungen fallend")
    func applyOrderAtPositions() {
        let result = WordCandidateRanking.applyOrder(["lach", "Lauch"], to: candidates, positions: [0, 3])
        #expect(result.map(\.text) == ["lach", "auch", "Cauch", "Lauch"])
        #expect(result.map(\.score) == [1, 0.8, 0.5, 0.2])
        #expect(result[0].sources.contains(.model) && result[3].sources.contains(.model))
        #expect(!result[1].sources.contains(.model))
    }

    @Test("Das Modell wird nur bei knapper Wahl zwischen bekannten Wörtern gefragt")
    func positions() {
        #expect(WordCandidateRanking.rerankPositions(candidates, checker: checker, terms: []) == [0, 1])
        // Clear consensus: the second word is far behind.
        var clear = candidates
        clear[1].score = 0.3
        #expect(WordCandidateRanking.rerankPositions(clear, checker: checker, terms: []).isEmpty)
        // Only non-words close to the best: nothing to ask.
        let nonWords = [
            WordCandidate(text: "Teilbereichen", score: 1, sources: [.vision]),
            WordCandidate(text: "leilberreichen", score: 0.93, sources: [.vision]),
        ]
        #expect(WordCandidateRanking.rerankPositions(nonWords, checker: checker, terms: []).isEmpty)
        // Subject terms count as known.
        let term = [nonWords[0], WordCandidate(text: "Teilerreichen", score: 0.9, sources: [.vision])]
        #expect(WordCandidateRanking.rerankPositions(term, checker: checker, terms: ["Teilerreichen"]) == [0, 1])
    }

    @Test("Zeitlimit: ohne Antwort rechtzeitig kommt nil, auch wenn die Aufgabe Abbruch ignoriert")
    func timeout() async {
        let fast = await WordCandidateRanking.value(within: 2) { ["auch"] }
        #expect(fast == ["auch"])

        // nil proves that the call did not wait for the late answer.
        let slow = await WordCandidateRanking.value(within: 0.2) { () -> [String] in
            // Ignores cancellation on purpose.
            let until = Date().addingTimeInterval(8)
            while Date() < until { try? await Task.sleep(nanoseconds: 50_000_000) }
            return ["zu spät"]
        }
        #expect(slow == nil)
    }

    @Test("Zeitlimit: Abbruch der aufrufenden Aufgabe beendet das Warten")
    func cancellation() async {
        let task = Task {
            await WordCandidateRanking.value(within: 10) { () -> [String] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return ["x"]
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        // nil (not the answer after 5 s, not the 10 s timeout's nil after the answer) proves the cancellation.
        let result = await task.value
        #expect(result == nil)
    }
}

@Suite("Wortrahmen auf das Zeilenband begrenzt")
struct WordGeometryTests {
    private func line(_ y: Double, height: Double = 0.03, x: Double = 0.1, width: Double = 0.8, text: String = "Text")
        -> RecognizedLine
    {
        RecognizedLine(text: text, rect: NormalizedRect(x: x, y: y, width: width, height: height))
    }

    @Test("Hohe Wortrahmen werden auf die Mitte ± halben Zeilenabstand gekürzt")
    func clamped() {
        let above = line(0.08), current = line(0.10), below = line(0.125)
        let word = NormalizedRect(x: 0.3, y: 0.095, width: 0.1, height: 0.04)
        let band = WordGeometry.bandRect(for: word, line: current, pageLines: [above, current, below])
        // Centre 0.115; rows above at 0.095 (distance 0.02), below at 0.14 (distance 0.025).
        #expect(abs(band.minY - 0.105) < 1e-9)
        #expect(abs(band.maxY - 0.1275) < 1e-9)
        #expect(band.minX == word.minX && band.width == word.width)
    }

    @Test("Ohne Nachbarzeilen, bei Zeilen daneben oder in derselben Zeile bleibt der Rahmen")
    func unchanged() {
        let current = line(0.10)
        let word = NormalizedRect(x: 0.3, y: 0.095, width: 0.1, height: 0.04)
        #expect(WordGeometry.bandRect(for: word, line: current, pageLines: [current]) == word)
        let beside = line(0.08, x: 0.7, width: 0.2)          // other column
        let sameRow = line(0.102, x: 0.35, width: 0.1)        // split line on the same row
        let empty = line(0.08, text: " ")
        #expect(WordGeometry.bandRect(for: word, line: current, pageLines: [current, beside, sameRow, empty]) == word)
        // A small word box inside the band stays as it is.
        let small = NormalizedRect(x: 0.3, y: 0.108, width: 0.1, height: 0.01)
        #expect(WordGeometry.bandRect(for: small, line: current, pageLines: [line(0.08), current, line(0.125)]) == small)
    }

    @Test("Strichband: ±0,7 Zeilenhöhen, zur Nachbarzeile höchstens 80 % des Abstands")
    func strokeBand() {
        let current = line(0.10), below = line(0.12)
        let band = WordGeometry.strokeBand(
            centre: 0.115, height: 0.03, xRange: 0.2...0.4, line: current, pageLines: [current, below])
        #expect(abs(band.lowerBound - (0.115 - 0.021)) < 1e-9)
        #expect(abs(band.upperBound - (0.115 + 0.016)) < 1e-9)
    }
}

@Suite("Fachbegriff-Vorschläge")
struct TermSuggestionsTests {
    private func line(_ text: String, order: Int, height: Double = 0.02, kind: LineBlockKind? = nil) -> RecognizedLine {
        RecognizedLine(
            text: text, rect: NormalizedRect(x: 0.1, y: 0.05 * Double(order), width: 0.8, height: height),
            blockKind: kind, order: order, origin: .recognizer)
    }

    @Test("Unbekannte Wörter, die sich wiederholen oder in Überschriften stehen; bekannte und einmalige nicht")
    func candidates() {
        let lines = [
            line("Anthroposphäre", order: 0, kind: .title),
            line("Die Pedosphäre und die Erde", order: 1),
            line("Pedosphäre und Lithosphäre", order: 2),
            line("Das Aralsee-Syndrom", order: 3),
            line("System Erde xqzt", order: 4),
            line("Kryosphäre", order: 5, height: 0.04),
            line("Wandeli", order: 6, height: 0.05),
            line("der Kryosphäre und", order: 7),
        ]
        let terms = TermSuggestions.candidates(lines: lines, checker: checker, known: ["Kryosphäre"])
        #expect(terms == ["Pedosphäre", "Anthroposphäre"])
    }

    @Test("Höchstens 12, ohne Doppelte (Groß/klein), häufigste Schreibweise")
    func limitAndSpelling() {
        var lines: [RecognizedLine] = []
        for i in 0..<14 {
            let word = "Fachwort" + String(UnicodeScalar(UInt8(97 + i)))
            lines.append(line("\(word) und \(word)", order: i))
        }
        lines.append(line("pedosphäre Pedosphäre Pedosphäre", order: 20))
        let terms = TermSuggestions.candidates(lines: lines, checker: checker, known: [])
        #expect(terms.count == 12)
        #expect(terms.first == "Pedosphäre")
        #expect(!terms.contains("pedosphäre"))
    }

    @Test("Einmalige Lesefehler bekannter Wörter sind keine Fachbegriffe, Beugungen und Bindestrich-Varianten schon")
    func misreading() {
        #expect(TermSuggestions.isMisreading("Wandeli", of: "Wandel"))
        #expect(TermSuggestions.isMisreading("Eritred", of: "Eritrea"))
        #expect(!TermSuggestions.isMisreading("Anthroposphäre", of: "Anthroposphären"))
        #expect(!TermSuggestions.isMisreading("Aralsee-Syndrom", of: "Aralsee Syndrom"))
        #expect(!TermSuggestions.isMisreading("Hydro", of: "Hydra"))
    }
}

@Suite("Wortprüfung: Abkürzungen und Trennstriche")
struct WordReviewFragmentTests {
    private func marked(_ texts: [String], terms: Set<String> = []) -> [String] {
        let lines = texts.enumerated().map { index, text in
            RecognizedLine(
                text: text, rect: NormalizedRect(x: 0, y: 0.05 * Double(index), width: 1, height: 0.03), order: index,
                origin: .recognizer)
        }
        let result = WordReview.review(lines, checker: checker, terms: terms)
        return lines.flatMap { line in (result.marks[line.id] ?? []).map { WordReview.tokens(of: line)[$0].core } }
    }

    @Test("Kurze Abkürzungen mit Punkt (bis 5 Buchstaben) sind keine Fehler, längere unbekannte Wörter schon")
    func abbreviations() {
        #expect(marked(["(medz.) etz. Abb. bspw. Erde"]).isEmpty)
        #expect(marked(["Klimgxy."]) == ["Klimgxy"])
        #expect(marked(["xqz1."]).isEmpty)
    }

    @Test("Trennstriche in Aufzählungen und am Zeilenende mit späterer Fortsetzung sind keine Fehler")
    func hyphenFragments() {
        #expect(marked(["- Atmo-, Hydro- und Biosphäre durchdringen sich"]) == ["durchdringen"])
        #expect(marked(["Atmo- und Lithosphäre"]).isEmpty)
        // The continuation stands two lines further down (reading order of a narrow column).
        #expect(marked(["die Atmo-", "Erde", "sphäre und"]) == ["sphäre"])
        // Nothing completes it.
        #expect(marked(["die Atmo-", "Erde"]) == ["Atmo"])
    }
}

@Suite("Wortvorschläge: bestätigte Lesung und plausible Kandidaten (D-047)")
struct WordCandidateConfirmationTests {
    @Test("Bestätigt: alle Lesungen lesen das geschriebene Wort zuerst (Groß/klein und Satzzeichen egal)")
    func confirmed() {
        #expect(WordCandidateRanking.isConfirmed(
            written: "Lithosphäre", vision: vision(["Lithosphäre", "Lithophäre"], ["Lithosphäre"],
                                                    wordOff: ["Lithosphäre"], lineOff: ["Lithosphäre"]),
            checker: checker))
        #expect(WordCandidateRanking.isConfirmed(
            written: "Aralsee-Syndrom:", vision: vision(["Aralsee-Syndrom"], ["Aralsee-syndrom", "Aralsee-syndrem"]),
            checker: checker))
        // An unknown variant leads the word crops, the line crops read the written word: still the consensus.
        #expect(WordCandidateRanking.isConfirmed(
            written: "Hydro", vision: vision(["Hydros", "Hydro-s", "Hydro"], ["Hydro"], wordOff: ["Hydros"],
                                              lineOff: ["Hydro"]),
            checker: checker))
    }

    @Test("Nicht bestätigt: eine Lesung liest zuerst ein anderes bekanntes Wort, nur eine Lesung oder keine Mehrheit")
    func notConfirmed() {
        // "tasst": three readings repeat the misreading, the line crop with language correction reads "fasst".
        #expect(!WordCandidateRanking.isConfirmed(
            written: "tasst", vision: vision(["tasst", "tast"], ["fasst", "tasst"], wordOff: ["tasst"],
                                              lineOff: ["tasst"]),
            checker: checker))
        #expect(!WordCandidateRanking.isConfirmed(
            written: "Klimg", vision: vision(["Klima", "Klina"], ["Klimg"], wordOff: ["Klima"], lineOff: ["Klimg"]),
            checker: checker))
        // Only one reading has it first.
        #expect(!WordCandidateRanking.isConfirmed(
            written: "Pedosphäre", vision: vision(["Pedosphäre"]), checker: checker))
        // Two readings have it first, but an unknown reading is stronger overall.
        #expect(!WordCandidateRanking.isConfirmed(
            written: "Gle", vision: vision(["Glo", "Gle"], ["Gle", "Glo"], wordOff: ["Glo"], lineOff: ["Gle", "Glo"]),
            checker: checker))
        #expect(!WordCandidateRanking.isConfirmed(written: "", vision: vision(["a"]), checker: checker))
        #expect(!WordCandidateRanking.isConfirmed(written: "Erde", vision: [], checker: checker))
    }

    @Test("Plausibel: bekannte Wörter, unbekannt nur die beste Lesung mit zwei Lesungen; höchstens 5")
    func plausible() {
        let candidates = [
            WordCandidate(text: "Pedosphäre", score: 1, sources: [.vision], readings: 2),
            WordCandidate(text: "Pedophäre", score: 0.8, sources: [.vision], readings: 1),
            WordCandidate(text: "Erde", score: 0.5, sources: [.spelling]),
        ]
        #expect(WordCandidateRanking.plausible(candidates, checker: checker).map(\.text) == ["Pedosphäre", "Erde"])
        #expect(WordCandidateRanking.plausible(candidates, checker: checker, allowsUnknownBest: false).map(\.text)
                == ["Erde"])
        var weak = candidates
        weak[0].readings = 1
        #expect(WordCandidateRanking.plausible(weak, checker: checker).map(\.text) == ["Erde"])
        let mutations = [
            WordCandidate(text: "Erde", score: 1, sources: [.vision], readings: 2),
            WordCandidate(text: "Erdei", score: 0.9, sources: [.vision], readings: 2),
            WordCandidate(text: "Erdeii", score: 0.5, sources: [.vision], readings: 1),
        ]
        #expect(WordCandidateRanking.plausible(mutations, checker: checker).map(\.text) == ["Erde"])
        let many = ["Erde", "Wandel", "Klima", "Wasser", "Folgen", "Menschen"].map {
            WordCandidate(text: $0, score: 1, sources: [.spelling])
        }
        #expect(WordCandidateRanking.plausible(many, checker: checker).count == 5)
        #expect(WordCandidateRanking.plausible([], checker: checker).isEmpty)
    }

    @Test("Ist das geschriebene Wort selbst ein Wort, zählen nur Kandidaten mit einer Lesung der Tinte")
    func knownWritten() {
        let shortWords = ListSpellChecker(words: ["ab", "am", "an", "db"])
        let candidates = [
            WordCandidate(text: "am", score: 1, sources: [.spelling]),
            WordCandidate(text: "an", score: 0.8, sources: [.vision, .spelling], readings: 1),
        ]
        #expect(WordCandidateRanking.plausible(candidates, written: "ab", checker: shortWords).map(\.text) == ["an"])
        #expect(WordCandidateRanking.plausible(candidates, written: "xb", checker: shortWords).map(\.text)
                == ["am", "an"])
    }

    @Test("Die Rangfolge zählt die Lesungen je Kandidat")
    func readingsCount() {
        let ranked = WordCandidateRanking.rank(
            written: "Klimg", vision: vision(["Klima", "Klina"], ["Klima"], wordOff: ["Klima"]),
            local: .init(spelling: ["Kling"]), checker: checker)
        #expect(ranked.first?.text == "Klima" && ranked.first?.readings == 3)
        #expect(ranked.first { $0.text == "Kling" }?.readings == 0)
    }
}
