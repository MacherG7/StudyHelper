import StudyData
import SwiftUI

/// App settings: recognition (Phase 1), AI providers, tasks, costs, developer mode (Phase 2) and the app version.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var multiPass = StudySettings().multiPassRecognition

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Mehrfacherkennung (genauer, dauert länger)", isOn: $multiPass)
                        .accessibilityIdentifier("multiPassToggle")
                } header: {
                    Text("Texterkennung")
                } footer: {
                    Text("Bei der Mehrfacherkennung wird jede Seite zweimal gelesen. Wörter, bei denen sich die Ergebnisse unterscheiden, werden als unsicher markiert. Die Fachbegriffe für die Erkennung pflegst du im jeweiligen Fach.")
                }
                AISettingsSections()
                Section {
                    LabeledContent("Version", value: AppVersion.current)
                        .accessibilityIdentifier("appVersion")
                    LabeledContent("Commit") {
                        Text(AppVersion.currentCommit)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("appCommit")
                } header: {
                    Text("Über StudyHelper")
                } footer: {
                    if AppVersion.hasLocalChanges(info: Bundle.main.infoDictionary) {
                        Text("* Mit lokalen, noch nicht committeten Änderungen gebaut.")
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onChange(of: multiPass) { _, newValue in
                StudySettings().multiPassRecognition = newValue
            }
        }
    }
}
