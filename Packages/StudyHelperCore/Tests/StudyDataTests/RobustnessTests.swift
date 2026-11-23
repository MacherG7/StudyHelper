import Foundation
import SwiftData
import StudyCore
import Testing

@testable import StudyData

// MARK: - Helpers

private let metadata = RecognitionMetadata(method: .vision, osVersion: "test", deviceModel: "test")
private let pageSize = PageSize(width: 595, height: 842)

@MainActor
private func makeRepo() throws -> StudyRepository {
    StudyRepository(container: try ModelContainerFactory.makeContainer(inMemory: true))
}

private func line(
    _ text: String, y: Double, order: Int, id: UUID = UUID(), height: Double = 0.04
) -> RecognizedLine {
    let words = text.split(separator: " ").enumerated().map { i, w in
        RecognizedWord(
            text: String(w), rect: NormalizedRect(x: 0.1 + 0.1 * Double(i), y: y, width: 0.09, height: height))
    }
    return RecognizedLine(
        id: id, text: text, rect: NormalizedRect(x: 0.1, y: y, width: 0.8, height: height),
        words: words, order: order)
}

private func result(_ lines: [RecognizedLine], _ highlights: [RecognizedHighlight] = []) -> DigitizationResult {
    DigitizationResult(
        lines: lines, highlights: highlights, metadata: metadata,
        originalMarkdown: OriginalTextMarkdown.build(lines: lines, highlights: highlights),
        pageSize: pageSize)
}

@MainActor
private func makeSource(_ repo: StudyRepository) throws -> (Subject, Source) {
    let subject = try repo.createSubject(name: "Biologie")
    let batch = try repo.createBatch(
        in: subject, kind: .photo, pages: [SourceInput(imageData: Data([1]), pageSize: pageSize)])
    return (subject, batch.sources[0])
}

@MainActor
private func reRecognize(
    _ repo: StudyRepository, _ source: Source, _ result: DigitizationResult
) throws -> SaveDigitizationOutcome {
    try repo.prepareReRecognition(for: [source])
    return try repo.saveDigitization(result, for: source)
}

private func highlight(
    _ text: String, kind: HighlightKind, word: Int, in line: RecognizedLine
) -> RecognizedHighlight {
    RecognizedHighlight(
        text: text, kind: kind, rect: line.words[word].rect, source: .goodnotesShape,
        words: [WordReference(lineID: line.id, wordIndex: word)])
}

/// Same text, slightly moved, fresh ids (what a new recognition run produces).
private func moved(_ l: RecognizedLine, dy: Double = 0.004) -> RecognizedLine {
    var copy = l
    copy.id = UUID()
    copy.rect.y += dy
    for i in copy.words.indices { copy.words[i].rect.y += dy }
    return copy
}

private func movedHighlight(_ h: RecognizedHighlight, newLine: RecognizedLine, dy: Double = 0.004) -> RecognizedHighlight {
    var copy = h
    copy.id = UUID()
    copy.rect.y += dy
    copy.words = h.words.map { WordReference(lineID: newLine.id, wordIndex: $0.wordIndex) }
    return copy
}

// MARK: - Highlight edits survive

@MainActor
@Suite("Hervorhebungs-Korrekturen")
struct HighlightCorrectionPersistenceTests {
    private func setup() throws -> (StudyRepository, Source, RecognizedLine, RecognizedHighlight, RecognizedHighlight) {
        let repo = try makeRepo()
        let (_, source) = try makeSource(repo)
        let l = line("Die Zelle teilt sich", y: 0.1, order: 0)
        let h1 = highlight("Zelle", kind: .underline, word: 1, in: l)
        let h2 = highlight("sich", kind: .highlighter, word: 3, in: l)
        try repo.saveDigitization(result([l], [h1, h2]), for: source)
        return (repo, source, l, h1, h2)
    }

    @Test("Hinzufügen, Umtypisieren und Löschen überleben Neuerkennung mit verschobenen Rects")
    func editsSurviveReRecognition() throws {
        let (repo, source, l, h1, h2) = try setup()
        try repo.setHighlightKind(.circled, id: h1.id, in: source)
        try repo.setHighlightColor(RGBColor(red: 1, green: 0, blue: 0), id: h1.id, in: source)
        try repo.deleteHighlight(id: h2.id, in: source)
        let added = try repo.addHighlight(
            in: source, words: [WordReference(lineID: l.id, wordIndex: 2)], kind: .bold, meaning: .important)
        #expect(source.highlightCorrections.count == 3)

        let n = moved(l)
        let outcome = try reRecognize(
            repo, source,
            result([n], [movedHighlight(h1, newLine: n), movedHighlight(h2, newLine: n)]))
        let highlights = outcome.digitization.highlights
        #expect(outcome.unmatchedHighlightCorrections.isEmpty)
        #expect(source.unmatchedCorrectionCount == 0)
        #expect(highlights.count == 2)
        let circled = try #require(highlights.first { $0.text == "Zelle" })
        #expect(circled.kind == .circled)
        #expect(circled.color == RGBColor(red: 1, green: 0, blue: 0))
        #expect(circled.source == .user)
        #expect(!highlights.contains { $0.text == "sich" })
        let bold = try #require(highlights.first { $0.kind == .bold })
        #expect(bold.text == "teilt")
        #expect(bold.id == added.id)
        // References point at the carried-over line id.
        #expect(circled.words.map(\.lineID) == [l.id])
        #expect(bold.words == [WordReference(lineID: l.id, wordIndex: 2)])
        #expect(outcome.digitization.originalMarkdown.contains("**teilt**"))
        #expect(!outcome.digitization.originalMarkdown.contains("==sich=="))
    }

    @Test("Mehrfaches Bearbeiten derselben Hervorhebung legt keine weiteren Korrekturen an")
    func upsertsRecords() throws {
        let (repo, source, _, h1, _) = try setup()
        try repo.setHighlightKind(.circled, id: h1.id, in: source)
        try repo.setHighlightMeaning(.term, id: h1.id, in: source)
        try repo.setHighlightKind(.boxed, id: h1.id, in: source)
        #expect(source.highlightCorrections.count == 1)
        let value = try #require(source.highlightCorrections[0].value)
        #expect(value.action == .modify)
        #expect(value.kind == .boxed)
        #expect(value.meaning == .term)
        #expect(value.originalKind == .underline)
        #expect(Set(value.changedFields) == [.kind, .meaning])
        // Deleting a modified highlight turns the record into a deletion.
        try repo.deleteHighlight(id: h1.id, in: source)
        #expect(source.highlightCorrections.count == 1)
        #expect(source.highlightCorrections[0].value?.action == .delete)
    }

    @Test("Eigene Hervorhebung löschen entfernt die Korrektur wieder")
    func deleteAddedRemovesRecord() throws {
        let (repo, source, l, _, _) = try setup()
        let added = try repo.addHighlight(in: source, words: [WordReference(lineID: l.id, wordIndex: 0)], kind: .bold)
        #expect(source.highlightCorrections.count == 1)
        try repo.deleteHighlight(id: added.id, in: source)
        #expect(source.highlightCorrections.isEmpty)
    }

    @Test("Wiederherstellen einer älteren Version wendet Hervorhebungs-Korrekturen erneut an, ohne Duplikate")
    func restoreAppliesHighlightCorrections() throws {
        let (repo, source, l, h1, h2) = try setup()
        let v1 = try #require(source.currentDigitization)
        try repo.deleteHighlight(id: h2.id, in: source)
        try repo.setHighlightKind(.circled, id: h1.id, in: source)
        try repo.addHighlight(in: source, words: [WordReference(lineID: l.id, wordIndex: 2)], kind: .bold)
        let n = moved(l)
        _ = try reRecognize(repo, source, result([n], [movedHighlight(h1, newLine: n), movedHighlight(h2, newLine: n)]))
        try repo.restoreVersion(v1)
        try repo.restoreVersion(v1)  // idempotent
        let highlights = v1.highlights
        #expect(highlights.count == 2)
        #expect(highlights.contains { $0.kind == .circled })
        #expect(highlights.contains { $0.kind == .bold })
        #expect(!highlights.contains { $0.text == "sich" })
        #expect(source.unmatchedCorrectionCount == 0)
    }

    @Test("Nicht wiedergefundene Hervorhebungs-Korrekturen werden gemeldet und als nicht zugeordnet markiert")
    func unmatchedFlagged() throws {
        let (repo, source, l, h1, h2) = try setup()
        try repo.setHighlightKind(.circled, id: h1.id, in: source)
        try repo.deleteHighlight(id: h2.id, in: source)
        try repo.addHighlight(in: source, words: [WordReference(lineID: l.id, wordIndex: 2)], kind: .bold)
        let other = line("Völlig anderer Text hier", y: 0.7, order: 0)
        let outcome = try reRecognize(repo, source, result([other]))
        #expect(outcome.unmatchedHighlightCorrections.count == 3)
        #expect(source.unmatchedCorrectionCount == 3)
        #expect(source.highlightCorrections.allSatisfy { $0.isUnmatched })
        // User can discard one.
        try repo.discard(source.highlightCorrections[0])
        #expect(source.unmatchedCorrectionCount == 2)
    }
}

// MARK: - Stable line ids

@MainActor
@Suite("Stabile Zeilen-IDs")
struct LineIdentityPersistenceTests {
    @Test("Verweise von Themen-Einträgen und betroffene Themen funktionieren nach Neuerkennung weiter")
    func referencesResolveAfterReRecognition() throws {
        let repo = try makeRepo()
        let (subject, source) = try makeSource(repo)
        let l1 = line("Die Zelle", y: 0.10, order: 0)
        let l2 = line("Der Kern", y: 0.20, order: 1)
        let h = highlight("Zelle", kind: .underline, word: 1, in: l1)
        let first = try repo.saveDigitization(result([l1, l2], [h]), for: source).digitization
        let topic = try repo.createTopic(in: subject, title: "Zelle")
        let reference = SourceReference(
            sourceID: source.id, lineIDs: [l2.id], digitizationID: first.id, digitizationVersion: first.versionNumber)
        try repo.addEntry(to: topic, kind: .keyStatement, text: "Kern", sourceReferences: [reference])

        let n1 = moved(l1), n2 = moved(l2)
        let second = try reRecognize(repo, source, result([n2, n1], [movedHighlight(h, newLine: n1)])).digitization
        #expect(Set(second.lines.map(\.id)) == [l1.id, l2.id])
        #expect(second.lines.first { $0.text == "Der Kern" }?.id == l2.id)
        #expect(try repo.lines(for: reference).map(\.text) == ["Der Kern"])
        #expect(try repo.affectedTopics(bySourceID: source.id, lineIDs: [l2.id]).map(\.id) == [topic.id])
        #expect(second.highlights[0].words.map(\.lineID) == [l1.id])
        #expect(topic.entries[0].sourceReferences[0].digitizationVersion == 1)
        #expect(topic.entries[0].sourceReferences[0].digitizationID == first.id)
    }

    @Test("Zeilen ohne geometrische Entsprechung bekommen neue IDs")
    func unmatchedLinesGetNewIDs() throws {
        let repo = try makeRepo()
        let (_, source) = try makeSource(repo)
        let l = line("Alt", y: 0.1, order: 0)
        try repo.saveDigitization(result([l]), for: source)
        let n = line("Neu", y: 0.6, order: 0)
        let second = try reRecognize(repo, source, result([n])).digitization
        #expect(second.lines[0].id == n.id)
        #expect(second.lines[0].id != l.id)
    }
}

// MARK: - Raw text

@MainActor
@Suite("Rohtext der Erkennung")
struct RawTextTests {
    @Test("Korrektur behält den automatisch erkannten Text, auch nach Neuerkennung und Wiederherstellung")
    func rawTextKept() throws {
        let repo = try makeRepo()
        let (_, source) = try makeSource(repo)
        let l = line("Zelie", y: 0.1, order: 0)
        let v1 = try repo.saveDigitization(result([l]), for: source).digitization
        #expect(v1.lines[0].recognizedText == nil)
        try repo.correctLine(source: source, lineID: l.id, newText: "Zellen")
        try repo.correctLine(source: source, lineID: l.id, newText: "Zelle")
        #expect(v1.lines[0].text == "Zelle")
        #expect(v1.lines[0].recognizedText == "Zelie")
        #expect(v1.lines[0].automaticText == "Zelie")

        let v2 = try reRecognize(repo, source, result([moved(line("Zelle?", y: 0.1, order: 0))])).digitization
        #expect(v2.lines[0].text == "Zelle")
        #expect(v2.lines[0].recognizedText == "Zelle?")
        #expect(v1.lines[0].recognizedText == "Zelie")  // old version untouched

        try repo.restoreVersion(v1)
        #expect(v1.lines[0].text == "Zelle")
        #expect(v1.lines[0].recognizedText == "Zelie")
        #expect(source.corrections.count == 1)
        #expect(source.corrections[0].value.recognizedText == "Zelie")
    }
}

// MARK: - Adjacent corrections

@MainActor
@Suite("Benachbarte Korrekturen")
struct AdjacentCorrectionTests {
    @Test("Zwei Korrekturen auf eng benachbarten Zeilen landen bei der richtigen Zeile")
    func adjacentLines() throws {
        let repo = try makeRepo()
        let (_, source) = try makeSource(repo)
        let a = line("Aaa", y: 0.100, order: 0)
        let b = line("Bbb", y: 0.115, order: 1)  // overlaps `a` (IoU ≈ 0.45)
        try repo.saveDigitization(result([a, b]), for: source)
        try repo.correctLine(source: source, lineID: a.id, newText: "A korrigiert")
        try repo.correctLine(source: source, lineID: b.id, newText: "B korrigiert")
        try repo.correctLine(source: source, lineID: a.id, newText: "A zweimal")
        #expect(source.corrections.count == 2)

        let outcome = try reRecognize(
            repo, source, result([moved(a, dy: 0.002), moved(b, dy: 0.002)]))
        #expect(outcome.unmatchedCorrections.isEmpty)
        let lines = outcome.digitization.lines.sorted { $0.order < $1.order }
        #expect(lines.map(\.text) == ["A zweimal", "B korrigiert"])
        #expect(lines.map(\.recognizedText) == ["Aaa", "Bbb"])
    }
}

// MARK: - Damaged / versioned blobs

@MainActor
@Suite("Beschädigte und versionierte Blobs")
struct BlobSafetyTests {
    private func setup() throws -> (StudyRepository, Source, Digitization, RecognizedLine, RecognizedHighlight) {
        let repo = try makeRepo()
        let (_, source) = try makeSource(repo)
        let l = line("Die Zelle", y: 0.1, order: 0)
        let h = highlight("Zelle", kind: .underline, word: 1, in: l)
        let d = try repo.saveDigitization(result([l], [h]), for: source).digitization
        return (repo, source, d, l, h)
    }

    @Test("Blobs werden mit Versionsnummer gespeichert")
    func envelope() throws {
        let (repo, _, d, _, _) = try setup()
        try withExtendedLifetime(repo) {
            let json = try #require(String(data: d.linesData, encoding: .utf8))
            #expect(json.contains("\"v\":1"))
            #expect(json.contains("\"data\":"))
        }
    }

    @Test("Das alte Format ohne Wrapper und ohne neue Felder wird weiter gelesen")
    func readsBareLegacyFormat() throws {
        let (repo, source, d, l, _) = try setup()
        let id = l.id.uuidString
        let legacyLines = """
        [{"id":"\(id)","text":"Die Zelle","rect":{"x":0.1,"y":0.1,"width":0.8,"height":0.04},
          "words":[{"text":"Die","rect":{"x":0.1,"y":0.1,"width":0.09,"height":0.04}}]}]
        """
        d.linesData = Data(legacyLines.utf8)
        d.highlightsData = Data("[]".utf8)
        d.metadataData = Data(#"{"method":"vision"}"#.utf8)
        #expect(d.lines.count == 1)
        #expect(d.lines[0].status == .confident)
        #expect(d.lines[0].recognizedText == nil)
        #expect(d.metadata.method == .vision)
        try repo.correctLine(source: source, lineID: l.id, newText: "Die Zellen")
        #expect(d.lines[0].text == "Die Zellen")
        // Written back in the versioned format.
        #expect(String(data: d.linesData, encoding: .utf8)?.contains("\"v\":1") == true)
    }

    @Test("Beschädigte Zeilendaten: Bearbeiten wirft und überschreibt nichts")
    func corruptLinesThrow() throws {
        let (repo, source, d, l, h) = try setup()
        let garbage = Data("{ not json".utf8)
        d.linesData = garbage
        let markdown = d.originalMarkdown
        #expect(throws: StudyDataError.damagedData) {
            try repo.correctLine(source: source, lineID: l.id, newText: "X")
        }
        #expect(throws: StudyDataError.damagedData) { try repo.setHighlightKind(.bold, id: h.id, in: source) }
        #expect(throws: StudyDataError.damagedData) { try repo.deleteHighlight(id: h.id, in: source) }
        #expect(throws: StudyDataError.damagedData) {
            try repo.addHighlight(in: source, words: [WordReference(lineID: l.id, wordIndex: 0)], kind: .bold)
        }
        #expect(throws: StudyDataError.damagedData) { try repo.restoreVersion(d) }
        #expect(d.linesData == garbage)
        #expect(d.originalMarkdown == markdown)
        #expect(d.isDamaged)
        #expect(d.damageNote != nil)
        #expect(source.corrections.isEmpty)
        #expect(source.highlightCorrections.isEmpty)
        // The non-throwing setter refuses to overwrite as well.
        d.lines = []
        #expect(d.linesData == garbage)
    }

    @Test("Beschädigte Highlight-Daten: Bearbeiten wirft, Zeilen bleiben unverändert")
    func corruptHighlightsThrow() throws {
        let (repo, source, d, l, _) = try setup()
        let before = d.linesData
        d.highlightsData = Data([0xFF, 0x00])
        #expect(throws: StudyDataError.damagedData) {
            try repo.correctLine(source: source, lineID: l.id, newText: "X")
        }
        #expect(d.linesData == before)
        #expect(source.corrections.isEmpty)
    }

    @Test("Neuerkennung bei beschädigter Vorversion legt eine neue Version an und lässt die alte unberührt")
    func reRecognizeOverDamaged() throws {
        let (repo, source, d, l, _) = try setup()
        let garbage = Data("nope".utf8)
        d.linesData = garbage
        let second = try reRecognize(repo, source, result([moved(l)])).digitization
        #expect(second.versionNumber == 2)
        #expect(d.linesData == garbage)
        #expect(second.lines.count == 1)
    }

    @Test("Daten aus einer neueren Version werden nicht angefasst und nicht als beschädigt markiert")
    func newerVersion() throws {
        let (repo, source, d, l, _) = try setup()
        let future = Data(#"{"v":99,"data":[]}"#.utf8)
        d.linesData = future
        #expect(throws: StudyDataError.dataFromNewerVersion) {
            try repo.correctLine(source: source, lineID: l.id, newText: "X")
        }
        #expect(d.linesData == future)
        #expect(!d.isDamaged)
    }

    @Test("Beschädigte Korrektur wird übersprungen, behalten und als nicht zugeordnet markiert")
    func corruptCorrectionKept() throws {
        let (repo, source, _, l, _) = try setup()
        try repo.correctLine(source: source, lineID: l.id, newText: "Die Zellen")
        let record = source.corrections[0]
        let garbage = Data("???".utf8)
        record.valueData = garbage
        let outcome = try reRecognize(repo, source, result([moved(l)]))
        #expect(outcome.skippedCorrectionCount == 1)
        #expect(record.valueData == garbage)
        #expect(record.isUnmatched)
        #expect(source.unmatchedCorrectionCount == 1)
        #expect(outcome.digitization.lines[0].text == "Die Zelle")
    }

    @Test("Beschädigte Eintragsdaten: Bearbeiten und Auswirkungsprüfung werfen")
    func corruptEntry() throws {
        let repo = try makeRepo()
        let (subject, source) = try makeSource(repo)
        let topic = try repo.createTopic(in: subject, title: "T")
        let entry = try repo.addEntry(
            to: topic, kind: .keyStatement, text: "a",
            sourceReferences: [SourceReference(sourceID: source.id, lineIDs: [UUID()])])
        let garbage = Data("{{".utf8)
        entry.sourceReferencesBlob = garbage
        #expect(throws: StudyDataError.damagedData) { try repo.editEntry(entry) { $0.text = "b" } }
        #expect(entry.text == "a")
        #expect(throws: StudyDataError.damagedData) {
            try repo.affectedTopics(bySourceID: source.id, lineIDs: [UUID()])
        }
        entry.sourceReferences = []
        #expect(entry.sourceReferencesBlob == garbage)
    }

    @Test("Alte Eintrags-Blobs ohne neue Felder (SourceReference) werden gelesen")
    func legacySourceReference() throws {
        let repo = try makeRepo()
        let (subject, source) = try makeSource(repo)
        let topic = try repo.createTopic(in: subject, title: "T")
        let entry = try repo.addEntry(to: topic, kind: .keyStatement, text: "a")
        entry.sourceReferencesBlob = Data(#"[{"sourceID":"\#(source.id.uuidString)"}]"#.utf8)
        #expect(entry.sourceReferences.count == 1)
        #expect(entry.sourceReferences[0].lineIDs.isEmpty)
        #expect(entry.sourceReferences[0].digitizationVersion == nil)
    }
}
