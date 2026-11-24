import Foundation
import SwiftData
import StudyCore
import Testing

@testable import StudyData

// MARK: - Helpers

@MainActor
private func makeRepo() throws -> (StudyRepository, ModelContainer) {
    let container = try ModelContainerFactory.makeContainer(inMemory: true)
    return (StudyRepository(container: container), container)
}

private let metadata = RecognitionMetadata(method: .vision, osVersion: "test", deviceModel: "test")
private let pageSize = PageSize(width: 595, height: 842)

private func line(_ text: String, y: Double, order: Int, id: UUID = UUID(), status: ConfidenceStatus = .confident) -> RecognizedLine {
    let rect = NormalizedRect(x: 0.1, y: y, width: 0.8, height: 0.04)
    let words = text.split(separator: " ").enumerated().map { i, w in
        RecognizedWord(
            text: String(w),
            rect: NormalizedRect(x: 0.1 + 0.1 * Double(i), y: y, width: 0.09, height: 0.04))
    }
    return RecognizedLine(id: id, text: text, rect: rect, words: words, status: status, order: order)
}

private func result(
    _ lines: [RecognizedLine], highlights: [RecognizedHighlight] = []
) -> DigitizationResult {
    DigitizationResult(
        lines: lines, highlights: highlights, metadata: metadata,
        originalMarkdown: OriginalTextMarkdown.build(lines: lines, highlights: highlights),
        pageSize: pageSize)
}

@MainActor
private func makeSource(_ repo: StudyRepository, pages: Int = 1) throws -> (Subject, ImportBatch) {
    let subject = try repo.createSubject(name: "Biologie")
    let batch = try repo.createBatch(
        in: subject, kind: .photo,
        pages: (0..<pages).map { _ in SourceInput(imageData: Data([1, 2, 3]), pageSize: pageSize) })
    return (subject, batch)
}

/// Explicit "Neu erkennen": makes the source pending again, then stores the new result.
@MainActor
@discardableResult
private func reRecognize(
    _ repo: StudyRepository, _ source: Source, _ result: DigitizationResult
) throws -> SaveDigitizationOutcome {
    try repo.prepareReRecognition(for: [source])
    return try repo.saveDigitization(result, for: source)
}

// MARK: - Subjects

@MainActor
@Suite("Fächer")
struct SubjectTests {
    @Test("Anlegen, umbenennen, sortiert auflisten")
    func crud() throws {
        let (repo, _) = try makeRepo()
        let b = try repo.createSubject(name: "Biologie")
        let c = try repo.createSubject(name: "  Chemie ")
        #expect(c.name == "Chemie")
        try repo.renameSubject(b, to: "Bio")
        #expect(try repo.subjects().map(\.name) == ["Bio", "Chemie"])
        #expect(throws: StudyDataError.emptyName) { try repo.createSubject(name: "  ") }
    }

    @Test("Löschen entfernt Importe, Seiten, Digitalisierungen und Themen")
    func cascade() throws {
        let (repo, container) = try makeRepo()
        let (subject, batch) = try makeSource(repo)
        let source = batch.sources[0]
        try repo.saveDigitization(result([line("Zelle", y: 0.1, order: 0)]), for: source)
        try repo.correctLine(source: source, lineID: source.currentDigitization!.lines[0].id, newText: "Zellen")
        let topic = try repo.createTopic(in: subject, title: "Zelle")
        try repo.assign(source, to: topic)
        try repo.addEntry(to: topic, kind: .keyStatement, text: "x")

        try repo.deleteSubject(subject)
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<Subject>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ImportBatch>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Source>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Digitization>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LineCorrection>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Topic>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TopicEntry>()) == 0)
    }

    @Test("Bestätigte Begriffe: Duplikate ohne Groß-/Kleinschreibung werden ignoriert")
    func confirmedTerms() throws {
        let (repo, _) = try makeRepo()
        let s = try repo.createSubject(name: "Bio")
        try repo.addConfirmedTerm("Mitochondrium", to: s)
        try repo.addConfirmedTerm("mitochondrium", to: s)
        try repo.addConfirmedTerm("Chloroplast", to: s)
        #expect(s.confirmedTerms == ["Mitochondrium", "Chloroplast"])
        try repo.removeConfirmedTerm("MITOCHONDRIUM", from: s)
        #expect(s.confirmedTerms == ["Chloroplast"])
    }
}

// MARK: - Digitization

@MainActor
@Suite("Digitalisierung")
struct DigitizationTests {
    @Test("Zwei Digitalisierungen: Version 1 und 2, nur eine aktuell")
    func versions() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let first = try repo.saveDigitization(result([line("Eins", y: 0.1, order: 0)]), for: source).digitization
        let second = try reRecognize(repo, source, result([line("Zwei", y: 0.1, order: 0)])).digitization
        #expect(first.versionNumber == 1)
        #expect(second.versionNumber == 2)
        #expect(source.digitizations.filter(\.isCurrent).count == 1)
        #expect(source.currentDigitization === second)
        #expect(source.digitizationState == .done)
        #expect(second.lines.first?.text == "Zwei")
        #expect(first.lines.first?.text == "Eins")
    }

    @Test("Korrekturen überleben Neuerkennung mit leicht verschobenen Rects und ändern das Markdown")
    func correctionsSurvive() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let l1 = line("Zelie", y: 0.10, order: 0, status: .uncertain)
        let l2 = line("Kern", y: 0.20, order: 1)
        try repo.saveDigitization(result([l1, l2]), for: source)
        #expect(repo.openReviewCount(for: source) == 1)
        try repo.correctLine(source: source, lineID: l1.id, newText: "Zelle")
        #expect(repo.openReviewCount(for: source) == 0)
        #expect(source.currentDigitization?.originalMarkdown.contains("Zelle") == true)

        // New recognition: same text wrong again, rects moved slightly, new ids.
        var n1 = line("Zelie", y: 0.105, order: 0, status: .uncertain)
        n1.id = UUID()
        let n2 = line("Kern", y: 0.205, order: 1)
        let outcome = try reRecognize(repo, source, result([n1, n2]))
        #expect(outcome.unmatchedCorrections.isEmpty)
        let current = outcome.digitization
        #expect(current.versionNumber == 2)
        #expect(current.lines[0].text == "Zelle")
        #expect(current.lines[0].isUserCorrected)
        #expect(current.originalMarkdown.contains("Zelle"))
        #expect(!current.originalMarkdown.contains("Zelie"))
        #expect(repo.openReviewCount(for: source) == 0)
    }

    @Test("Wiederholtes Korrigieren derselben Zeile legt keine zweite Korrektur an")
    func correctionUpserts() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let l = line("Falsch", y: 0.1, order: 0)
        try repo.saveDigitization(result([l]), for: source)
        try repo.correctLine(source: source, lineID: l.id, newText: "Fast")
        try repo.correctLine(source: source, lineID: l.id, newText: "Richtig")
        #expect(source.corrections.count == 1)
        #expect(source.corrections[0].value.recognizedText == "Falsch")
        #expect(source.corrections[0].value.correctedText == "Richtig")
    }

    @Test("Nicht wiedergefundene Korrektur wird gemeldet")
    func unmatched() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let l = line("Alt", y: 0.1, order: 0)
        try repo.saveDigitization(result([l]), for: source)
        try repo.correctLine(source: source, lineID: l.id, newText: "Neu")
        let outcome = try reRecognize(repo, source, result([line("Ganz woanders", y: 0.7, order: 0)]))
        #expect(outcome.unmatchedCorrections.count == 1)
        #expect(outcome.unmatchedCorrections[0].correctedText == "Neu")
        #expect(outcome.digitization.lines[0].text == "Ganz woanders")
    }

    @Test("Ältere Version wiederherstellen, Korrekturen gewinnen weiterhin")
    func restore() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let v1 = try repo.saveDigitization(result([line("Zelie", y: 0.1, order: 0)]), for: source).digitization
        let v2 = try reRecognize(repo, source, result([line("Zelle", y: 0.1, order: 0)])).digitization
        try repo.correctLine(source: source, lineID: v2.lines[0].id, newText: "Zelle (korrigiert)")
        let unmatched = try repo.restoreVersion(v1)
        #expect(unmatched.isEmpty)
        #expect(source.currentDigitization === v1)
        #expect(!v2.isCurrent)
        #expect(v1.lines[0].text == "Zelle (korrigiert)")
        #expect(v1.originalMarkdown.contains("korrigiert"))
        #expect(source.digitizations.filter(\.isCurrent).count == 1)
    }

    @Test("Einmalige Digitalisierung: erledigte Seiten werden nie wieder ausstehend")
    func oneTimeDigitization() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo, pages: 2)
        let a = batch.sortedSources[0], b = batch.sortedSources[1]
        #expect(try repo.sourcesNeedingDigitization().count == 2)
        try repo.saveDigitization(result([line("A", y: 0.1, order: 0)]), for: a)
        #expect(try repo.sourcesNeedingDigitization().map(\.id) == [b.id])

        // Loading, correcting, structuring or saving again never makes `a` pending.
        try repo.correctLine(source: a, lineID: a.currentDigitization!.lines[0].id, newText: "A2")
        _ = try repo.openReviewCount(for: batch)
        #expect(throws: StudyDataError.digitizationNotPending) {
            try repo.saveDigitization(result([line("A", y: 0.1, order: 0)]), for: a)
        }
        #expect(a.digitizations.count == 1)
        #expect(a.digitizationState == .done)
        #expect(try repo.sourcesNeedingDigitization().map(\.id) == [b.id])
        try repo.markDigitizationFailed(b, message: "Texterkennung fehlgeschlagen.")
        #expect(try repo.sourcesNeedingDigitization().isEmpty)
        #expect(b.digitizationError == "Texterkennung fehlgeschlagen.")
    }

    @Test("Explizites Neu-Erkennen markiert Seiten wieder als ausstehend und behält Versionen")
    func reRecognition() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        try repo.saveDigitization(result([line("A", y: 0.1, order: 0)]), for: source)
        try repo.prepareReRecognition(for: [source])
        #expect(source.digitizationState == .pending)
        #expect(source.digitizations.count == 1)
        #expect(try repo.sourcesNeedingDigitization().count == 1)
        try repo.saveDigitization(result([line("B", y: 0.1, order: 0)]), for: source)
        #expect(source.digitizationState == .done)
        #expect(throws: StudyDataError.digitizationNotPending) {
            try repo.saveDigitization(result([line("C", y: 0.1, order: 0)]), for: source)
        }
        #expect(source.digitizations.count == 2)
        #expect(try repo.sourcesNeedingDigitization().isEmpty)
    }

    @Test("Offene Prüfstellen pro Seite und pro Import")
    func reviewCounts() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo, pages: 2)
        try repo.saveDigitization(
            result([line("a", y: 0.1, order: 0, status: .uncertain), line("b", y: 0.2, order: 1, status: .illegible)]),
            for: batch.sortedSources[0])
        try repo.saveDigitization(
            result([line("c", y: 0.1, order: 0, status: .uncertain)]), for: batch.sortedSources[1])
        #expect(repo.openReviewCount(for: batch.sortedSources[0]) == 2)
        #expect(repo.openReviewCount(for: batch) == 3)
    }
}

// MARK: - Highlights

@MainActor
@Suite("Hervorhebungen")
struct HighlightTests {
    @Test("Art, Farbe, Bedeutung ändern, löschen, aus Wörtern anlegen")
    func edit() throws {
        let (repo, _) = try makeRepo()
        let (_, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let l = line("Die Zelle teilt sich", y: 0.1, order: 0)
        let h = RecognizedHighlight(
            text: "Zelle", kind: .underline, rect: l.words[1].rect, status: .uncertain,
            suggestedMeaning: .term, source: .goodnotesShape, words: [WordReference(lineID: l.id, wordIndex: 1)])
        try repo.saveDigitization(result([l], highlights: [h]), for: source)
        let digitization = source.currentDigitization!

        try repo.setHighlightKind(.doubleUnderline, id: h.id, in: source)
        try repo.setHighlightColor(RGBColor(red: 1, green: 0, blue: 0), id: h.id, in: source)
        try repo.setHighlightMeaning(.heading, id: h.id, in: source)
        let edited = digitization.highlights[0]
        #expect(edited.kind == .doubleUnderline)
        #expect(edited.color == RGBColor(red: 1, green: 0, blue: 0))
        #expect(edited.suggestedMeaning == .heading)
        #expect(edited.source == .user)
        #expect(edited.status == .confident)
        // Heading meaning shows up in the rebuilt Markdown.
        #expect(digitization.originalMarkdown.hasPrefix("## "))

        let added = try repo.addHighlight(
            in: source,
            words: [WordReference(lineID: l.id, wordIndex: 2), WordReference(lineID: l.id, wordIndex: 3)],
            kind: .highlighter, color: RGBColor(red: 1, green: 1, blue: 0), meaning: .important)
        #expect(added.text == "teilt sich")
        #expect(added.source == .user)
        #expect(added.rect == l.words[2].rect.union(l.words[3].rect))
        #expect(digitization.highlights.count == 2)
        #expect(digitization.originalMarkdown.contains("==teilt sich=="))

        try repo.deleteHighlight(id: h.id, in: source)
        #expect(digitization.highlights.map(\.id) == [added.id])
        #expect(throws: StudyDataError.highlightNotFound) { try repo.deleteHighlight(id: h.id, in: source) }
        #expect(throws: StudyDataError.noWordsSelected) {
            try repo.addHighlight(in: source, words: [], kind: .bold)
        }
    }
}

// MARK: - Topics

@MainActor
@Suite("Themen")
struct TopicTests {
    @Test("Titel ist Pflicht (deutsche Fehlermeldung)")
    func titleValidation() throws {
        let (repo, _) = try makeRepo()
        let s = try repo.createSubject(name: "Bio")
        #expect(throws: StudyDataError.emptyTopicTitle) { try repo.createTopic(in: s, title: "   ") }
        #expect(StudyDataError.emptyTopicTitle.errorDescription == "Ein Thema braucht einen Titel.")
        let t = try repo.createTopic(in: s, title: "Zelle")
        #expect(throws: StudyDataError.emptyTopicTitle) { try repo.renameTopic(t, to: "") }
        try repo.renameTopic(t, to: "Zellbiologie")
        #expect(t.title == "Zellbiologie")
    }

    @Test("Einträge anlegen, ändern, sortieren, löschen; strukturierte Felder bleiben erhalten")
    func entries() throws {
        let (repo, _) = try makeRepo()
        let s = try repo.createSubject(name: "Bio")
        let t = try repo.createTopic(in: s, title: "Zelle")
        let ref = SourceReference(sourceID: UUID(), lineIDs: [UUID()], rect: NormalizedRect(x: 0, y: 0, width: 1, height: 0.1))
        let e1 = try repo.addEntry(to: t, kind: .keyStatement, text: "A", sourceReferences: [ref],
                                   highlight: EntryHighlight(kind: .underline))
        let e2 = try repo.addEntry(to: t, kind: .term, term: "Zellkern", definition: "Steuerzentrale")
        let e3 = try repo.addEntry(
            to: t, kind: .table, tableData: TableData(headers: ["a", "b"], rows: [["1", "2"]]))
        let e4 = try repo.addEntry(to: t, kind: .example, text: "KI", origin: .aiSupplement, supplementReason: "Lücke")
        #expect(e4.supplementStatus == .proposed)
        #expect(e1.supplementStatus == nil)
        #expect(t.openSupplementCount == 1)
        #expect(e1.sourceReferences == [ref])
        #expect(e1.highlight?.kind == .underline)
        #expect(e3.tableData?.rows == [["1", "2"]])

        try repo.moveEntry(e3, toIndex: 0)
        #expect(t.sortedEntries.map(\.id) == [e3.id, e1.id, e2.id, e4.id])
        try repo.reorderEntries(in: t, orderedIDs: [e4.id, e2.id])
        #expect(t.sortedEntries.map(\.id) == [e4.id, e2.id, e3.id, e1.id])
        try repo.editEntry(e2) { $0.definition = "Zentrale" }
        #expect(e2.definition == "Zentrale")
        try repo.setSupplementStatus(.accepted, for: e4)
        #expect(t.openSupplementCount == 0)
        try repo.deleteEntry(e3)
        #expect(t.sortedEntries.map(\.sortIndex) == [0, 1, 2])
        #expect(t.entries.count == 3)
    }

    @Test("Quellen zuordnen und zwischen Themen verschieben")
    func sources() throws {
        let (repo, _) = try makeRepo()
        let (s, batch) = try makeSource(repo, pages: 2)
        let a = try repo.createTopic(in: s, title: "A")
        let b = try repo.createTopic(in: s, title: "B")
        let p0 = batch.sortedSources[0], p1 = batch.sortedSources[1]
        try repo.assign(p0, to: a)
        try repo.assign(p0, to: a)
        try repo.assign(p1, to: a)
        #expect(a.sources.count == 2)
        try repo.moveSource(p1, from: a, to: b)
        #expect(a.sources.map(\.id) == [p0.id])
        #expect(b.sources.map(\.id) == [p1.id])
        #expect(p1.topics.map(\.id) == [b.id])
        try repo.remove(p0, from: a)
        #expect(a.sources.isEmpty)
        // Deleting a topic keeps the sources.
        try repo.deleteTopic(b)
        #expect(batch.sources.count == 2)
    }

    @Test("Zusammenlegen übernimmt Einträge und Quellen")
    func merge() throws {
        let (repo, _) = try makeRepo()
        let (s, batch) = try makeSource(repo, pages: 2)
        let a = try repo.createTopic(in: s, title: "A", summary: "Zusammenfassung A", origin: .manual)
        let b = try repo.createTopic(in: s, title: "B", origin: .ai)
        try repo.assign(batch.sortedSources[0], to: a)
        try repo.assign(batch.sortedSources[0], to: b)
        try repo.assign(batch.sortedSources[1], to: a)
        try repo.addEntry(to: a, kind: .keyStatement, text: "a1")
        try repo.addEntry(to: a, kind: .keyStatement, text: "a2")
        try repo.addEntry(to: b, kind: .keyStatement, text: "b1")
        try repo.merge(a, into: b)
        #expect(b.sortedEntries.map(\.text) == ["b1", "a1", "a2"])
        #expect(b.sortedEntries.map(\.sortIndex) == [0, 1, 2])
        #expect(b.sources.count == 2)
        #expect(b.summary == "Zusammenfassung A")
        #expect(b.origin == .mixed)
        #expect(try repo.topics(in: s).map(\.id) == [b.id])
        #expect(throws: StudyDataError.sameTopic) { try repo.merge(b, into: b) }
        let other = try repo.createSubject(name: "Chemie")
        let c = try repo.createTopic(in: other, title: "C")
        #expect(throws: StudyDataError.differentSubjects) { try repo.merge(c, into: b) }
    }

    @Test("Zusammenlegen: ein unbestätigtes Thema macht das Ziel zum Entwurf")
    func mergeUnconfirmedIntoConfirmed() throws {
        let (repo, _) = try makeRepo()
        let (s, _) = try makeSource(repo)
        let draft = try repo.createTopic(in: s, title: "Entwurf")
        let target = try repo.createTopic(in: s, title: "Ziel")
        try repo.addEntry(to: draft, kind: .keyStatement, text: "ungeprüft")
        try repo.addEntry(to: target, kind: .keyStatement, text: "geprüft")
        try repo.confirm(target)
        #expect(target.isReadyForLearning)
        try repo.merge(draft, into: target)
        #expect(!target.isConfirmed)
        #expect(target.confirmedAt == nil)
        #expect(target.modifiedAt == nil)
        #expect(!target.isReadyForLearning)
        #expect(target.entries.count == 2)
    }

    @Test("Zusammenlegen: ein bestätigtes Thema in ein bestätigtes Ziel verlangt erneutes Bestätigen")
    func mergeConfirmedIntoConfirmed() throws {
        let (repo, _) = try makeRepo()
        let (s, _) = try makeSource(repo)
        let a = try repo.createTopic(in: s, title: "A")
        let b = try repo.createTopic(in: s, title: "B")
        try repo.addEntry(to: a, kind: .keyStatement, text: "a")
        try repo.confirm(a)
        try repo.confirm(b)
        try repo.merge(a, into: b)
        #expect(b.isConfirmed)
        #expect(b.modifiedAt != nil)
        #expect(!b.isReadyForLearning)
        #expect(b.needsReconfirmation)
        try repo.confirm(b)
        #expect(b.isReadyForLearning)
        // A confirmed topic merged into a draft stays a draft.
        let c = try repo.createTopic(in: s, title: "C")
        let d = try repo.createTopic(in: s, title: "D")
        try repo.confirm(c)
        try repo.merge(c, into: d)
        #expect(!d.isConfirmed)
    }

    @Test("Lernbereit ist nur ein bestätigtes, seither nicht geändertes Thema")
    func readyForLearning() throws {
        let (repo, _) = try makeRepo()
        let (s, batch) = try makeSource(repo, pages: 2)
        let t = try repo.createTopic(in: s, title: "T")
        #expect(!t.isReadyForLearning && !t.needsReconfirmation)
        try repo.confirm(t)
        #expect(t.isReadyForLearning && !t.needsReconfirmation)
        // Every kind of edit of a confirmed topic needs a new confirmation.
        let edits: [(String, () throws -> Void)] = [
            ("Eintrag hinzufügen", { try repo.addEntry(to: t, kind: .keyStatement, text: "x") }),
            ("Quelle zuordnen", { try repo.assign(batch.sortedSources[0], to: t) }),
            ("Quelle entfernen", { try repo.remove(batch.sortedSources[0], from: t) }),
            ("Umbenennen", { try repo.renameTopic(t, to: "T2") }),
        ]
        for (name, edit) in edits {
            try repo.confirm(t)
            #expect(t.isReadyForLearning, "\(name): vorher bereit")
            try edit()
            #expect(!t.isReadyForLearning, "\(name): danach nicht bereit")
            #expect(t.isConfirmed && t.modifiedAt != nil, "\(name)")
        }
        // Moving a source into a confirmed topic marks the target (and the source topic) as changed.
        let from = try repo.createTopic(in: s, title: "Von")
        let to = try repo.createTopic(in: s, title: "Nach")
        try repo.assign(batch.sortedSources[1], to: from)
        try repo.confirm(from)
        try repo.confirm(to)
        try repo.moveSource(batch.sortedSources[1], from: from, to: to)
        #expect(!from.isReadyForLearning && !to.isReadyForLearning)
    }

    @Test("Verweise ersetzen ohne das Thema als geändert zu markieren")
    func replaceReferencesKeepsTopicReady() throws {
        let (repo, _) = try makeRepo()
        let (s, batch) = try makeSource(repo)
        let t = try repo.createTopic(in: s, title: "T")
        let source = batch.sortedSources[0]
        let entry = try repo.addEntry(
            to: t, kind: .keyStatement, text: "x", origin: .original,
            sourceReferences: [SourceReference(sourceID: source.id, snapshotText: "alt")])
        try repo.confirm(t)
        try repo.replaceSourceReferences(
            of: entry, with: [SourceReference(sourceID: source.id, snapshotText: "neu", snapshotHighlights: [])])
        #expect(entry.sourceReferences.first?.snapshotText == "neu")
        #expect(t.isReadyForLearning)
    }

    @Test("Der Schnappschuss im Quellenverweis wird gespeichert; ältere Verweise ohne ihn bleiben lesbar")
    func referenceSnapshotRoundTrip() throws {
        let id = UUID()
        let marker = EntryHighlight(kind: .highlighter, color: RGBColor(hex: "#FFEB3B"))
        let reference = SourceReference(
            sourceID: id, lineIDs: [UUID()], digitizationVersion: 3, snapshotText: "Text", snapshotHighlights: [marker])
        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(SourceReference.self, from: data)
        #expect(decoded == reference)
        let legacy = Data(#"{"sourceID":"\#(id.uuidString)","lineIDs":[],"digitizationVersion":2}"#.utf8)
        let old = try JSONDecoder().decode(SourceReference.self, from: legacy)
        #expect(old.snapshotText == nil && old.snapshotHighlights == nil)
        #expect(old.digitizationVersion == 2)
    }

    @Test("Aufteilen verschiebt Einträge in ein neues Thema mit den referenzierten Quellen")
    func split() throws {
        let (repo, _) = try makeRepo()
        let (s, batch) = try makeSource(repo, pages: 2)
        let t = try repo.createTopic(in: s, title: "Gross")
        let p0 = batch.sortedSources[0], p1 = batch.sortedSources[1]
        try repo.assign(p0, to: t)
        try repo.assign(p1, to: t)
        let e1 = try repo.addEntry(to: t, kind: .keyStatement, text: "1", sourceReferences: [SourceReference(sourceID: p0.id)])
        let e2 = try repo.addEntry(to: t, kind: .keyStatement, text: "2", sourceReferences: [SourceReference(sourceID: p1.id)])
        let e3 = try repo.addEntry(to: t, kind: .keyStatement, text: "3")
        let new = try repo.split(t, movingEntries: [e2, e3], newTitle: "Klein")
        #expect(new.title == "Klein")
        #expect(new.subject === s)
        #expect(new.sortedEntries.map(\.text) == ["2", "3"])
        #expect(t.sortedEntries.map(\.text) == ["1"])
        #expect(t.sortedEntries.map(\.sortIndex) == [0])
        #expect(new.sources.map(\.id) == [p1.id])
        #expect(!new.isConfirmed)
        #expect(throws: StudyDataError.emptyTopicTitle) { try repo.split(t, movingEntries: [e1], newTitle: " ") }
        #expect(throws: StudyDataError.entryNotInTopic) { try repo.split(t, movingEntries: [e2], newTitle: "X") }
    }

    @Test("Bestätigen verlangt Titel; Bearbeiten hält das Thema bestätigt und setzt modifiedAt")
    func confirm() throws {
        let (repo, _) = try makeRepo()
        let s = try repo.createSubject(name: "Bio")
        let t = try repo.createTopic(in: s, title: "Zelle")
        #expect(t.modifiedAt == nil)
        try repo.confirm(t)
        #expect(t.isConfirmed && t.confirmedAt != nil && t.modifiedAt == nil)
        try repo.addEntry(to: t, kind: .keyStatement, text: "neu")
        #expect(t.isConfirmed)
        #expect(t.modifiedAt != nil)

        let empty = try repo.createTopic(in: s, title: "Temp")
        empty.title = ""
        #expect(throws: StudyDataError.emptyTopicTitle) { try repo.confirm(empty) }
        #expect(!empty.isConfirmed)
    }

    @Test("Betroffene Themen über Quelle und Zeilen-IDs")
    func affected() throws {
        let (repo, _) = try makeRepo()
        let (s, batch) = try makeSource(repo)
        let source = batch.sources[0]
        let l1 = UUID(), l2 = UUID(), l3 = UUID()
        let a = try repo.createTopic(in: s, title: "A")
        let b = try repo.createTopic(in: s, title: "B")
        let c = try repo.createTopic(in: s, title: "C")
        try repo.addEntry(to: a, kind: .keyStatement, sourceReferences: [SourceReference(sourceID: source.id, lineIDs: [l1, l2])])
        try repo.addEntry(to: b, kind: .term, sourceReferences: [SourceReference(sourceID: source.id, lineIDs: [l3])])
        try repo.addEntry(to: c, kind: .term, sourceReferences: [SourceReference(sourceID: UUID(), lineIDs: [l1])])
        #expect(try repo.affectedTopics(bySourceID: source.id, lineIDs: [l2]).map(\.id) == [a.id])
        #expect(Set(try repo.affectedTopics(bySourceID: source.id, lineIDs: [l1, l3]).map(\.id)) == [a.id, b.id])
        #expect(try repo.affectedTopics(bySourceID: source.id, lineIDs: [UUID()]).isEmpty)
    }
}

// MARK: - Persistence and settings

@MainActor
@Suite("Persistenz und Einstellungen")
struct PersistenceTests {
    @Test("Daten überleben Schließen und Neuöffnen des Containers (Neuinstallation)")
    func onDiskRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "StudyDataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Test.store")
        let image = Data(repeating: 7, count: 300_000)
        var sourceID = UUID()

        do {
            let container = try ModelContainerFactory.makeContainer(url: url)
            let repo = StudyRepository(container: container)
            let subject = try repo.createSubject(name: "Physik")
            try repo.addConfirmedTerm("Impuls", to: subject)
            let batch = try repo.createBatch(
                in: subject, kind: .goodnotes, originalFileName: "Notiz.pdf",
                originalPDF: Data([9, 9]), goodnotesVariant: .editable, reducedPDF: Data([8]),
                pages: [SourceInput(imageData: image, pageSize: pageSize, hasEmbeddedText: true)])
            let source = batch.sources[0]
            sourceID = source.id
            let l = line("Kraft gleich Masse mal Beschleunigung", y: 0.1, order: 0)
            let h = RecognizedHighlight(text: "Kraft", kind: .circled, rect: l.words[0].rect, source: .goodnotesShape,
                                        words: [WordReference(lineID: l.id, wordIndex: 0)])
            try repo.saveDigitization(result([l], highlights: [h]), for: source)
            try repo.correctLine(source: source, lineID: l.id, newText: "F = m * a")
            let topic = try repo.createTopic(in: subject, title: "Mechanik")
            try repo.assign(source, to: topic)
            try repo.addEntry(to: topic, kind: .table, tableData: TableData(headers: ["x"], rows: [["1"]]),
                              sourceReferences: [SourceReference(sourceID: source.id, lineIDs: [l.id])])
        }

        let container = try ModelContainerFactory.makeContainer(url: url)
        let repo = StudyRepository(container: container)
        let subject = try #require(try repo.subjects().first)
        #expect(subject.name == "Physik")
        #expect(subject.confirmedTerms == ["Impuls"])
        let batch = try #require(subject.imports.first)
        #expect(batch.originalFileName == "Notiz.pdf")
        #expect(batch.goodnotesVariant == .editable)
        #expect(batch.reducedPDF == Data([8]))
        let source = try #require(batch.sources.first)
        #expect(source.id == sourceID)
        #expect(source.imageData == image)
        #expect(source.hasEmbeddedText)
        let digitization = try #require(source.currentDigitization)
        #expect(digitization.lines[0].text == "F = m * a")
        #expect(digitization.highlights[0].kind == .circled)
        #expect(digitization.metadata.method == .vision)
        #expect(source.corrections.count == 1)
        let topic = try #require(subject.topics.first)
        #expect(topic.sources.map(\.id) == [sourceID])
        #expect(topic.entries[0].tableData?.headers == ["x"])
        #expect(topic.entries[0].sourceReferences[0].sourceID == sourceID)
    }

    @Test("Mehrfacherkennung ist standardmäßig aus und lässt sich umschalten")
    func multiPassDefault() throws {
        let suite = "StudyDataTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StudySettings(defaults: defaults)
        #expect(settings.multiPassRecognition == false)
        settings.multiPassRecognition = true
        #expect(StudySettings(defaults: defaults).multiPassRecognition)
    }
}
