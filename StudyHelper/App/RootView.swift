import StudyCore
import SwiftUI

/// Placeholder start screen until subjects and import arrive in Phase 1.
struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Noch keine Fächer", systemImage: "books.vertical")
            } description: {
                Text("Hier erscheinen bald deine Fächer und dein Lernstoff.")
            }
            .navigationTitle("StudyHelper")
            .toolbar {
                ToolbarItem(placement: .status) {
                    Text("Core \(StudyCore.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("coreVersion")
                }
            }
        }
    }
}

#Preview {
    RootView()
}
