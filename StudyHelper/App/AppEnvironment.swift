import Foundation
import Observation
import StudyData
import SwiftData
import SwiftUI

/// Long-lived app objects, created once at launch.
@MainActor
final class AppServices {
    let container: ModelContainer
    let repository: StudyRepository
    let incomingFiles: IncomingFiles

    init(container: ModelContainer) {
        self.container = container
        self.repository = StudyRepository(container: container)
        self.incomingFiles = IncomingFiles()
    }
}

@MainActor
enum AppEnvironment {
    case ready(AppServices)
    case failed(String)

    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        do {
            let inMemory = arguments.contains("-uiTestInMemory")
            let container = try ModelContainerFactory.makeContainer(inMemory: inMemory)
            let services = AppServices(container: container)
            if inMemory, arguments.contains("-uiTestSeed") {
                try UITestSeeder.seed(services.repository, withVersions: arguments.contains("-uiTestSeedVersions"))
            }
            return .ready(services)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Repository in the environment

private struct StudyRepositoryKey: EnvironmentKey {
    static let defaultValue: StudyRepository? = nil
}

extension EnvironmentValues {
    /// The app's repository. Always set by `StudyHelperApp`; nil only in previews without setup.
    var studyRepository: StudyRepository? {
        get { self[StudyRepositoryKey.self] }
        set { self[StudyRepositoryKey.self] = newValue }
    }
}

// MARK: - Files opened via "Öffnen in StudyHelper"

/// PDFs handed to the app by other apps (e.g. Goodnotes "Teilen → Exportieren → PDF").
/// Each file is taken into the app's own inbox right away (moved if iOS already put it into our
/// `Documents/Inbox`, copied otherwise); the import UI picks them up from `pending`, asks for the
/// subject and starts the import. `pending` is not persisted, so everything left in the inboxes at
/// launch is stale and gets purged.
@MainActor
@Observable
final class IncomingFiles {
    struct File: Identifiable, Hashable {
        let id = UUID()
        /// Copy inside the app container (Application Support/StudyHelper/Inbox).
        let url: URL
        let originalName: String
    }

    private(set) var pending: [File] = []
    /// German error message of the last failed hand-over, for an alert.
    var lastError: String?

    @ObservationIgnored private let appInbox: URL?
    @ObservationIgnored private let documentsInbox: URL?
    @ObservationIgnored private var purgeTask: Task<Void, Never>?

    /// Files in `Documents/Inbox` younger than this survive the launch purge: on a cold start "Öffnen in"
    /// puts the file there just before `onOpenURL` delivers it.
    nonisolated static let freshFileGrace: TimeInterval = 60

    /// - Parameters:
    ///   - appInbox: where files are kept while pending; nil uses Application Support/StudyHelper/Inbox.
    ///   - documentsInbox: the folder iOS delivers "Öffnen in" files to; nil uses Documents/Inbox.
    ///   - purgeStale: delete leftovers of earlier sessions right away (in the background).
    init(appInbox: URL? = nil, documentsInbox: URL? = nil, purgeStale: Bool = true) {
        self.appInbox = appInbox
        self.documentsInbox = documentsInbox
        if purgeStale {
            let launch = Date()
            purgeTask = Task { [appInbox, documentsInbox] in
                await Self.purge(appInbox: appInbox, documentsInbox: documentsInbox, launchDate: launch)
            }
        }
    }

    /// Takes over a file. The file work runs off the main actor; `pending` grows when it is done.
    func receive(_ url: URL) async {
        await purgeTask?.value
        let name = url.lastPathComponent
        do {
            let target = try await Self.ingest(url, appInbox: appInbox, documentsInbox: documentsInbox)
            pending.append(File(url: target, originalName: name))
        } catch {
            lastError = "Die Datei „\(name)“ konnte nicht übernommen werden."
        }
    }

    /// Call when the import of `file` finished or the user discarded it; deletes the inbox copy.
    /// Only this file is removed; other pending files are untouched.
    func finish(_ file: File) {
        pending.removeAll { $0.id == file.id }
        try? FileManager.default.removeItem(at: file.url)
    }

    /// Waits for the launch purge (tests).
    func waitForPurge() async { await purgeTask?.value }

    // MARK: File work (off the main actor)

    nonisolated static func inboxDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("StudyHelper/Inbox", isDirectory: true)
    }

    nonisolated static func systemDocumentsInbox() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// True if `url` lies inside `folder` (symlinks like /var → /private/var resolved).
    nonisolated static func isInside(_ url: URL, folder: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Moves the file into the app inbox if it already lies in our own container's `Documents/Inbox`
    /// (no second copy that would leak), copies it otherwise (security-scoped file from another app).
    @concurrent
    nonisolated static func ingest(_ url: URL, appInbox: URL?, documentsInbox: URL?) async throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let inbox = try appInbox ?? inboxDirectory()
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let target = inbox.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        if let documentsInbox = documentsInbox ?? systemDocumentsInbox(), isInside(url, folder: documentsInbox) {
            do {
                try manager.moveItem(at: url, to: target)
                return target
            } catch {
                try manager.copyItem(at: url, to: target)
                try? manager.removeItem(at: url)
                return target
            }
        }
        try manager.copyItem(at: url, to: target)
        return target
    }

    /// Deletes what earlier sessions left behind: everything in the app inbox, and files in `Documents/Inbox`
    /// that are older than `freshFileGrace` before `launchDate`.
    @concurrent
    nonisolated static func purge(appInbox: URL?, documentsInbox: URL?, launchDate: Date) async {
        let manager = FileManager.default
        if let inbox = appInbox ?? (try? inboxDirectory()),
           let items = try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) {
            for item in items { try? manager.removeItem(at: item) }
        }
        if let inbox = documentsInbox ?? systemDocumentsInbox(),
           let items = try? manager.contentsOfDirectory(
               at: inbox, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]) {
            let cutoff = launchDate.addingTimeInterval(-freshFileGrace)
            for item in items {
                let values = try? item.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let newest = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max()
                if let newest, newest > cutoff { continue }
                try? manager.removeItem(at: item)
            }
        }
    }
}
