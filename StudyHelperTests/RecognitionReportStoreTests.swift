import Foundation
import StudyCore
@testable import StudyData
import SwiftData
import Testing
@testable import StudyHelper

@Suite("Fehlerliste im Entwickler-Modus (Speicher)")
@MainActor
struct RecognitionReportStoreTests {
    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecognitionReportStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(RecognitionReportStore.fileName)
    }

    private func entry(
        importID: UUID = UUID(), page: Int = 1, recognized: String = "Chlorophyl", expected: String? = "Chlorophyll",
        image: Data? = nil
    ) -> RecognitionReportEntry {
        RecognitionReportEntry(
            importID: importID, page: page, pageSize: PageSize(width: 600, height: 800),
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05), kind: .misread,
            recognized: recognized, expected: expected, note: "Notiz", imageJPEG: image)
    }

    private func info(_ id: UUID, name: String = "Fotosynthese.jpg") -> RecognitionReportImport {
        RecognitionReportImport(id: id, fileName: name, kind: "image", goodnotesVariant: nil, pageCount: 2)
    }

    @Test("Einträge hinzufügen, löschen und alles löschen")
    func addDeleteDeleteAll() {
        let store = RecognitionReportStore(fileURL: nil)
        #expect(store.isEmpty)
        let importID = UUID()
        let first = entry(importID: importID)
        let second = entry(importID: importID, page: 2)
        store.add(first, importInfo: info(importID))
        store.add(second, importInfo: info(importID))
        #expect(store.entries.count == 2)
        #expect(store.imports.count == 1, "dieselbe Quelle wird nur einmal gespeichert")

        store.delete(first.id)
        #expect(store.entries.map(\.id) == [second.id])
        #expect(store.importInfo(for: importID) != nil)

        store.delete(second.id)
        #expect(store.isEmpty)
        #expect(store.imports.isEmpty, "Quellen ohne Einträge werden entfernt")

        store.add(first, importInfo: info(importID))
        store.deleteAll()
        #expect(store.isEmpty && store.imports.isEmpty)
    }

    @Test("Einträge überleben einen Neustart, auch mit Bildausschnitt")
    func persistsAndReloads() async throws {
        let url = makeFileURL()
        let importID = UUID()
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let stored = entry(importID: importID, image: image)
        do {
            let store = RecognitionReportStore(fileURL: url)
            store.add(stored, importInfo: info(importID))
            await store.flushWrites()
        }
        let reloaded = RecognitionReportStore(fileURL: url)
        #expect(reloaded.loadNote == nil)
        #expect(reloaded.entries.count == 1)
        let back = try #require(reloaded.entries.first)
        #expect(back.id == stored.id && back.recognized == "Chlorophyl" && back.expected == "Chlorophyll")
        #expect(back.imageJPEG == image)
        #expect(reloaded.importInfo(for: importID)?.fileName == "Fotosynthese.jpg")

        reloaded.delete(stored.id)
        await reloaded.flushWrites()
        #expect(RecognitionReportStore(fileURL: url).isEmpty, "das Löschen wird gespeichert")
    }

    @Test("Eine beschädigte Datei wird gesichert und die Liste beginnt leer")
    func damagedFileIsBackedUp() async throws {
        let url = makeFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ kaputt".utf8).write(to: url)

        let store = RecognitionReportStore(fileURL: url)
        #expect(store.isEmpty)
        let note = try #require(store.loadNote)
        #expect(note.contains("beschädigt"))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("RecognitionReports-beschaedigt-") }, "die Kopie liegt daneben")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // The store keeps working: a new entry creates a fresh file.
        let importID = UUID()
        store.add(entry(importID: importID), importInfo: info(importID))
        await store.flushWrites()
        #expect(RecognitionReportStore(fileURL: url).entries.count == 1)
        store.clearLoadNote()
        #expect(store.loadNote == nil)
    }

    @Test("Ein kaputter Eintrag geht verloren, die anderen bleiben; keine Sicherungskopie")
    func oneBadEntryKeepsTheOthers() async throws {
        let url = makeFileURL()
        let importID = UUID()
        let first = entry(importID: importID, recognized: "erster")
        let second = entry(importID: importID, page: 2, recognized: "zweiter")
        do {
            let store = RecognitionReportStore(fileURL: url)
            store.add(first, importInfo: info(importID))
            store.add(second, importInfo: info(importID))
            await store.flushWrites()
        }
        // Break the file in two places: an entry with an invalid id between the good ones, and a value that is no object.
        let data = try Data(contentsOf: url)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var list = try #require(json["entries"] as? [Any])
        #expect(list.count == 2)
        list.insert(["id": "kein-uuid", "kaputt": true], at: 1)
        list.append("kein Objekt")
        json["entries"] = list
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let store = RecognitionReportStore(fileURL: url)
        #expect(store.entries.map(\.recognized) == ["erster", "zweiter"])
        #expect(store.importInfo(for: importID) != nil)
        let note = try #require(store.loadNote)
        #expect(note.contains("2 beschädigte Einträge"))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!files.contains { $0.hasPrefix("RecognitionReports-beschaedigt-") }, "keine Sicherung bei einzelnen Fehlern")
        #expect(FileManager.default.fileExists(atPath: url.path))

        // The next write drops the broken entries for good.
        store.clearLoadNote()
        store.add(entry(importID: importID, page: 3, recognized: "dritter"), importInfo: info(importID))
        await store.flushWrites()
        let again = RecognitionReportStore(fileURL: url)
        #expect(again.entries.count == 3 && again.loadNote == nil)
    }

    @Test("Viele schnelle Änderungen werden in der richtigen Reihenfolge geschrieben")
    func rapidWritesKeepOrder() async throws {
        let url = makeFileURL()
        let store = RecognitionReportStore(fileURL: url)
        let importID = UUID()
        var ids: [UUID] = []
        for page in 1...25 {
            let item = entry(importID: importID, page: page)
            ids.append(item.id)
            store.add(item, importInfo: info(importID))
        }
        store.delete(ids[0])
        await store.flushWrites()
        let reloaded = RecognitionReportStore(fileURL: url)
        #expect(reloaded.entries.map(\.id) == Array(ids.dropFirst()), "der letzte Stand liegt auf der Platte")
        #expect(store.saveError == nil)
    }

    @Test("Ein Schreibfehler wird gemeldet")
    func writeFailureIsReported() async throws {
        // The "folder" of the file is a regular file, so the folder cannot be created.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let store = RecognitionReportStore(fileURL: blocker.appendingPathComponent("sub").appendingPathComponent("r.json"))
        store.add(entry())
        await store.flushWrites()
        #expect(store.saveError != nil)
    }

    @Test("Voreinstellung: Korrekturen nur der Importe mit gemeldeten Fehlern")
    func defaultCorrectionSelection() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(RecognitionReportCorrections.defaultSelection(candidates: [a, b], reportedImports: [b, c]) == [b])
        #expect(RecognitionReportCorrections.defaultSelection(candidates: [a], reportedImports: []).isEmpty)
        let key = RecognitionReportCorrections.includeKey
        #expect(UserDefaults(suiteName: "RecognitionReportStoreTests-\(UUID().uuidString)")?.bool(forKey: key) == false,
                "ohne gespeicherte Wahl bleibt der Schalter aus")
    }

    @Test("Eine Datei mit fremdem Format gilt als beschädigt")
    func wrongFormatIsDamaged() throws {
        let url = makeFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"format":"etwas-anderes","version":1}"#.utf8).write(to: url)
        let store = RecognitionReportStore(fileURL: url)
        #expect(store.isEmpty && store.loadNote != nil)
    }

    @Test("Der Export enthält die Korrekturen aller Importe nur auf Wunsch")
    func exportIncludesCorrectionsWhenAsked() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let batch = try #require(subject.imports.first)
        let source = try #require(batch.sortedSources.first)
        let digitization = try #require(source.currentDigitization)
        let line = try #require(digitization.lines.first { $0.text.hasPrefix("Chlorophyl") })
        try repository.correctLine(source: source, lineID: line.id, newText: "Chlorophyll ist der grüne Blattfarbstoff")

        let store = RecognitionReportStore(fileURL: nil)
        let reportID = UUID()
        store.add(entry(importID: reportID), importInfo: info(reportID))

        let plain = store.makeReport()
        #expect(plain.entries.count == 1)

        let corrections = RecognitionReportCorrections.collect(from: [batch])
        #expect(corrections.entries.count == 1)
        #expect(corrections.imports.map(\.id) == [batch.id])
        let full = store.makeReport(extraEntries: corrections.entries, extraImports: corrections.imports)
        #expect(full.entries.count == 2)
        #expect(full.imports.count == 2)
        let correction = try #require(full.entries.first { $0.source == .correction })
        #expect(correction.kind == .misread)
        #expect(correction.expected == "Chlorophyll ist der grüne Blattfarbstoff")
        #expect(correction.recognized == "Chlorophyl ist der grune Blattfarbstoff")
        #expect(correction.page == 1)
        #expect(full.chatText().contains("Fotosynthese.jpg"))
        #expect(full.chatText().contains("(Korrektur)"))
    }

    @Test("Ohne Korrekturen liefert die Sammlung nichts")
    func noCorrectionsNoEntries() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        try UITestSeeder.seed(repository)
        let subject = try #require(try repository.subjects().first { $0.name == UITestSeeder.subjectName })
        let corrections = RecognitionReportCorrections.collect(from: subject.imports)
        #expect(corrections.entries.isEmpty && corrections.imports.isEmpty)
    }

    @Test("Die Export-Datei hat das Berichtsformat und enthält Bildausschnitte")
    func exportJSONHasFormat() throws {
        let store = RecognitionReportStore(fileURL: nil)
        let importID = UUID()
        store.add(entry(importID: importID, image: Data([1, 2, 3])), importInfo: info(importID))
        let data = try store.makeReport().encodedJSON()
        let decoded = try RecognitionReport.decode(from: data)
        #expect(decoded.entries.first?.imageJPEG == Data([1, 2, 3]))
        #expect(decoded.app.version == AppVersion.current)
    }
}
