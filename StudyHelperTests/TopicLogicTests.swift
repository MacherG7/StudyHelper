import Foundation
import StudyCore
import StudyData
import SwiftData
import Testing
@testable import StudyHelper

@Suite("Themen: Übernahme aus dem Text, Vorschläge, Tabellen, Quellenverweise")
@MainActor
struct TopicLogicTests {
    private let sourceID = UUID()
    private let digitizationID = UUID()

    private func line(_ text: String, order: Int, y: Double, words: Bool = true) -> RecognizedLine {
        let rect = NormalizedRect(x: 0.1, y: y, width: 0.6, height: 0.05)
        let parts = text.split(separator: " ").map(String.init)
        let width = rect.width / Double(max(parts.count, 1))
        let recognized = words
            ? parts.enumerated().map { i, part in
                RecognizedWord(text: part, rect: NormalizedRect(x: rect.x + Double(i) * width, y: y, width: width * 0.9, height: rect.height))
            }
            : []
        return RecognizedLine(text: text, rect: rect, words: recognized, order: order)
    }

    private func selection(
        _ lines: [RecognizedLine], words: [UUID: Set<Int>] = [:], highlights: [RecognizedHighlight] = []
    ) -> SourceSelection {
        SourceSelection(
            sourceID: sourceID, digitizationID: digitizationID, digitizationVersion: 2,
            lines: lines, words: words, highlights: highlights)
    }

    // MARK: Übernahme

    @Test("Mehrere Zeilen werden in Lesereihenfolge zu einem Text verbunden")
    func textOfSeveralLines() {
        let a = line("Chlorophyll absorbiert", order: 0, y: 0.1)
        let b = line("rotes und blaues Licht", order: 1, y: 0.2)
        #expect(selection([b, a]).text == "Chlorophyll absorbiert rotes und blaues Licht")
    }

    @Test("Der Quellenverweis enthält Zeilen, Rechteck-Vereinigung und Version")
    func referenceOfSelection() throws {
        let a = line("Eins", order: 0, y: 0.1)
        let b = line("Zwei", order: 1, y: 0.3)
        let reference = selection([b, a]).reference
        #expect(reference.sourceID == sourceID)
        #expect(reference.lineIDs == [a.id, b.id])
        #expect(reference.digitizationID == digitizationID)
        #expect(reference.digitizationVersion == 2)
        let rect = try #require(reference.rect)
        #expect(rect.minY == 0.1)
        #expect(abs(rect.maxY - 0.35) < 1e-9)
    }

    @Test("Einzelne Wörter ergeben Text und Rechteck nur dieser Wörter")
    func wordSelection() throws {
        let l = line("Ort ist Chloroplast", order: 0, y: 0.1)
        let chosen = selection([l], words: [l.id: [0, 2]])
        #expect(chosen.text == "Ort Chloroplast")
        let rect = try #require(chosen.rect)
        #expect(rect.minX == l.words[0].rect.minX)
        #expect(abs(rect.maxX - l.words[2].rect.maxX) < 1e-9)
        #expect(chosen.reference.lineIDs == [l.id])
    }

    @Test("Nach einer Textkorrektur werden die alten Wortkästen nicht mehr benutzt")
    func staleWordsAreIgnored() {
        var l = line("Chlorophyl ist grün", order: 0, y: 0.1)
        l.text = "Chlorophyll ist grün"
        #expect(!l.hasReliableWords)
        #expect(selection([l], words: [l.id: [0]]).text == "Chlorophyll ist grün")
    }

    @Test("Die Hervorhebung des übernommenen Textes wird mitgespeichert")
    func entryHighlightIsTaken() {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let marker = RecognizedHighlight(
            text: "Chloroplasten", kind: .highlighter, color: RGBColor(hex: "#FFEB3B"), rect: l.rect,
            source: .goodnotesAnnotation, words: [WordReference(lineID: l.id, wordIndex: 1)])
        let other = RecognizedHighlight(text: "x", kind: .underline, rect: .zero, source: .user, words: [WordReference(lineID: UUID(), wordIndex: 0)])
        let highlight = selection([l], highlights: [other, marker]).entryHighlight
        #expect(highlight?.kind == .highlighter)
        #expect(highlight?.color == RGBColor(hex: "#FFEB3B"))
    }

    @Test("Ohne Hervorhebung im Original gibt es keine Hervorhebungsangabe")
    func noHighlight() {
        let l = line("Nur Text", order: 0, y: 0.1)
        #expect(selection([l]).entryHighlight == nil)
    }

    @Test("Bei Wortauswahl zählen nur Hervorhebungen der gewählten Wörter")
    func highlightOfChosenWordsOnly() {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let marker = RecognizedHighlight(
            text: "Chloroplasten", kind: .circled, rect: l.rect, source: .goodnotesShape,
            words: [WordReference(lineID: l.id, wordIndex: 1)])
        #expect(selection([l], words: [l.id: [0]], highlights: [marker]).entryHighlight == nil)
        #expect(selection([l], words: [l.id: [1]], highlights: [marker]).entryHighlight?.kind == .circled)
    }

    @Test("Der Entwurf als Kernaussage trägt Text, Verweis und Hervorhebung; leere Auswahl ergibt keinen")
    func draftKeyStatement() throws {
        let l = line("Licht liefert die Energie", order: 0, y: 0.1)
        let draft = try #require(selection([l]).draft(kind: .keyStatement))
        #expect(draft.text == "Licht liefert die Energie")
        #expect(draft.term.isEmpty)
        #expect(draft.reference.lineIDs == [l.id])
        #expect(selection([]).draft(kind: .keyStatement) == nil)
        #expect(selection([line("  ", order: 0, y: 0.1, words: false)]).draft(kind: .keyStatement) == nil)
    }

    @Test("Ein Begriff wird am Doppelpunkt in Begriff und Definition geteilt")
    func termSplitting() throws {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let draft = try #require(selection([l]).draft(kind: .term))
        #expect(draft.term == "Ort")
        #expect(draft.definition == "Chloroplasten")
        #expect(draft.text.isEmpty)
        #expect(TermSplitter.split(lines: ["Chlorophyll ist der grüne Blattfarbstoff"], text: "Chlorophyll ist der grüne Blattfarbstoff")
            == ("Chlorophyll", "der grüne Blattfarbstoff"))
        #expect(TermSplitter.split(lines: ["Stroma", "Flüssigkeit im Chloroplasten"], text: "Stroma Flüssigkeit im Chloroplasten")
            == ("Stroma", "Flüssigkeit im Chloroplasten"))
        #expect(TermSplitter.split(lines: ["Thylakoid"], text: "Thylakoid") == ("Thylakoid", ""))
    }

    // MARK: Vorschläge

    private func highlight(
        _ text: String, kind: HighlightKind, meaning: HighlightMeaning? = nil, in l: RecognizedLine, word: Int
    ) -> RecognizedHighlight {
        RecognizedHighlight(
            text: text, kind: kind, rect: l.rect, suggestedMeaning: meaning, source: .goodnotesShape,
            words: [WordReference(lineID: l.id, wordIndex: word)])
    }

    private func suggestions(
        _ lines: [RecognizedLine], _ highlights: [RecognizedHighlight], existing: Set<String> = []
    ) -> [HighlightSuggestion] {
        HighlightSuggestions.make(
            lines: lines, highlights: highlights, sourceID: sourceID, digitizationID: digitizationID,
            digitizationVersion: 1, existing: existing)
    }

    @Test("Überschriften, Begriffe und Wichtiges werden als Vorschläge erkannt")
    func suggestionRoles() {
        let heading = line("Fotosynthese", order: 0, y: 0.1)
        let term = line("Ort: Chloroplasten", order: 1, y: 0.2)
        let rule = line("6 CO2 + 6 H2O", order: 2, y: 0.3)
        let important = line("Licht liefert die Energie", order: 3, y: 0.4)
        let result = suggestions(
            [heading, term, rule, important],
            [
                highlight("Licht liefert die Energie", kind: .highlighter, meaning: .important, in: important, word: 0),
                highlight("Fotosynthese", kind: .underline, meaning: .heading, in: heading, word: 0),
                highlight("Chloroplasten", kind: .circled, in: term, word: 1),
                highlight("6 CO2 + 6 H2O", kind: .boxed, meaning: .formula, in: rule, word: 0),
            ])
        #expect(result.map(\.text) == ["Fotosynthese", "Chloroplasten", "6 CO2 + 6 H2O", "Licht liefert die Energie"])
        #expect(result.map(\.role) == [.heading, .term, .rule, .statement])
        #expect(result.map(\.role.entryKind) == [.keyStatement, .term, .rule, .keyStatement])
    }

    @Test("Ein umkreister Satz ist eine Aussage, ein umkreistes Wort ein Begriff")
    func circledSentenceIsStatement() {
        let l = line("Pflanzen bilden Zucker aus Licht", order: 0, y: 0.1)
        let sentence = highlight("Pflanzen bilden Zucker aus Licht", kind: .circled, in: l, word: 0)
        let word = highlight("Zucker", kind: .circled, in: l, word: 3)
        #expect(HighlightSuggestions.role(for: sentence, text: sentence.text) == .statement)
        #expect(HighlightSuggestions.role(for: word, text: word.text) == .term)
    }

    @Test("Unterstrichen ohne Bedeutung: Überschrift oder Begriff entscheidet der Nutzer")
    func underlinedWithoutMeaningIsOpen() {
        let l = line("Pflanzen bilden Zucker aus Licht", order: 0, y: 0.1)
        let word = highlight("Zucker", kind: .underline, in: l, word: 2)
        let whole = highlight("Pflanzen bilden Zucker aus Licht", kind: .doubleUnderline, in: l, word: 0)
        #expect(HighlightSuggestions.role(for: word, text: word.text) == .open)
        #expect(HighlightSuggestions.role(for: whole, text: whole.text) == .open)
        let chosen = highlight("Zucker", kind: .underline, meaning: .heading, in: l, word: 2)
        #expect(HighlightSuggestions.role(for: chosen, text: chosen.text) == .heading)
    }

    @Test("Vorschlag: Quellenverweis auf die Wortkästen, Definition aus dem Rest der Zeile")
    func suggestionReferenceAndDefinition() throws {
        let l = line("Ort: Chloroplasten", order: 4, y: 0.2)
        let h = highlight("Ort", kind: .circled, meaning: .term, in: l, word: 0)
        let suggestion = try #require(suggestions([l], [h]).first)
        #expect(suggestion.reference.lineIDs == [l.id])
        #expect(suggestion.reference.rect == l.words[0].rect)
        #expect(suggestion.reference.digitizationVersion == 1)
        #expect(suggestion.definitionHint == "Chloroplasten")
        let draft = suggestion.draft()
        #expect(draft.kind == .term)
        #expect(draft.term == "Ort")
        #expect(draft.definition == "Chloroplasten")
        #expect(draft.highlight?.kind == .circled)
        #expect(suggestion.draft(as: .keyStatement).text == "Ort")
    }

    @Test("Schon übernommene und leere Hervorhebungen werden nicht vorgeschlagen")
    func suggestionsSkipExistingAndEmpty() {
        let l = line("Fotosynthese Chlorophyll", order: 0, y: 0.1)
        let a = highlight("Fotosynthese", kind: .underline, meaning: .heading, in: l, word: 0)
        let b = highlight("Chlorophyll", kind: .circled, in: l, word: 1)
        let empty = highlight("  ", kind: .circled, in: l, word: 1)
        let duplicate = highlight("chlorophyll ", kind: .underline, in: l, word: 1)
        let existing: Set<String> = [HighlightSuggestions.normalized("FOTOSYNTHESE")]
        #expect(suggestions([l], [a, b, empty, duplicate], existing: existing).map(\.text) == ["Chlorophyll"])
    }

    // MARK: Tabellen

    @Test("Tabellen: Zeilen und Spalten hinzufügen und entfernen, Zellen setzen")
    func tableEditing() {
        var table = TableData.starter
        #expect(table.columnCount == 2)
        table.setHeader("Phase", at: 0)
        table.setHeader("Ort", at: 1)
        table.setCell("Lichtreaktion", row: 0, column: 0)
        table.setCell("Thylakoid", row: 0, column: 1)
        table.addRow()
        table.addColumn(header: "Produkt")
        #expect(table.headers == ["Phase", "Ort", "Produkt"])
        #expect(table.rows == [["Lichtreaktion", "Thylakoid", ""], ["", "", ""]])
        table.setCell("ATP", row: 0, column: 2)
        table.removeColumn(at: 1)
        #expect(table.headers == ["Phase", "Produkt"])
        #expect(table.rows[0] == ["Lichtreaktion", "ATP"])
        table.removeRow(at: 1)
        #expect(table.rows.count == 1)
        table.removeRow(at: 7)
        table.setCell("ignoriert", row: 5, column: 0)
        #expect(table.rows.count == 1)
    }

    @Test("Tabellen: die letzte Spalte bleibt, schiefe Zeilen werden geglättet, Leerheit wird erkannt")
    func tableNormalizeAndBlank() {
        var single = TableData(headers: ["A"], rows: [["x"]])
        single.removeColumn(at: 0)
        #expect(single.columnCount == 1)
        var ragged = TableData(headers: ["A"], rows: [["x", "y", "z"], []])
        ragged.normalize()
        #expect(ragged.headers == ["A", "", ""])
        #expect(ragged.rows == [["x", "y", "z"], ["", "", ""]])
        #expect(TableData.starter.isBlank)
        #expect(!TableData(headers: ["", "x"], rows: []).isBlank)
    }

    // MARK: Reihenfolge

    @Test("Verschieben innerhalb einer Art lässt die Plätze der anderen Arten unberührt")
    func orderingWithinKind() {
        let ids = (0..<5).map { _ in UUID() }
        let all: [(id: UUID, kind: EntryKind)] = [
            (ids[0], .keyStatement), (ids[1], .term), (ids[2], .keyStatement), (ids[3], .term), (ids[4], .keyStatement),
        ]
        // Last key statement to the front of the key statements.
        let up = EntryOrdering.reordered(all: all, kind: .keyStatement, from: IndexSet(integer: 2), to: 0)
        #expect(up == [ids[4], ids[1], ids[0], ids[3], ids[2]])
        // First term behind the second term.
        let down = EntryOrdering.reordered(all: all, kind: .term, from: IndexSet(integer: 0), to: 2)
        #expect(down == [ids[0], ids[3], ids[2], ids[1], ids[4]])
    }

    // MARK: Quellenverweise

    @Test("Die Markierung folgt den Zeilen und bevorzugt den gespeicherten, engeren Bereich")
    func markResolution() throws {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.2)
        let narrow = l.words[1].rect
        let whole = SourceReference(sourceID: sourceID, lineIDs: [l.id], rect: l.rect)
        #expect(ReferenceResolver.mark(for: whole, resolvedLines: [l]) == ResolvedMark(sourceID: sourceID, rect: l.rect, isStale: false))
        let words = SourceReference(sourceID: sourceID, lineIDs: [l.id], rect: narrow)
        #expect(ReferenceResolver.mark(for: words, resolvedLines: [l]).rect == narrow)
        // The line moved: follow the line.
        var moved = l
        moved.rect = NormalizedRect(x: 0.1, y: 0.6, width: 0.6, height: 0.05)
        #expect(ReferenceResolver.mark(for: words, resolvedLines: [moved]).rect == moved.rect)
    }

    @Test("Fehlen Zeilen, gilt der gespeicherte Bereich und der Eintrag ist als veraltet markiert")
    func markFallback() {
        let stored = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05)
        let reference = SourceReference(sourceID: sourceID, lineIDs: [UUID()], rect: stored)
        let mark = ReferenceResolver.mark(for: reference, resolvedLines: [])
        #expect(mark.rect == stored)
        #expect(mark.isStale)
        let none = ReferenceResolver.mark(for: SourceReference(sourceID: sourceID, lineIDs: [UUID()]), resolvedLines: [])
        #expect(none.rect == nil)
        // A reference without lines and without a rect has nothing to show, but is not "stale".
        #expect(!ReferenceResolver.mark(for: SourceReference(sourceID: sourceID), resolvedLines: []).isStale)
    }

    // MARK: Anzeige

    @Test("Der Sprechtext nennt Art, Inhalt, Herkunft, Hervorhebung und Quelle")
    func spokenLabel() {
        let entry = TopicEntry(
            kind: .keyStatement, text: "Ort: Chloroplasten", origin: .original,
            highlight: EntryHighlight(kind: .highlighter, color: RGBColor(hex: "#FFEB3B")))
        let label = entry.spokenLabel(sourceText: "Quelle: Notiz.pdf · Seite 1")
        #expect(label.contains("Kernaussage: Ort: Chloroplasten"))
        #expect(label.contains("Herkunft: Original aus dem Lernstoff"))
        #expect(label.contains("Im Original hervorgehoben: Textmarker, gelb"))
        #expect(label.contains("Quelle: Notiz.pdf · Seite 1"))
        let own = TopicEntry(kind: .term, term: "Stroma", definition: "Flüssigkeit", origin: .user)
        #expect(own.spokenLabel(sourceText: nil).contains("Begriff: Stroma: Flüssigkeit"))
        #expect(own.spokenLabel(sourceText: nil).contains("von dir eingegeben"))
        let ai = TopicEntry(kind: .example, text: "…", origin: .aiSupplement, supplementStatus: .proposed)
        #expect(ai.spokenLabel(sourceText: nil).contains("KI-Ergänzung, nicht aus dem Lernstoff"))
    }

    // MARK: Zusammenspiel mit dem Speicher

    @Test("Eine übernommene Zeile wird als Original mit auflösbarem Verweis gespeichert")
    func storedTakeoverResolves() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let source = try #require(subject.imports.first?.sortedSources.first)
        let digitization = try #require(source.currentDigitization)
        let target = try #require(digitization.lines.first { $0.order == 1 })

        let draft = try #require(SourceSelection(
            sourceID: source.id, digitizationID: digitization.id, digitizationVersion: digitization.versionNumber,
            lines: [target], highlights: digitization.highlights).draft(kind: .keyStatement))
        let topic = try repository.createTopic(in: subject, title: "Fotosynthese")
        let entry = try repository.addEntry(
            to: topic, kind: draft.kind, text: draft.text, origin: .original,
            sourceReferences: [draft.reference], highlight: draft.highlight)

        #expect(entry.origin == .original)
        #expect(entry.text == UITestSeeder.lineTexts[1])
        #expect(entry.highlight?.kind == .highlighter)
        let reference = try #require(entry.sourceReferences.first)
        let resolved = try repository.lines(for: reference)
        #expect(resolved.map(\.id) == [target.id])
        #expect(ReferenceResolver.mark(for: reference, resolvedLines: resolved).rect == target.rect)
        #expect(try repository.affectedTopics(bySourceID: source.id, lineIDs: [target.id]).map(\.id) == [topic.id])
    }

    @Test("Der Seeder mit Themen legt ein unbestätigtes Thema mit einem Original-Eintrag an")
    func seederTopics() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository, withTopics: true)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let topic = try #require(repository.topics(in: subject).first)
        #expect(topic.title == UITestSeeder.topicTitle)
        #expect(!topic.isConfirmed)
        #expect(topic.entries.count == 1)
        #expect(topic.sources.count == 1)
        let entry = try #require(topic.entries.first)
        #expect(entry.origin == .original)
        #expect(try repository.lines(for: #require(entry.sourceReferences.first)).first?.text == UITestSeeder.topicEntryText)
    }
}
