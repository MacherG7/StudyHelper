import Foundation
import Testing
@testable import StudyHelper

@Suite("Öffnen in: Eingangsordner")
@MainActor
struct IncomingFilesTests {
    /// Temporary app inbox, "Documents/Inbox" and an external folder.
    private struct Folders {
        let root: URL
        var appInbox: URL { root.appendingPathComponent("AppInbox") }
        var documentsInbox: URL { root.appendingPathComponent("Documents/Inbox") }
        var external: URL { root.appendingPathComponent("External") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("IncomingFilesTests-\(UUID().uuidString)")
            for folder in [appInbox, documentsInbox, external] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        func file(in folder: URL, named name: String, age: TimeInterval = 0) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("%PDF".utf8).write(to: url)
            if age > 0 {
                let date = Date().addingTimeInterval(-age)
                try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
            }
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("Eine Datei von außerhalb wird kopiert, das Original bleibt")
    func externalFileIsCopied() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let incoming = IncomingFiles(appInbox: folders.appInbox, documentsInbox: folders.documentsInbox, purgeStale: false)
        let original = try folders.file(in: folders.external, named: "Notiz.pdf")

        await incoming.receive(original)

        let file = try #require(incoming.pending.first)
        #expect(file.originalName == "Notiz.pdf")
        #expect(exists(file.url) && exists(original))
        #expect(IncomingFiles.isInside(file.url, folder: folders.appInbox))
    }

    @Test("Eine Datei aus Documents/Inbox wird verschoben, es bleibt keine zweite Kopie")
    func documentsInboxFileIsMoved() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let incoming = IncomingFiles(appInbox: folders.appInbox, documentsInbox: folders.documentsInbox, purgeStale: false)
        let delivered = try folders.file(in: folders.documentsInbox, named: "Goodnotes.pdf")

        await incoming.receive(delivered)

        let file = try #require(incoming.pending.first)
        #expect(exists(file.url))
        #expect(!exists(delivered), "die Auslieferung in Documents/Inbox wurde verschoben, nicht kopiert")
        #expect((try FileManager.default.contentsOfDirectory(atPath: folders.documentsInbox.path)).isEmpty)
    }

    @Test("Regression: Eine zweite Datei wird nicht gelöscht, wenn die erste fertig ist")
    func finishingOneFileKeepsTheNext() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let incoming = IncomingFiles(appInbox: folders.appInbox, documentsInbox: folders.documentsInbox, purgeStale: false)
        await incoming.receive(try folders.file(in: folders.external, named: "Eins.pdf"))
        await incoming.receive(try folders.file(in: folders.external, named: "Zwei.pdf"))
        #expect(incoming.pending.map(\.originalName) == ["Eins.pdf", "Zwei.pdf"])
        let first = incoming.pending[0]
        let second = incoming.pending[1]

        incoming.finish(first)

        #expect(incoming.pending == [second])
        #expect(!exists(first.url))
        #expect(exists(second.url), "die nächste Datei liegt unberührt im Eingang")

        incoming.finish(first)  // finishing twice is harmless
        #expect(incoming.pending == [second])
        #expect(exists(second.url))

        incoming.finish(second)
        #expect(incoming.pending.isEmpty)
        #expect(!exists(second.url))
    }

    @Test("Unlesbare Datei: Fehlermeldung statt Absturz, nichts bleibt hängen")
    func missingFileReportsError() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let incoming = IncomingFiles(appInbox: folders.appInbox, documentsInbox: folders.documentsInbox, purgeStale: false)
        await incoming.receive(folders.external.appendingPathComponent("gibt-es-nicht.pdf"))
        #expect(incoming.pending.isEmpty)
        #expect(incoming.lastError?.contains("gibt-es-nicht.pdf") == true)
    }

    @Test("Beim Start werden alte Reste gelöscht, frisch gelieferte Dateien bleiben")
    func launchPurge() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let leftoverCopy = try folders.file(in: folders.appInbox, named: "alt.pdf", age: 5)
        let staleDelivery = try folders.file(in: folders.documentsInbox, named: "alt-geliefert.pdf", age: 3600)
        let freshDelivery = try folders.file(in: folders.documentsInbox, named: "neu.pdf")

        let incoming = IncomingFiles(appInbox: folders.appInbox, documentsInbox: folders.documentsInbox)
        await incoming.waitForPurge()

        #expect(!exists(leftoverCopy))
        #expect(!exists(staleDelivery))
        #expect(exists(freshDelivery), "die gerade gelieferte Datei wird gleich per onOpenURL übergeben")

        await incoming.receive(freshDelivery)
        #expect(incoming.pending.count == 1)
    }
}
