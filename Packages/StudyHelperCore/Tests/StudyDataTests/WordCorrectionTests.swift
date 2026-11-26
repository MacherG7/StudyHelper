import Foundation
import SwiftData
import StudyCore
import Testing

@testable import StudyData

private struct WordList: SpellChecking {
    var words: Set<String>
    func isKnown(_ word: String) -> Bool { words.contains(word) }
    func guesses(for word: String) -> [String] { [] }
}

@Suite("Wortkorrekturen speichern")
@MainActor
struct WordCorrectionTests {
    private let checker = WordList(words: ["Durch", "die", "des", "Menschen", "Eingriffe"])

    private func setUp(_ text: String, uncertain: Set<Int>) throws -> (StudyRepository, Source, RecognizedLine) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        let subject = try repo.createSubject(name: "Erdkunde")
        let pageSize = PageSize(width: 595, height: 842)
        let batch = try repo.createBatch(
            in: subject, kind: .photo, pages: [SourceInput(imageData: Data([1, 2, 3]), pageSize: pageSize)])
        let source = batch.sources[0]
        let words = WordTokenizer.tokens(in: text).enumerated().map { i, token in
            RecognizedWord(text: token.original, rect: NormalizedRect(x: 0.1 * Double(i), y: 0.1, width: 0.09, height: 0.04),
                           status: uncertain.contains(i) ? .uncertain : .confident)
        }
        let line = RecognizedLine(
            text: text, rect: NormalizedRect(x: 0, y: 0.1, width: 0.9, height: 0.04), words: words,
            status: uncertain.isEmpty ? .confident : .uncertain, order: 0)
        try repo.saveDigitization(DigitizationResult(
            lines: [line], highlights: [], metadata: RecognitionMetadata(method: .vision, osVersion: "t", deviceModel: "t"),
            originalMarkdown: text, pageSize: pageSize), for: source)
        return (repo, source, line)
    }

    private func marks(_ source: Source) throws -> [Int] {
        let lines = try #require(source.currentDigitization).lines
        return WordReview.marks(for: lines, checker: checker)[lines[0].id] ?? []
    }

    @Test("Einzelne Wörter korrigieren: eine Korrektur je Zeile, übrige Wörter bleiben markiert")
    func correctWords() throws {
        let (repo, source, line) = try setUp("Durch die Eingrifte des Manschen", uncertain: [2, 4])
        #expect(try marks(source) == [2, 4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 2, newText: "Eingriffe")
        #expect(source.currentDigitization?.lines[0].text == "Durch die Eingriffe des Manschen")
        #expect(try marks(source) == [4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 4, newText: "Menschen")
        #expect(try marks(source).isEmpty)
        #expect(source.corrections.count == 1)
        #expect(source.corrections[0].value.confirmedWordIndexes == [2, 4])
        #expect(source.corrections[0].value.recognizedText == "Durch die Eingrifte des Manschen")
        #expect(source.currentDigitization?.originalMarkdown.contains("Menschen") == true)
    }

    @Test("Wortkorrektur übersteht eine Neuerkennung")
    func survivesReRecognition() throws {
        let (repo, source, line) = try setUp("Durch die Eingrifte des Manschen", uncertain: [2, 4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 2, newText: "Eingriffe")
        var fresh = line
        fresh.id = UUID()
        try repo.prepareReRecognition(for: [source])
        let outcome = try repo.saveDigitization(DigitizationResult(
            lines: [fresh], highlights: [], metadata: RecognitionMetadata(method: .vision, osVersion: "t", deviceModel: "t"),
            originalMarkdown: fresh.text, pageSize: PageSize(width: 595, height: 842)), for: source)
        #expect(outcome.unmatchedCorrections.isEmpty)
        #expect(outcome.digitization.lines[0].text == "Durch die Eingriffe des Manschen")
        #expect(try marks(source) == [4])
    }

    @Test("Ganze Zeile korrigieren nach Wortkorrekturen: alles erledigt; danach bleibt die Zeile erledigt")
    func wholeLineWins() throws {
        let (repo, source, line) = try setUp("Durch die Eingrifte des Manschen", uncertain: [2, 4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 2, newText: "Eingriffe")
        try repo.correctLine(source: source, lineID: line.id, newText: "Durch die Eingriffe des Manschen")
        #expect(source.corrections[0].value.confirmedWordIndexes == nil)
        #expect(try marks(source).isEmpty)
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 4, newText: "Menschen")
        #expect(source.corrections[0].value.confirmedWordIndexes == nil)
        #expect(try marks(source).isEmpty)
    }

    @Test("Ersatz durch mehrere Wörter: beide bestätigt, spätere Bestätigungen verschoben, übrige Markierungen bleiben")
    func splitWord() throws {
        let (repo, source, line) = try setUp("Durch dieEingrifte des Manschen Durch", uncertain: [1, 3, 4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 4, newText: "Durch")
        #expect(try marks(source) == [1, 3])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 1, newText: "die Eingriffe")
        let stored = try #require(source.currentDigitization).lines[0]
        #expect(stored.text == "Durch die Eingriffe des Manschen Durch")
        #expect(stored.words.map(\.text) == ["Durch", "die", "Eingriffe", "des", "Manschen", "Durch"])
        #expect(source.corrections[0].value.confirmedWordIndexes == [1, 2, 5])
        #expect(try marks(source) == [4])
    }

    @Test("Wort entfernen: spätere Bestätigungen rücken nach, die Zeile bleibt wortweise")
    func removeWord() throws {
        let (repo, source, line) = try setUp("Durch die xx Eingrifte des Manschen", uncertain: [2, 3, 5])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 3, newText: "Eingriffe")
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 2, newText: "")
        #expect(source.currentDigitization?.lines[0].text == "Durch die Eingriffe des Manschen")
        #expect(source.corrections[0].value.confirmedWordIndexes == [2])
        #expect(try marks(source) == [4])
    }

    @Test("Zeile mit fehlendem Wortrahmen: Wortkorrektur lässt die übrigen Markierungen stehen")
    func missingWordBox() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repo = StudyRepository(container: container)
        let subject = try repo.createSubject(name: "Erdkunde")
        let pageSize = PageSize(width: 595, height: 842)
        let batch = try repo.createBatch(
            in: subject, kind: .photo, pages: [SourceInput(imageData: Data([1, 2, 3]), pageSize: pageSize)])
        let source = batch.sources[0]
        let text = "Durch die Eingrifte des Manschen"
        // The recognizer gave no box for "die".
        let words = WordTokenizer.tokens(in: text).enumerated().compactMap { i, token -> RecognizedWord? in
            i == 1 ? nil : RecognizedWord(
                text: token.original, rect: NormalizedRect(x: 0.1 * Double(i), y: 0.1, width: 0.09, height: 0.04),
                status: [2, 4].contains(i) ? .uncertain : .confident)
        }
        let line = RecognizedLine(
            text: text, rect: NormalizedRect(x: 0, y: 0.1, width: 0.9, height: 0.04), words: words,
            status: .uncertain, reviewReasons: [.lowConfidence], order: 0, origin: .recognizer)
        try repo.saveDigitization(DigitizationResult(
            lines: [line], highlights: [], metadata: RecognitionMetadata(method: .vision, osVersion: "t", deviceModel: "t"),
            originalMarkdown: text, pageSize: pageSize), for: source)
        #expect(try marks(source) == [1, 2, 4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 2, newText: "Eingriffe")
        let stored = try #require(source.currentDigitization).lines[0]
        #expect(stored.words.count == 5)
        #expect(stored.words[2].text == "Eingriffe" && stored.words[2].isUserConfirmed)
        #expect(stored.origin == .recognizer)
        #expect(try marks(source) == [1, 4])
    }

    @Test("Neuerkennung: bestätigte Wörter behalten den Text des Nutzers, die anderen den neuen Text und Status")
    func reRecognitionKeepsConfirmedWords() throws {
        let (repo, source, line) = try setUp("Durch die Eingrifte des Manschen", uncertain: [2, 4])
        try repo.correctWord(source: source, lineID: line.id, wordIndex: 2, newText: "Eingriffe")
        try repo.prepareReRecognition(for: [source])
        // The new run reads the last word correctly and is unsure about "des".
        let text = "Durch die Eingrifte des Menschen"
        let words = WordTokenizer.tokens(in: text).enumerated().map { i, token in
            RecognizedWord(text: token.original, rect: NormalizedRect(x: 0.1 * Double(i), y: 0.1, width: 0.09, height: 0.04),
                           status: i == 3 ? .uncertain : .confident)
        }
        let fresh = RecognizedLine(
            text: text, rect: line.rect, words: words, status: .uncertain, order: 0, origin: .recognizer)
        let outcome = try repo.saveDigitization(DigitizationResult(
            lines: [fresh], highlights: [], metadata: RecognitionMetadata(method: .vision, osVersion: "t", deviceModel: "t"),
            originalMarkdown: text, pageSize: PageSize(width: 595, height: 842)), for: source)
        let stored = outcome.digitization.lines[0]
        #expect(stored.text == "Durch die Eingriffe des Menschen")
        #expect(stored.words[2].isUserConfirmed && stored.words[4].status == .confident)
        #expect(stored.words[3].status == .uncertain)
        #expect(stored.origin == .recognizer)
        #expect(try marks(source) == [3])
    }
}
