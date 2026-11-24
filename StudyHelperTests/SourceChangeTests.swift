import Foundation
import StudyCore
@testable import StudyData
import SwiftData
import Testing
@testable import StudyHelper

@Suite("Themen: Quelle geändert, betroffene Themen, Übernahme-Regeln")
@MainActor
struct SourceChangeTests {
    private let sourceID = UUID()
    private let jpeg = Data([0xFF, 0xD8, 0xFF])

    private func line(_ text: String, order: Int, y: Double, id: UUID = UUID()) -> RecognizedLine {
        let rect = NormalizedRect(x: 0.1, y: y, width: 0.6, height: 0.05)
        let parts = text.split(separator: " ").map(String.init)
        let width = rect.width / Double(max(parts.count, 1))
        let words = parts.enumerated().map { i, part in
            RecognizedWord(text: part, rect: NormalizedRect(x: rect.x + Double(i) * width, y: y, width: width * 0.9, height: rect.height))
        }
        return RecognizedLine(id: id, text: text, rect: rect, words: words, order: order)
    }

    private func marker(on target: RecognizedLine, words: [Int], kind: HighlightKind = .highlighter) -> RecognizedHighlight {
        RecognizedHighlight(
            text: "x", kind: kind, color: RGBColor(hex: "#FFEB3B"), rect: target.rect, source: .goodnotesAnnotation,
            words: words.map { WordReference(lineID: target.id, wordIndex: $0) })
    }

    // MARK: Hervorhebung bei Übernahme (mindestens die Hälfte der Wörter)

    @Test("Eine Hervorhebung auf einem Wort von vielen übernommenen Zeilen gehört nicht zum ganzen Text")
    func highlightNeedsHalfOfTheWords() {
        let a = line("Chlorophyll absorbiert Licht", order: 0, y: 0.1)
        let b = line("und wandelt es in Energie um", order: 1, y: 0.2)
        let one = marker(on: a, words: [0])
        let multi = SourceSelection(sourceID: sourceID, lines: [a, b], highlights: [one])
        #expect(multi.entryHighlight == nil, "1 von 8 Wörtern")
        // The same highlight does belong to the line it sits on.
        #expect(SourceSelection(sourceID: sourceID, lines: [a], highlights: [one]).entryHighlight == nil, "1 von 3 Wörtern")
        #expect(SourceSelection(sourceID: sourceID, lines: [a], highlights: [marker(on: a, words: [0, 1])]).entryHighlight?.kind == .highlighter)
    }

    @Test("Die Hälfte der Wörter genügt, auch über mehrere Zeilen; eine flächige Hervorhebung deckt die ganze Zeile")
    func highlightAtTheThreshold() {
        let a = line("Eins zwei", order: 0, y: 0.1)
        let b = line("drei vier", order: 1, y: 0.2)
        // Two of four words: exactly half.
        let half = marker(on: a, words: [0, 1])
        #expect(SourceSelection(sourceID: sourceID, lines: [a, b], highlights: [half]).entryHighlight != nil)
        // One of four words: below half.
        #expect(SourceSelection(sourceID: sourceID, lines: [a, b], highlights: [marker(on: a, words: [0])]).entryHighlight == nil)
        // An area highlight (no word references) over a whole line covers all its words.
        let area = RecognizedHighlight(text: "", kind: .underline, rect: a.rect, source: .goodnotesShape, words: [])
        #expect(SourceSelection(sourceID: sourceID, lines: [a], highlights: [area]).entryHighlight?.kind == .underline)
        #expect(SourceSelection(sourceID: sourceID, lines: [a, b], highlights: [area]).entryHighlight?.kind == .underline, "2 von 4 Wörtern")
    }

    // MARK: Markierung

    @Test("Fehlen einige Zeilen, zeigt die Markierung den gespeicherten Bereich, nicht nur die übrigen Zeilen")
    func staleMarkShowsStoredRect() {
        let a = line("Eins", order: 0, y: 0.1)
        let b = line("Zwei", order: 1, y: 0.3)
        let stored = a.rect.union(b.rect)
        let reference = SourceReference(sourceID: sourceID, lineIDs: [a.id, b.id], rect: stored)
        let mark = ReferenceResolver.mark(for: reference, resolvedLines: [a])
        #expect(mark.isStale)
        #expect(mark.rect == stored)
        // Without a stored rect the remaining lines are all there is.
        let bare = SourceReference(sourceID: sourceID, lineIDs: [a.id, b.id])
        #expect(ReferenceResolver.mark(for: bare, resolvedLines: [a]).rect == a.rect)
    }

    // MARK: Erkennung

    private func snapshotReference(
        _ lines: [RecognizedLine], highlights: [RecognizedHighlight], version: Int = 1
    ) -> SourceReference {
        SourceSelection(sourceID: sourceID, digitizationVersion: version, lines: lines, highlights: highlights).reference
    }

    @Test("Der Quellenverweis einer Übernahme trägt den Schnappschuss von Text und Hervorhebung")
    func referenceCarriesSnapshot() {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let reference = snapshotReference([l], highlights: [marker(on: l, words: [1])])
        #expect(reference.snapshotText == "Ort: Chloroplasten")
        #expect(reference.snapshotHighlights == [EntryHighlight(kind: .highlighter, color: RGBColor(hex: "#FFEB3B"))])
        let suggestion = HighlightSuggestions.make(
            lines: [l], highlights: [marker(on: l, words: [1])], sourceID: sourceID, digitizationID: nil, digitizationVersion: 1)
        #expect(suggestion.first?.reference.snapshotText == "Ort: Chloroplasten")
    }

    @Test("Unveränderte Quelle: keine Meldung")
    func unchangedSource() {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let highlights = [marker(on: l, words: [1])]
        let reference = snapshotReference([l], highlights: highlights)
        let report = SourceChangeDetector.detect(reference: reference, lines: [l], highlights: highlights, version: 5)
        #expect(!report.isChanged, "eine neue Versionsnummer allein ist keine Änderung des Inhalts")
        #expect(report.canAdopt)
    }

    @Test("Geänderter Zeilentext wird erkannt")
    func textChange() {
        var l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let reference = snapshotReference([l], highlights: [])
        l.text = "Ort: Chloroplasten (Stroma)"
        let report = SourceChangeDetector.detect(reference: reference, lines: [l], highlights: [], version: 1)
        #expect(report.textChanged && !report.highlightChanged && report.isChanged)
        #expect(report.detail.contains("Text"))
    }

    @Test("Geänderte oder entfernte Hervorhebung wird erkannt")
    func highlightChange() {
        let l = line("Ort: Chloroplasten", order: 0, y: 0.1)
        let reference = snapshotReference([l], highlights: [marker(on: l, words: [1])])
        let removed = SourceChangeDetector.detect(reference: reference, lines: [l], highlights: [], version: 1)
        #expect(removed.highlightChanged && !removed.textChanged)
        let other = SourceChangeDetector.detect(
            reference: reference, lines: [l], highlights: [marker(on: l, words: [1], kind: .circled)], version: 1)
        #expect(other.highlightChanged)
        // A highlight elsewhere on the page is not the emphasis of this entry.
        let elsewhere = line("Etwas anderes", order: 1, y: 0.5)
        let unrelated = SourceChangeDetector.detect(
            reference: reference, lines: [l, elsewhere], highlights: [marker(on: l, words: [1]), marker(on: elsewhere, words: [0], kind: .boxed)],
            version: 1)
        #expect(!unrelated.isChanged)
    }

    @Test("Fehlende Zeilen werden erkannt; ohne verbleibende Zeile kann nichts übernommen werden")
    func missingLines() {
        let a = line("Eins", order: 0, y: 0.1)
        let b = line("Zwei", order: 1, y: 0.2)
        let reference = snapshotReference([a, b], highlights: [])
        let some = SourceChangeDetector.detect(reference: reference, lines: [a], highlights: [], version: 1)
        #expect(some.linesMissing && some.textChanged && some.canAdopt)
        let none = SourceChangeDetector.detect(reference: reference, lines: [], highlights: [], version: 1)
        #expect(none.linesMissing && !none.canAdopt)
    }

    @Test("Ohne Schnappschuss (ältere Verweise) entscheidet die Version der Digitalisierung")
    func legacyReferenceUsesVersion() {
        let l = line("Eins", order: 0, y: 0.1)
        let legacy = SourceReference(sourceID: sourceID, lineIDs: [l.id], digitizationVersion: 1)
        #expect(!SourceChangeDetector.detect(reference: legacy, lines: [l], highlights: [], version: 1).isChanged)
        let newer = SourceChangeDetector.detect(reference: legacy, lines: [l], highlights: [], version: 2)
        #expect(newer.versionChanged && newer.isChanged)
        #expect(newer.detail.contains("neu erkannt"))
        // Without any version there is nothing to compare.
        let bare = SourceReference(sourceID: sourceID, lineIDs: [l.id])
        #expect(!SourceChangeDetector.detect(reference: bare, lines: [l], highlights: [], version: 3).isChanged)
    }

    // MARK: Mit dem Speicher

    private struct Fixture {
        let repository: StudyRepository
        let subject: Subject
        let source: Source
        let topic: Topic
        let entry: TopicEntry
        let line: RecognizedLine
    }

    private func fixture(confirmed: Bool = false) throws -> Fixture {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository, withTopics: true)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let source = try #require(subject.imports.first?.sortedSources.first)
        let topic = try #require(repository.topics(in: subject).first)
        if confirmed { try repository.confirm(topic) }
        let entry = try #require(topic.entries.first)
        let line = try #require(source.currentDigitization?.lines.first { $0.order == 1 })
        return Fixture(repository: repository, subject: subject, source: source, topic: topic, entry: entry, line: line)
    }

    @Test("Der Seeder speichert einen Schnappschuss; ohne Korrektur ist der Eintrag unverändert")
    func seededEntryIsUnchanged() throws {
        let f = try fixture()
        #expect(f.entry.sourceReferences.first?.snapshotText == UITestSeeder.topicEntryText)
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject).isEmpty)
        #expect(TopicImpact.changed(in: f.subject).isEmpty)
    }

    @Test("Nach einer Textkorrektur ist der Eintrag und sein Thema betroffen; „Text übernehmen“ aktualisiert Text und Verweis")
    func correctionThenAdopt() throws {
        let f = try fixture(confirmed: true)
        try f.repository.correctLine(source: f.source, lineID: f.line.id, newText: "Ort: Chloroplasten (Stroma)")

        let reports = SourceChecks.reports(for: f.topic.entries, subject: f.subject)
        #expect(reports[f.entry.id]?.textChanged == true)
        #expect(TopicImpact.changed(in: f.subject).map(\.id) == [f.topic.id])
        #expect(TopicImpact.changed(in: f.subject, sourceIDs: [UUID()]).isEmpty, "andere Seiten betreffen das Thema nicht")
        #expect(f.entry.text == UITestSeeder.topicEntryText, "der Eintrag ändert sich nicht von selbst")
        #expect(f.topic.isReadyForLearning)

        try SourceChangeResolver.adopt(f.entry, subject: f.subject, repository: f.repository)
        #expect(f.entry.text == "Ort: Chloroplasten (Stroma)")
        #expect(f.entry.origin == .original)
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject).isEmpty)
        #expect(f.entry.sourceReferences.first?.snapshotText == "Ort: Chloroplasten (Stroma)")
        #expect(f.entry.sourceReferences.first?.digitizationVersion == f.source.currentDigitization?.versionNumber)
        #expect(!f.topic.isReadyForLearning, "geänderter Inhalt eines bestätigten Themas verlangt erneutes Bestätigen")
    }

    @Test("„Ignorieren“ lässt den Inhalt, bringt den Verweis auf den neuen Stand und markiert das Thema nicht als geändert")
    func correctionThenIgnore() throws {
        let f = try fixture(confirmed: true)
        try f.repository.correctLine(source: f.source, lineID: f.line.id, newText: "Ort: Stroma")
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject)[f.entry.id] != nil)

        try SourceChangeResolver.acknowledge(f.entry, subject: f.subject, repository: f.repository)
        #expect(f.entry.text == UITestSeeder.topicEntryText)
        #expect(f.entry.highlight?.kind == .highlighter)
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject).isEmpty)
        #expect(f.entry.sourceReferences.first?.snapshotText == "Ort: Stroma")
        #expect(f.topic.isReadyForLearning)
        // A further correction is reported again.
        try f.repository.correctLine(source: f.source, lineID: f.line.id, newText: "Ort: Thylakoide")
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject)[f.entry.id] != nil)
    }

    @Test("Eine geänderte Hervorhebung macht den Eintrag betroffen; „Übernehmen“ folgt der neuen Hervorhebung")
    func highlightEditThenAdopt() throws {
        let f = try fixture()
        let highlight = try #require(f.source.currentDigitization?.highlights.first { $0.kind == .highlighter })
        try f.repository.setHighlightKind(.circled, id: highlight.id, in: f.source)
        let report = try #require(SourceChecks.reports(for: f.topic.entries, subject: f.subject)[f.entry.id])
        #expect(report.highlightChanged && !report.textChanged)
        try SourceChangeResolver.adopt(f.entry, subject: f.subject, repository: f.repository)
        #expect(f.entry.highlight?.kind == .circled)
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject).isEmpty)
    }

    @Test("Nach der Wiederherstellung einer älteren Version werden betroffene Themen erkannt")
    func restoreVersionAffectsTopic() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository, withVersions: true, withTopics: true)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let source = try #require(subject.imports.first?.sortedSources.first)
        // The topic entry points at line 2, which is the same in both versions: nothing is affected.
        #expect(TopicImpact.changed(in: subject).isEmpty)
        let first = try #require(source.sortedDigitizations.first)
        try repository.restoreVersion(first)
        #expect(TopicImpact.changed(in: subject).isEmpty)
        // An edit of the entry's line in the restored version is.
        let line = try #require(source.currentDigitization?.lines.first { $0.order == 1 })
        try repository.correctLine(source: source, lineID: line.id, newText: "Ort: Stroma")
        #expect(TopicImpact.changed(in: subject).count == 1)
    }

    @Test("Themen, die einen Import verwenden: zugeordnete Seite oder Verweis eines Eintrags")
    func topicsUsingSources() throws {
        let f = try fixture()
        #expect(TopicImpact.using(sourceIDs: [f.source.id], in: f.subject).map(\.id) == [f.topic.id])
        #expect(TopicImpact.using(sourceIDs: [UUID()], in: f.subject).isEmpty)
        // Not assigned, but referenced by an entry.
        try f.repository.remove(f.source, from: f.topic)
        #expect(TopicImpact.using(sourceIDs: [f.source.id], in: f.subject).map(\.id) == [f.topic.id])
        try f.repository.deleteEntry(f.entry)
        #expect(TopicImpact.using(sourceIDs: [f.source.id], in: f.subject).isEmpty)
    }

    @Test("Einträge ohne Original-Herkunft und ohne lesbare Quelle werden nicht gemeldet")
    func onlyOriginalEntriesWithReadableSource() throws {
        let f = try fixture()
        try f.repository.correctLine(source: f.source, lineID: f.line.id, newText: "Ort: Stroma")
        try f.repository.editEntry(f.entry) { $0.origin = .user }
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject).isEmpty)
        // Unknown source: no crash, no report.
        try f.repository.editEntry(f.entry) { target in
            target.origin = .original
            target.sourceReferences = [SourceReference(sourceID: UUID(), lineIDs: [UUID()], snapshotText: "x")]
        }
        #expect(SourceChecks.reports(for: f.topic.entries, subject: f.subject).isEmpty)
    }

    // MARK: Koordinator

    @Test("Nach dem erneuten Erkennen nennt die Meldung die betroffenen Themen")
    func reRecognitionReportsAffectedTopics() async throws {
        let pipeline = MockPipeline()
        pipeline.onImage = { n in makePage(index: 0, text: n == 1 ? "Ort: Chloroplasten" : "Ort: Stroma") }
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importImageData([jpeg], kind: .photo, into: f.subject)
        await f.coordinator.waitUntilIdle()
        let batch = try #require(f.batch)
        let source = try #require(batch.sortedSources.first)
        let digitization = try #require(source.currentDigitization)
        let line = try #require(digitization.lines.first)
        let topic = try f.repository.createTopic(in: f.subject, title: "Fotosynthese")
        try f.repository.addEntry(
            to: topic, kind: .keyStatement, text: "Ort: Chloroplasten", origin: .original,
            sourceReferences: [SourceSelection(
                sourceID: source.id, digitizationID: digitization.id, digitizationVersion: digitization.versionNumber,
                lines: [line], highlights: []).reference])
        _ = try f.repository.createTopic(in: f.subject, title: "Unbeteiligt")
        #expect(f.coordinator.affectedTopics.isEmpty)

        f.coordinator.reRecognize([source], in: batch)
        await f.coordinator.waitUntilIdle()
        #expect(f.coordinator.affectedTopics.map(\.title) == ["Fotosynthese"])
        #expect(f.coordinator.affectedSubjectID == f.subject.id)
        #expect(f.coordinator.notice == "1 von 1 Bild erkannt. Betroffene Themen: Fotosynthese.")

        f.coordinator.dismissImpact()
        #expect(f.coordinator.affectedTopics.isEmpty)
    }

    @Test("Der Koordinator sammelt betroffene Themen ohne Duplikate")
    func impactAccumulatesWithoutDuplicates() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository, withTopics: true)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let source = try #require(subject.imports.first?.sortedSources.first)
        let line = try #require(source.currentDigitization?.lines.first { $0.order == 1 })
        let coordinator = ImportCoordinator(repository: repository)
        #expect(coordinator.reportImpact(of: [source]).isEmpty)
        try repository.correctLine(source: source, lineID: line.id, newText: "Ort: Stroma")
        #expect(coordinator.reportImpact(of: [source]).count == 1)
        #expect(coordinator.reportImpact(of: [source]).count == 1)
        #expect(coordinator.affectedTopics.count == 1)
    }
}
