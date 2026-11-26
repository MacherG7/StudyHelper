import Foundation
import StudyAI
import StudyCore
import StudyData
import SwiftData
import Testing
import UIKit
@testable import StudyHelper

private struct ListSpellChecker: SpellChecking {
    let known: Set<String>
    func isKnown(_ word: String) -> Bool { known.contains(word.lowercased()) }
    func guesses(for word: String) -> [String] { [] }
}

@Suite("Wortprüfung in der App")
@MainActor
struct WordReviewAppTests {
    // MARK: Rechtschreibprüfung

    @Test("UITextChecker-Adapter: bekannte und unbekannte deutsche Wörter")
    func spellCheckerKnownAndUnknown() {
        let checker = UITextCheckerSpellChecking()
        #expect(checker.isKnown("Haus"))
        #expect(checker.isKnown("Wasser"))
        #expect(!checker.isKnown("Hauus"))
        #expect(!checker.isKnown("Xqzwvk"))
        // Zweite Abfrage kommt aus dem Zwischenspeicher und gibt dasselbe Ergebnis.
        #expect(checker.isKnown("Haus") && !checker.isKnown("Hauus"))
        #expect(checker.isKnown(""))
    }

    @Test("UITextChecker-Adapter: Korrekturvorschläge für ein falsch geschriebenes Wort")
    func spellCheckerGuesses() {
        let checker = UITextCheckerSpellChecking()
        let guesses = checker.guesses(for: "Hauus")
        #expect(guesses.contains("Haus"), "Vorschläge: \(guesses)")
        #expect(checker.guesses(for: "Hauus") == guesses)
        #expect(checker.guesses(for: "").isEmpty)
    }

    @Test("UITextChecker-Adapter funktioniert auch von einem anderen Thread")
    func spellCheckerFromBackground() async {
        let checker = UITextCheckerSpellChecking()
        let result = await Task.detached { (checker.isKnown("Baum"), checker.isKnown("Baumm")) }.value
        #expect(result.0 && !result.1)
    }

    // MARK: Zählung

    @Test("Zählung: Wörter und unleserliche Stellen in einem Satz")
    func countText() {
        #expect(PageWordReview.description(words: 1, illegible: 0) == "1 Wort")
        #expect(PageWordReview.description(words: 3, illegible: 0) == "3 Wörter")
        #expect(PageWordReview.description(words: 0, illegible: 2) == "2 unleserliche Stellen")
        #expect(PageWordReview.headline(words: 3, illegible: 1) == "Noch 3 Wörter und 1 unleserliche Stelle offen")
        #expect(PageWordReview.headline(words: 1, illegible: 0) == "Noch 1 Wort offen")
    }

    private func seededSource() throws -> (StudyRepository, Subject, ImportBatch, Source) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let batch = try #require(subject.imports.first)
        let source = try #require(batch.sortedSources.first)
        return (repository, subject, batch, source)
    }

    @Test("Seiten-, Import- und Fachzähler nutzen dieselbe Wortzählung")
    func summariesCountWords() throws {
        // Keep the repository (and with it the model container) alive while the models are read.
        let (repository, subject, batch, source) = try seededSource()
        let checker = UITestSpellChecker(unknown: [])
        withExtendedLifetime(repository) {
            let page = PageSummary(source, checker: checker)
            #expect(page.open == 2 && page.openWords == 2 && page.illegible == 0)
            #expect(BatchSummary(batch, checker: checker).openWords == 2)
            #expect(SubjectSummary(subject, checker: checker).open == 2)
        }
    }

    @Test("Ein Wort, das die Rechtschreibprüfung nicht kennt, zählt als offen; ein Fachbegriff nicht")
    func spellingMarksCount() throws {
        let (repository, subject, _, source) = try seededSource()
        // Only these words are known (a checker that knows everything else would also accept "Chloroplasten" as a
        // compound of known parts).
        let checker = ListSpellChecker(known: ["fotosynthese", "ort", "ist", "der", "blattfarbstoff"])
        #expect(PageSummary(source, checker: checker).openWords == 3)
        try repository.addConfirmedTerm("Chloroplasten", to: subject)
        #expect(PageSummary(source, checker: checker).openWords == 2)
    }

    @Test("Eine Wortkorrektur senkt die Zahl um genau ein Wort, das andere bleibt markiert")
    func wordCorrectionLowersCount() throws {
        let (repository, _, _, source) = try seededSource()
        let checker = UITestSpellChecker(unknown: [])
        let line = try #require(source.currentDigitization?.lines.first { $0.order == 2 })
        try repository.correctWord(source: source, lineID: line.id, wordIndex: 0, newText: "Chlorophyll")
        let after = try #require(source.currentDigitization)
        let review = PageWordReview(lines: after.lines, method: after.metadata.method, terms: [], checker: checker)
        #expect(review.openWords == 1)
        let corrected = try #require(after.lines.first { $0.order == 2 })
        #expect(review.markedTokens(of: corrected.id).map(\.core) == ["grune"])
    }

    @Test("Beschädigte Seiten und Importe in Arbeit sperren die Wortkorrektur")
    func editingLock() {
        let batch = UUID()
        #expect(!ReviewPageView.editingDisabled(damaged: false, activeBatchID: nil, batchID: batch))
        #expect(!ReviewPageView.editingDisabled(damaged: false, activeBatchID: UUID(), batchID: batch))
        #expect(ReviewPageView.editingDisabled(damaged: true, activeBatchID: nil, batchID: batch))
        #expect(ReviewPageView.editingDisabled(damaged: false, activeBatchID: batch, batchID: batch))
    }

    @Test("Eingebetteter PDF-Text und Textfelder werden nie geprüft, Handschrift auch mit Sicherheit 1 schon")
    func embeddedLines() {
        func line(_ origin: LineOrigin?) -> RecognizedLine {
            let rect = NormalizedRect(x: 0, y: 0, width: 1, height: 0.1)
            return RecognizedLine(
                text: "Hallo Welt", rect: rect, confidence: 1,
                words: [RecognizedWord(text: "Hallo", rect: rect, confidence: 1),
                        RecognizedWord(text: "Welt", rect: rect, confidence: 1)],
                order: 0, origin: origin)
        }
        #expect(PageWordReview.isEmbeddedLine(line(.pdfText), method: .embeddedPDFText))
        #expect(PageWordReview.isEmbeddedLine(line(.freeText), method: .goodnotesInkLayers))
        #expect(!PageWordReview.isEmbeddedLine(line(.recognizer), method: .goodnotesInkLayers))
        #expect(!PageWordReview.isEmbeddedLine(line(nil), method: .embeddedPDFText))
    }

    @Test("Das Wortbild wird mit Rand aus der Seite geschnitten")
    func cropsTheWord() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let rect = NormalizedRect(x: 0.25, y: 0.4, width: 0.25, height: 0.1)
        let line = RecognizedLine(
            text: "Wort", rect: rect, confidence: 0.4,
            words: [RecognizedWord(text: "Wort", rect: rect, confidence: 0.4, status: .uncertain)], order: 0)
        let token = try #require(WordReview.tokens(of: line).first)
        let crop = try #require(WordCorrectionSheet.cropWord(token, from: image))
        #expect(crop.size.width > 100 && crop.size.width < 400)
        #expect(crop.size.height > 20 && crop.size.height < 200)
        #expect(WordCorrectionSheet.cropWord(token, from: nil) == nil)
    }

    // MARK: Vorschläge des Geräte-Modells

    private func service(backend: AIBackend) throws -> (AIService, StudyRepository) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        let defaults = UserDefaults(suiteName: "StudyHelperTests-Words-\(UUID().uuidString)") ?? .standard
        let ai = AIService(
            repository: repository, settingsStore: AISettingsStore(defaults: defaults), keyStore: InMemoryKeyStore(),
            backend: backend)
        return (ai, repository)
    }

    @Test("Wortvorschläge laufen über das Geräte-Modell, ohne eingerichteten Anbieter, und werden protokolliert")
    func suggestWordsWithMock() async throws {
        let (ai, repository) = try service(backend: .mock())
        #expect(ai.configurations.isEmpty)
        let words = try await ai.suggestWords(word: "Chlorophyl", before: "", after: "ist der", subject: "Biologie")
        #expect(words == ["Chlorophyll", "Chlorofyll"])
        let logs = try repository.requestLogs()
        #expect(logs.count == 1)
        #expect(logs.first?.task == "wordSuggestions")
        #expect(logs.first?.sentImage == false)
    }

    @Test("Ohne verfügbares Geräte-Modell: Fehler „nicht verfügbar“, nichts gesendet, nichts protokolliert")
    func suggestWordsUnavailable() async throws {
        let unavailable = AIBackend(
            makeProvider: { _ in MockProvider() }, makeCatalog: { _ in StaticModelCatalog(models: []) },
            makeOnDeviceProvider: { throw ProviderError.unavailable(AppleModelAvailability.deviceNotEligible.germanDescription) })
        let (ai, repository) = try service(backend: unavailable)
        await #expect(throws: ProviderError.self) {
            try await ai.suggestWords(word: "Wort", before: "", after: "", subject: nil)
        }
        #expect(try repository.requestLogs().isEmpty)

        // Backend ohne Geräte-Modell (z. B. in Tests): dieselbe Art Fehler mit der deutschen Meldung.
        let none = AIBackend(makeProvider: { _ in MockProvider() }, makeCatalog: { _ in StaticModelCatalog(models: []) })
        let (ai2, _) = try service(backend: none)
        do {
            _ = try await ai2.suggestWords(word: "Wort", before: "", after: "", subject: nil)
            Issue.record("sollte werfen")
        } catch {
            #expect(error.providerError == .unavailable(AIService.onDeviceUnavailableMessage))
        }
    }

    @Test("Eine Antwort ohne brauchbare Vorschläge ergibt eine leere Liste")
    func suggestWordsDropsGarbage() async throws {
        let backend = AIBackend(
            makeProvider: { _ in MockProvider() }, makeCatalog: { _ in StaticModelCatalog(models: []) },
            makeOnDeviceProvider: {
                (ProviderConfiguration(name: "Mock", kind: .mock, model: "m"),
                 MockProvider(script: MockScript(answer: "Das Wort heißt vermutlich ganz anders, nämlich irgendwas.")))
            })
        let (ai, repository) = try service(backend: backend)
        let words = try await ai.suggestWords(word: "Wort", before: "", after: "", subject: nil)
        #expect(words.isEmpty)
        let log = try #require(try repository.requestLogs().first)
        let message = try #require(log.parsingError, "Unlesbare Antworten werden nicht als Erfolg protokolliert")
        #expect(message.contains("keine Vorschlagsliste"))
    }

    @Test("Eine gültige leere Vorschlagsliste ist kein Lesefehler, JSON ohne Vorschlagsliste schon")
    func suggestionsValidation() {
        #expect(AIService.suggestionsParsingError(#"{"vorschlaege": []}"#) == nil)
        #expect(AIService.suggestionsParsingError(#"{"vorschlaege": ["Wort"]}"#) == nil)
        #expect(AIService.suggestionsParsingError("```json\n[\"Wort\"]\n```") == nil)
        #expect(AIService.suggestionsParsingError(#"{"antwort": "ja"}"#) != nil)
        #expect(AIService.suggestionsParsingError("Ich weiß es nicht") != nil)
        #expect(AIService.suggestionsParsingError("") != nil)
        #expect(AIService.suggestionsParsingError("{ kaputt") != nil)
    }
}
