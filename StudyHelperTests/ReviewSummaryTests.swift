import Foundation
import StudyCore
@testable import StudyData
import SwiftData
import Testing
@testable import StudyHelper

@Suite("Seiten-Zusammenfassungen und Zwischenspeicher")
@MainActor
struct ReviewSummaryTests {
    /// The repository retains the container, so keeping it keeps the models usable.
    private struct Seeded {
        let repository: StudyRepository
        let subject: Subject
    }

    private func seeded() throws -> Seeded {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        return Seeded(repository: repository, subject: subject)
    }

    @Test("Offene Wörter werden gezählt")
    func openCounts() throws {
        let seed = try seeded()
        let subject = seed.subject
        let batch = try #require(subject.imports.first)
        let source = try #require(batch.sortedSources.first)
        // Fixed word list instead of the system dictionary: only the two words the recognizer is unsure about count.
        let checker = UITestSpellChecker(unknown: [])
        #expect(PageSummary(source, checker: checker) == PageSummary(source, checker: checker))
        #expect(PageSummary(source, checker: checker).open == 2 && !PageSummary(source, checker: checker).unreadable)
        #expect(BatchSummary(batch, checker: checker).open == 2 && BatchSummary(batch, checker: checker).pages == 1)
        #expect(SubjectSummary(subject, checker: checker).open == 2 && SubjectSummary(subject, checker: checker).imports == 1)
    }

    @Test("Nicht lesbare Daten gelten nie als geprüft, sondern als beschädigt")
    func unreadableDataIsNotChecked() throws {
        let seed = try seeded()
        let subject = seed.subject
        let batch = try #require(subject.imports.first)
        let source = try #require(batch.sortedSources.first)
        let digitization = try #require(source.currentDigitization)
        #expect(!digitization.isDamaged, "die Beschädigung ist noch nicht markiert: nur die Bytes sind kaputt")
        digitization.linesData = Data("{ kaputt".utf8)

        let page = PageSummary(source)
        #expect(page.unreadable)
        #expect(page.open == 0)
        #expect(digitization.lines.isEmpty, "der Getter verschluckt den Fehler: deshalb darf die Prüfansicht ihn nicht allein nutzen")
        #expect(BatchSummary(batch).unreadablePages == 1)
        #expect(SubjectSummary(subject).unreadablePages == 1)
    }

    @Test("DerivedValue rechnet nur nach einer Änderung der gelesenen Werte neu")
    func derivedValueRecomputesOnChange() async throws {
        let seed = try seeded()
        let subject = seed.subject
        let cache = DerivedValue<String>()
        var computations = 0
        func read() -> String {
            cache.value(key: subject.id) {
                computations += 1
                return subject.name
            }
        }
        #expect(read() == "Biologie" && read() == "Biologie")
        #expect(computations == 1, "zweites Lesen kommt aus dem Zwischenspeicher")

        subject.name = "Chemie"
        #expect(await waitUntil { read() == "Chemie" })
        #expect(computations == 2)
        #expect(read() == "Chemie" && computations == 2)
    }

    @Test("DerivedValue rechnet bei anderem Schlüssel neu")
    func derivedValueKeyChange() {
        let cache = DerivedValue<Int>()
        var computations = 0
        #expect(cache.value(key: 1) { computations += 1; return 10 } == 10)
        #expect(cache.value(key: 1) { computations += 1; return 11 } == 10)
        #expect(cache.value(key: 2) { computations += 1; return 12 } == 12)
        #expect(computations == 2)
    }

    /// Counts lookups, so that a test can see whether a page was reviewed (a class: the memo identifies it by object).
    private final class CountingChecker: SpellChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var lookups = 0
        var count: Int { lock.withLock { lookups } }
        func isKnown(_ word: String) -> Bool { lock.withLock { lookups += 1 }; return true }
        func guesses(for word: String) -> [String] { [] }
    }

    @Test("Der Zwischenspeicher rechnet nur geänderte Seiten neu")
    func reviewMemoRecomputesOnlyChangedPages() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        for _ in 0..<8 { try UITestSeeder.seed(repository) }
        let subjects = try repository.subjects().filter { $0.name == UITestSeeder.subjectName }
        #expect(subjects.count == 8)
        let checker = CountingChecker()

        let first = subjects.map { SubjectSummary($0, checker: checker) }
        let afterFirst = checker.count
        #expect(afterFirst > 0, "die erste Berechnung prüft die Wörter")
        #expect(first.allSatisfy { $0.open == 2 })

        let second = subjects.map { SubjectSummary($0, checker: checker) }
        #expect(second == first)
        #expect(checker.count == afterFirst, "die zweite Zusammenfassung kommt vollständig aus dem Zwischenspeicher")

        // One corrected page is recomputed, the other seven are not.
        let subject = try #require(subjects.first)
        let source = try #require(subject.imports.first?.sortedSources.first)
        let line = try #require(source.currentDigitization?.lines.first { $0.text.hasPrefix("Chlorophyl") })
        try repository.correctLine(source: source, lineID: line.id, newText: "Chlorophyll ist der grüne Blattfarbstoff")
        _ = subjects.map { SubjectSummary($0, checker: checker) }
        #expect(checker.count > afterFirst)
        #expect(checker.count - afterFirst < afterFirst / 4, "nur die geänderte Seite wurde neu geprüft")

        // New subject terms change the result of that subject's pages only.
        let before = checker.count
        try repository.addConfirmedTerm("Blattfarbstoff", to: subject)
        _ = subjects.map { SubjectSummary($0, checker: checker) }
        #expect(checker.count > before)
    }

    @Test("Der Zwischenspeicher ist begrenzt und wirft die ältesten Seiten zuerst weg")
    func reviewMemoIsBounded() {
        let cache = PageWordReviewCache(capacity: 20)
        let checker = CountingChecker()
        let keys = (0..<60).compactMap {
            _ in PageWordReviewCache.Key(digitizationID: UUID(), lines: [], terms: [], method: nil, checker: checker)
        }
        for key in keys { cache.store(PageWordReview(), for: key) }
        #expect(cache.count <= 20)
        #expect(cache.value(for: keys[0]) == nil)
        #expect(cache.value(for: keys[59]) != nil)
    }

    @Test("Prüfer ohne feste Identität werden nicht zwischengespeichert")
    func anonymousStructCheckerIsNotMemoized() {
        struct Anonymous: SpellChecking {
            func isKnown(_ word: String) -> Bool { true }
            func guesses(for word: String) -> [String] { [] }
        }
        #expect(PageWordReviewCache.Key(digitizationID: UUID(), lines: [], terms: [], method: nil, checker: Anonymous()) == nil)
    }
}
