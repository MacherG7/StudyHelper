import StudyData
import SwiftData
import SwiftUI

/// Entry point of StudyHelper.
///
/// Launch arguments for UI tests:
/// - `-uiTestInMemory`: use an in-memory store (no data on disk); the review's spell checker is a fixed word list
/// - `-uiTestSeed`: additionally fill it with demo data (`UITestSeeder`)
/// - `-uiTestSeedVersions`: with `-uiTestSeed`, the demo page has a second version
/// - `-uiTestSeedReports`: with `-uiTestInMemory`, the developer error list holds one demo entry
/// - `-uiTestUnknownWords a,b`: with `-uiTestInMemory`, the review's spell checker does not know these words
/// - `-uiTestMockAI`: with `-uiTestInMemory`, every AI provider kind is a mock (no network, in-memory keys)
@main
struct StudyHelperApp: App {
    @State private var environment = AppEnvironment.make()

    var body: some Scene {
        WindowGroup {
            Group {
                switch environment {
                case .ready(let app):
                    RootView()
                        .modelContainer(app.container)
                        .environment(\.studyRepository, app.repository)
                        .environment(\.digitalPageStore, app.digitalPages)
                        .environment(app.incomingFiles)
                        .environment(app.ai)
                        .environment(app.reports)
                        .onOpenURL { url in Task { await app.incomingFiles.receive(url) } }
                case .failed(let message):
                    ContentUnavailableView(
                        "Daten konnten nicht geladen werden",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
        }
    }
}
