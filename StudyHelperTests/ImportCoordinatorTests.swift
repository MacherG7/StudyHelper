import Foundation
import StudyCore
@testable import StudyData
import StudyImport
import SwiftData
import Testing
@testable import StudyHelper

@Suite("ImportCoordinator")
@MainActor
struct ImportCoordinatorTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF])

    // MARK: Cancel

    @Test("Abbrechen bleibt bestehen, auch wenn die laufende Seite noch fertig wird")
    func cancelSticks() async throws {
        let gate = Gate()
        let pipeline = MockPipeline()
        pipeline.onImage = { n in
            await gate.wait()
            return makePage(index: 0, text: "Bild \(n)")
        }
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importImageData([jpeg, jpeg, jpeg], kind: .photo, into: f.subject)
        #expect(await waitUntil { pipeline.imageCalls == 1 })

        f.coordinator.cancel()
        #expect(f.coordinator.progress?.isCancelling == true)
        #expect(f.coordinator.progress?.message == "Wird abgebrochen…")

        gate.open()
        await f.coordinator.waitUntilIdle()
        #expect(pipeline.imageCalls == 1, "nach dem Abbruch wurde keine weitere Seite begonnen")
        #expect(f.coordinator.progress == nil)
        #expect(f.coordinator.notice?.contains("Abgebrochen") == true)
        #expect(f.coordinator.notice?.contains("2 Seiten warten") == true)
        let states = f.batch?.sortedSources.map(\.digitizationState)
        #expect(states == [.done, .pending, .pending], "die bereits erkannte Seite bleibt erhalten")
    }

    @Test("Zweiter Import während eines laufenden Imports wird abgelehnt")
    func secondJobIsRejected() async throws {
        let gate = Gate()
        let pipeline = MockPipeline()
        pipeline.onImage = { _ in await gate.wait(); return makePage(index: 0, text: "x") }
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importImageData([jpeg], kind: .photo, into: f.subject)
        #expect(await waitUntil { pipeline.imageCalls == 1 })

        f.coordinator.importImageData([jpeg], kind: .photo, into: f.subject)
        #expect(f.coordinator.errorMessage?.contains("läuft bereits") == true)
        gate.open()
        await f.coordinator.waitUntilIdle()
        #expect(f.subject.imports.count == 1)
    }

    // MARK: Re-recognition of single pages

    @Test("Eine Seite neu erkennen verarbeitet nur diese Seite")
    func singlePageReRecognition() async throws {
        let f = try CoordinatorFixture()
        f.coordinator.importPDF(main: CoordinatorFixture.fakePDF(pages: 3), reduced: nil, into: f.subject)
        await f.coordinator.waitUntilIdle()
        let batch = try #require(f.batch)
        #expect(f.pipeline.pdfCalls == [Set(0..<3)])
        #expect(f.coordinator.notice == "3 von 3 Seiten erkannt.")

        let sources = batch.sortedSources
        f.coordinator.reRecognize([sources[1]], in: batch)
        await f.coordinator.waitUntilIdle()

        #expect(f.pipeline.pdfCalls.last == [1], "die Pipeline bekam nur Seite 2 als Ziel")
        #expect(f.pipeline.processedPages == [0, 1, 2, 1], "Seite 1 und 3 wurden nicht noch einmal erkannt")
        #expect(sources.map { $0.digitizations.count } == [1, 2, 1])
        #expect(sources.allSatisfy { $0.digitizationState == .done })
        #expect(f.coordinator.notice == "1 von 1 Seite erkannt.")
    }

    @Test("Fehlgeschlagene Seiten werden gezählt und markiert")
    func failedPagesAreMarked() async throws {
        let pipeline = MockPipeline()
        pipeline.failingPages = [1]
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importPDF(main: CoordinatorFixture.fakePDF(pages: 3), reduced: nil, into: f.subject)
        await f.coordinator.waitUntilIdle()
        let sources = try #require(f.batch).sortedSources
        #expect(sources.map(\.digitizationState) == [.done, .failed, .done])
        #expect(sources[1].digitizationError?.contains("Seite 2") == true)
        #expect(f.coordinator.notice?.contains("2 von 3 Seiten erkannt. 1 fehlgeschlagen") == true)
    }

    @Test("Fehler für das ganze Dokument markiert alle Seiten als fehlgeschlagen")
    func documentErrorMarksSourcesFailed() async throws {
        let pipeline = MockPipeline()
        pipeline.pdfError = DigitizationError.encrypted
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importPDF(main: CoordinatorFixture.fakePDF(pages: 3), reduced: nil, into: f.subject)
        await f.coordinator.waitUntilIdle()

        let message = DigitizationError.encrypted.errorDescription
        let sources = try #require(f.batch).sortedSources
        #expect(sources.count == 3)
        #expect(sources.allSatisfy { $0.digitizationState == .failed && $0.digitizationError == message })
        #expect(f.coordinator.errorMessage == message)
        #expect(f.coordinator.progress == nil)
    }

    // MARK: Deleting while a job runs

    @Test("Ein Fach mit laufendem Import lässt sich nicht löschen, danach schon")
    func deletingSubjectDuringJobIsBlocked() async throws {
        let gate = Gate()
        let pipeline = MockPipeline()
        pipeline.onImage = { _ in await gate.wait(); return makePage(index: 0, text: "x") }
        let f = try CoordinatorFixture(pipeline: pipeline)
        let other = try f.repository.createSubject(name: "Deutsch")
        f.coordinator.importImageData([jpeg], kind: .photo, into: f.subject)
        #expect(await waitUntil { pipeline.imageCalls == 1 })

        #expect(f.coordinator.isBusy(with: f.subject))
        #expect(!f.coordinator.isBusy(with: other))
        do {
            try f.coordinator.deleteSubject(f.subject)
            Issue.record("Löschen hätte abgelehnt werden müssen")
        } catch let error as ImportFailure {
            guard case .subjectBusy = error else { Issue.record("falscher Fehler: \(error)"); return }
            #expect(error.errorDescription?.contains("läuft gerade ein Import") == true)
        }
        #expect(try f.repository.subjects().count == 2)

        // Another subject and the running import's batch: the batch is protected, the other subject is free.
        let batch = try #require(f.batch)
        #expect(throws: ImportFailure.self) { try f.coordinator.deleteBatch(batch) }
        try f.coordinator.deleteSubject(other)

        gate.open()
        await f.coordinator.waitUntilIdle()
        #expect(f.coordinator.notice == "1 von 1 Bild erkannt.")
        try f.coordinator.deleteSubject(f.subject)
        #expect(try f.repository.subjects().isEmpty)
    }

    @Test("Wird ein Fach trotzdem gelöscht, endet der Job ohne Absturz und ohne Fehlermeldung")
    func jobSurvivesDeletedSubject() async throws {
        let gate = Gate()
        let pipeline = MockPipeline()
        pipeline.onImage = { _ in await gate.wait(); return makePage(index: 0, text: "x") }
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importImageData([jpeg, jpeg], kind: .photo, into: f.subject)
        #expect(await waitUntil { pipeline.imageCalls == 1 })

        try f.repository.deleteSubject(f.subject)  // behind the coordinator's back
        gate.open()
        await f.coordinator.waitUntilIdle()

        #expect(f.coordinator.errorMessage == nil)
        #expect(f.coordinator.notice?.contains("gelöscht") == true)
        #expect(pipeline.imageCalls == 1)
        #expect(f.coordinator.progress == nil)
    }

    // MARK: Stored data

    @Test("Nicht lesbare gespeicherte Korrekturen werden gemeldet")
    func skippedCorrectionsAreReported() async throws {
        let f = try CoordinatorFixture()
        f.coordinator.importImageData([jpeg], kind: .photo, into: f.subject)
        await f.coordinator.waitUntilIdle()
        let source = try #require(f.batch?.sortedSources.first)
        let lineID = try #require(source.currentDigitization?.lines.first?.id)
        try f.repository.correctLine(source: source, lineID: lineID, newText: "Korrigiert")
        try #require(source.corrections.count == 1)
        source.corrections[0].valueData = Data("???".utf8)
        try f.repository.context.save()

        f.coordinator.reRecognize([source], in: try #require(f.batch))
        await f.coordinator.waitUntilIdle()
        let notice = try #require(f.coordinator.notice)
        #expect(notice.contains("1 gespeicherte Korrektur konnte nicht gelesen werden"), "Meldung: \(notice)")
    }

    @Test("Das gespeicherte Bild wird nur bei der ersten Erkennung ersetzt")
    func imageIsOnlyReplacedOnFirstDigitization() async throws {
        let pipeline = MockPipeline()
        pipeline.onImage = { n in makePage(index: 0, text: "Bild", imageData: Data([UInt8(n), UInt8(n)])) }
        let f = try CoordinatorFixture(pipeline: pipeline)
        f.coordinator.importImageData([jpeg], kind: .photo, into: f.subject)
        await f.coordinator.waitUntilIdle()
        let source = try #require(f.batch?.sortedSources.first)
        #expect(source.imageData == Data([1, 1]), "die erste Erkennung speichert das aufrechte Bild")

        f.coordinator.reRecognize([source], in: try #require(f.batch))
        await f.coordinator.waitUntilIdle()
        #expect(pipeline.imageCalls == 2)
        #expect(source.digitizations.count == 2)
        #expect(source.imageData == Data([1, 1]), "die erneute Erkennung darf das gespeicherte Bild nicht noch einmal neu kodieren")
    }
}
