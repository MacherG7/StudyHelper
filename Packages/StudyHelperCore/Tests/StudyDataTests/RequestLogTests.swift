import Foundation
import SwiftData
import Testing

@testable import StudyData

@MainActor
private func makeRepo() throws -> StudyRepository {
    StudyRepository(container: try ModelContainerFactory.makeContainer(inMemory: true))
}

@MainActor
@Suite("Anfrage-Log")
struct RequestLogTests {
    @Test("Einträge werden gespeichert und neueste zuerst gelistet")
    func addAndList() throws {
        let repo = try makeRepo()
        for i in 0..<3 {
            try repo.addRequestLog(RequestLogEntry(
                date: Date(timeIntervalSince1970: Double(i) * 100), task: "chat", providerKind: "mock",
                providerName: "Mock", model: "m\(i)", inputTokens: i))
        }
        let all = try repo.requestLogs()
        #expect(all.map(\.model) == ["m2", "m1", "m0"])
        #expect(try repo.requestLogs(limit: 2).count == 2)
        #expect(all[0].inputTokens == 2)
        #expect(all[0].outputTokens == nil)
    }

    @Test("Fehlgeschlagene Anfragen werden mit Fehlertext gespeichert")
    func failedRequest() throws {
        let repo = try makeRepo()
        try repo.addRequestLog(RequestLogEntry(
            task: "query", providerKind: "claude", providerName: "Claude", model: "x",
            errorMessage: "Der API-Key wurde abgelehnt."))
        #expect(try repo.requestLogs()[0].errorMessage == "Der API-Key wurde abgelehnt.")
    }

    @Test("Alle Einträge löschen")
    func deleteAll() throws {
        let repo = try makeRepo()
        try repo.addRequestLog(RequestLogEntry(task: "chat", providerKind: "mock", providerName: "M", model: "m"))
        try repo.deleteAllRequestLogs()
        #expect(try repo.requestLogs().isEmpty)
    }

    @Test("Export: Array mit Detail als JSON, nicht Base64")
    func export() throws {
        let repo = try makeRepo()
        let detail = Data(#"{"rawRequest":"hallo","units":["a","b"]}"#.utf8)
        try repo.addRequestLog(RequestLogEntry(
            task: "chat", providerKind: "mock", providerName: "M", model: "m", costUSD: 0.5, costKnown: true,
            detailJSON: detail))
        try repo.addRequestLog(RequestLogEntry(
            task: "chat", providerKind: "mock", providerName: "M", model: "kaputt", detailJSON: Data("kein json".utf8)))
        let data = try repo.exportRequestLogsJSON()
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(array.count == 2)
        let withDetail = try #require(array.first { $0["model"] as? String == "m" })
        let parsed = try #require(withDetail["detail"] as? [String: Any])
        #expect(parsed["rawRequest"] as? String == "hallo")
        #expect(parsed["units"] as? [String] == ["a", "b"])
        #expect(withDetail["costUSD"] as? Double == 0.5)
        let broken = try #require(array.first { $0["model"] as? String == "kaputt" })
        #expect(broken["detailText"] as? String == "kein json")
    }
}

@MainActor
@Suite("Schema-Migration V1 nach V2")
struct MigrationTests {
    /// Copies the committed V1 store (made with the shipped V1 code) to a temp directory.
    private func copyFixture() throws -> (URL, URL) {
        let source = try #require(Bundle.module.url(forResource: "Resources/StoreV1", withExtension: nil))
        let dir = FileManager.default.temporaryDirectory.appending(path: "Migration-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: dir)
        return (dir, dir.appending(path: "StudyHelper.store"))
    }

    @Test("V1-Datenbank wird geöffnet, alle Daten bleiben erhalten, Anfrage-Log nutzbar")
    func migratesV1() throws {
        let (dir, url) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: ".StudyHelper_SUPPORT").path))

        let container = try ModelContainerFactory.makeContainer(url: url)
        let repo = StudyRepository(container: container)
        let subject = try #require(try repo.subjects().first)
        #expect(subject.name == "Physik")
        #expect(subject.confirmedTerms == ["Impuls"])
        let batch = try #require(subject.imports.first)
        #expect(batch.originalFileName == "Notiz.pdf")
        #expect(batch.originalPDF == Data([9, 9]))
        #expect(batch.reducedPDF == Data([8]))
        let source = try #require(batch.sources.first)
        #expect(source.imageData == Data(repeating: 7, count: 300_000))
        let digitization = try #require(source.currentDigitization)
        #expect(digitization.lines[0].text == "Kraft gleich Masse mal Beschleunigung")
        #expect(!digitization.hasUnreadableData)
        let topic = try #require(subject.topics.first)
        #expect(topic.title == "Mechanik")
        #expect(topic.sources.map(\.id) == [source.id])
        #expect(topic.entries[0].tableData?.headers == ["x"])

        try repo.addRequestLog(RequestLogEntry(task: "chat", providerKind: "mock", providerName: "M", model: "m"))
        #expect(try repo.requestLogs().count == 1)
    }

    @Test("Nach der Migration überleben beide Datenbestände ein erneutes Öffnen")
    func reopenAfterMigration() throws {
        let (dir, url) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let repo = StudyRepository(container: try ModelContainerFactory.makeContainer(url: url))
            try repo.addRequestLog(RequestLogEntry(task: "chat", providerKind: "mock", providerName: "M", model: "m"))
        }
        let repo = StudyRepository(container: try ModelContainerFactory.makeContainer(url: url))
        #expect(try repo.subjects().count == 1)
        #expect(try repo.requestLogs().count == 1)
    }
}
