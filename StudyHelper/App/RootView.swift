import StudyData
import SwiftUI

/// Root of the app: subjects, with the import progress strip and the hand-over of files opened via "Öffnen in".
struct RootView: View {
    @Environment(\.studyRepository) private var repository

    var body: some View {
        if let repository {
            MainView(repository: repository)
        } else {
            ContentUnavailableView("Keine Daten", systemImage: "externaldrive.badge.xmark")
        }
    }
}

private struct MainView: View {
    @State private var coordinator: ImportCoordinator
    @State private var presentedFile: IncomingFiles.File?
    @Environment(IncomingFiles.self) private var incomingFiles

    init(repository: StudyRepository) {
        _coordinator = State(initialValue: ImportCoordinator(repository: repository))
    }

    var body: some View {
        NavigationStack {
            SubjectListView()
        }
        .environment(coordinator)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ImportStatusStrip()
                .environment(coordinator)
        }
        // One sheet per incoming file, presented by that file's identity. The sheet finishes (deletes) only
        // its own file; the next pending file follows after the sheet is gone.
        .sheet(item: $presentedFile, onDismiss: presentNextFile) { file in
            PDFImportSheet(subject: nil, urls: [file.url], incoming: file)
                .environment(coordinator)
        }
        .onChange(of: incomingFiles.pending.map(\.id), initial: true) { presentNextFile() }
        .alert("Datei konnte nicht übernommen werden", isPresented: Binding(
            get: { incomingFiles.lastError != nil },
            set: { if !$0 { incomingFiles.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(incomingFiles.lastError ?? "")
        }
        .errorAlert(Binding(get: { coordinator.errorMessage }, set: { coordinator.errorMessage = $0 }))
    }

    private func presentNextFile() {
        guard presentedFile == nil, let next = incomingFiles.pending.first else { return }
        presentedFile = next
    }
}

/// Progress of the running import ("Seite 2 von 5 wird erkannt…") with cancel, or the summary of the last one.
private struct ImportStatusStrip: View {
    @Environment(ImportCoordinator.self) private var coordinator

    var body: some View {
        if let progress = coordinator.progress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(progress.title).font(.footnote.weight(.semibold))
                    Spacer()
                    Button("Abbrechen", role: .cancel) { coordinator.cancel() }
                        .font(.footnote.weight(.semibold))
                        .disabled(progress.isCancelling)
                        .accessibilityIdentifier("cancelImportButton")
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(progress.message).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("importProgress")
        } else if let notice = coordinator.notice {
            HStack(alignment: .firstTextBaseline) {
                Text(notice).font(.footnote)
                Spacer()
                Button("OK") { coordinator.notice = nil }
                    .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityIdentifier("importNotice")
        }
    }
}

#Preview {
    RootView()
}
