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

    @Test("Offene Stellen werden gezählt")
    func openCounts() throws {
        let seed = try seeded()
        let subject = seed.subject
        let batch = try #require(subject.imports.first)
        let source = try #require(batch.sortedSources.first)
        #expect(PageSummary(source) == PageSummary(source))
        #expect(PageSummary(source).open == 1 && !PageSummary(source).unreadable)
        #expect(BatchSummary(batch).open == 1 && BatchSummary(batch).pages == 1)
        #expect(SubjectSummary(subject).open == 1 && SubjectSummary(subject).imports == 1)
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
}
