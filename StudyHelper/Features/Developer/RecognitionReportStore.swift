import Foundation
import Observation
import StudyCore
import StudyImport

/// Where the recognition error reports of the developer mode are kept: one JSON file in Application Support
/// (the `RecognitionReport` format of StudyCore, so the file can be read like an export). Writes are atomic, happen
/// on every change and run off the main thread (`ReportFileWriter`). A single broken entry is dropped on reading and
/// counted in `loadNote`; a file that is unreadable as a whole is moved aside and the list starts empty.
@MainActor
@Observable
final class RecognitionReportStore {
    private(set) var entries: [RecognitionReportEntry] = []
    private(set) var imports: [RecognitionReportImport] = []
    /// German note shown in the list when the stored file was damaged (nil otherwise).
    private(set) var loadNote: String?
    /// German message of the last failed write.
    var saveError: String?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let writer = ReportFileWriter()

    static let fileName = "RecognitionReports.json"

    /// - Parameter fileURL: the JSON file; nil keeps everything in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    /// Application Support/StudyHelper/RecognitionReports.json.
    static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return base.appendingPathComponent("StudyHelper", isDirectory: true).appendingPathComponent(fileName)
    }

    /// A store in a fresh temporary folder (UI tests).
    static func temporary() -> RecognitionReportStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecognitionReports-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(fileName)
        return RecognitionReportStore(fileURL: url)
    }

    // MARK: Queries

    var isEmpty: Bool { entries.isEmpty }

    func importInfo(for id: UUID) -> RecognitionReportImport? { imports.first { $0.id == id } }

    // MARK: Changes

    /// Adds an entry (and the import it belongs to, if not known yet).
    func add(_ entry: RecognitionReportEntry, importInfo: RecognitionReportImport? = nil) {
        entries.append(entry)
        if let importInfo {
            if let index = imports.firstIndex(where: { $0.id == importInfo.id }) {
                imports[index] = importInfo
            } else {
                imports.append(importInfo)
            }
        }
        persist()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        pruneImports()
        persist()
    }

    func deleteAll() {
        entries.removeAll()
        imports.removeAll()
        persist()
    }

    /// Forgets the "file was damaged" note.
    func clearLoadNote() { loadNote = nil }

    // MARK: Export

    /// The stored entries plus `extra` entries (e.g. corrections) as a report; imports are merged by id.
    func makeReport(
        extraEntries: [RecognitionReportEntry] = [], extraImports: [RecognitionReportImport] = [],
        date: Date = Date()
    ) -> RecognitionReport {
        var allImports = imports
        for info in extraImports where !allImports.contains(where: { $0.id == info.id }) {
            allImports.append(info)
        }
        return RecognitionReport(
            createdAt: date, app: .current(), imports: allImports, entries: entries + extraEntries)
    }

    // MARK: Persistence

    private func pruneImports() {
        let used = Set(entries.map(\.importID))
        imports.removeAll { !used.contains($0.id) }
    }

    private func persist() {
        guard let fileURL else { return }
        // The snapshot is a copy of value types; encoding and writing happen on the writer's queue, in order.
        let report = RecognitionReport(createdAt: Date(), app: .current(), imports: imports, entries: entries)
        writer.schedule(report, to: fileURL) { [weak self] failed in
            MainActor.assumeIsolated {
                self?.saveError = failed ? "Die Fehlerliste konnte nicht gespeichert werden." : nil
            }
        }
    }

    /// Waits until every scheduled write has finished (tests, and before reading the file back).
    func flushWrites() async {
        await writer.flush()
        await Task.yield()
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try LenientReportFile.decode(from: data)
            entries = file.entries
            imports = file.imports
            if file.droppedCount > 0 {
                let count = file.droppedCount
                loadNote = count == 1
                    ? "Ein beschädigter Eintrag der gespeicherten Fehlerliste wurde übersprungen. Die übrigen Einträge sind erhalten."
                    : "\(count) beschädigte Einträge der gespeicherten Fehlerliste wurden übersprungen. Die übrigen Einträge sind erhalten."
            }
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("RecognitionReports-beschaedigt-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                loadNote = "Die gespeicherte Fehlerliste war beschädigt und wurde durch eine leere ersetzt. Eine Kopie liegt als „\(backup.lastPathComponent)“ im App-Ordner."
            } catch {
                loadNote = "Die gespeicherte Fehlerliste war beschädigt und konnte nicht gesichert werden. Sie wird beim nächsten Eintrag überschrieben."
            }
            entries = []
            imports = []
        }
    }
}

// MARK: - Reading the file

/// The stored file read entry by entry: a broken entry or import is dropped (and counted), the rest is kept. Only a
/// file that is unreadable as a whole (no JSON, wrong format or version, no lists) throws.
nonisolated struct LenientReportFile {
    var imports: [RecognitionReportImport] = []
    var entries: [RecognitionReportEntry] = []
    /// Entries and imports that could not be read.
    var droppedCount = 0

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(T.self)
        }
    }

    private struct Envelope: Decodable {
        var format: String?
        var version: Int?
        var imports: [Lenient<RecognitionReportImport>]?
        var entries: [Lenient<RecognitionReportEntry>]?
    }

    static func decode(from data: Data) throws -> LenientReportFile {
        let envelope = try makeDecoder().decode(Envelope.self, from: data)
        guard envelope.format == RecognitionReport.formatIdentifier else { throw RecognitionReportError.wrongFormat(envelope.format) }
        guard let version = envelope.version, version >= 1, version <= RecognitionReport.currentVersion else {
            throw RecognitionReportError.unsupportedVersion(envelope.version)
        }
        var file = LenientReportFile()
        for item in envelope.imports ?? [] {
            if let value = item.value { file.imports.append(value) } else { file.droppedCount += 1 }
        }
        for item in envelope.entries ?? [] {
            if let value = item.value { file.entries.append(value) } else { file.droppedCount += 1 }
        }
        return file
    }

    /// Same date format as `RecognitionReport` (ISO 8601, with or without fractional seconds).
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let string = try c.decode(String.self)
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) { return date }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ungültiges Datum „\(string)“")
        }
        return decoder
    }
}

// MARK: - Writing the file

/// Writes the report file on a serial background queue, so that encoding (images make it large) never blocks the main
/// thread. Writes keep their order; a write that is still waiting when a newer snapshot arrives is skipped, because
/// every snapshot is the complete state.
nonisolated final class ReportFileWriter: @unchecked Sendable {
    private struct Job {
        let report: RecognitionReport
        let url: URL
        let completion: @Sendable (Bool) -> Void
    }

    private let queue = DispatchQueue(label: "StudyHelper.ReportFileWriter", qos: .utility)
    private let lock = NSLock()
    private var pending: Job?
    private var draining = false

    /// `completion(true)` is called on the main queue when the write failed.
    func schedule(_ report: RecognitionReport, to url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        let start: Bool = lock.withLock {
            pending = Job(report: report, url: url, completion: completion)
            let wasIdle = !draining
            draining = true
            return wasIdle
        }
        if start { queue.async { self.drain() } }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func drain() {
        while true {
            let job: Job? = lock.withLock {
                let next = pending
                pending = nil
                if next == nil { draining = false }
                return next
            }
            guard let job else { return }
            let failed: Bool
            do {
                try FileManager.default.createDirectory(
                    at: job.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try job.report.encodedJSON().write(to: job.url, options: .atomic)
                failed = false
            } catch {
                failed = true
            }
            DispatchQueue.main.async { job.completion(failed) }
        }
    }
}

// MARK: - App info

extension RecognitionReportApp {
    /// Version, commit, OS and device of this build.
    static func current() -> RecognitionReportApp {
        let environment = RecognitionEnvironment.current
        let commit = AppVersion.currentCommit
        return RecognitionReportApp(
            version: AppVersion.current, commit: commit == "unbekannt" ? nil : commit,
            os: environment.osVersion, device: environment.deviceModel)
    }
}
