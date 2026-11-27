import StudyData
import SwiftData
import SwiftUI

/// Start screen: the subjects (SPEC §1: "Lernstoff wird einem Fach zugeordnet").
struct SubjectListView: View {
    @Environment(ImportCoordinator.self) private var coordinator
    @Query(sort: [SortDescriptor(\Subject.sortIndex), SortDescriptor(\Subject.createdAt)])
    private var subjects: [Subject]

    @State private var nameSheet: SubjectNameSheet.Mode?
    @State private var subjectToDelete: Subject?
    @State private var showSettings = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(subjects) { subject in
                NavigationLink {
                    SubjectDetailView(subject: subject)
                } label: {
                    SubjectRow(subject: subject)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Löschen", systemImage: "trash", role: .destructive) { requestDelete(subject) }
                    Button("Umbenennen", systemImage: "pencil") { nameSheet = .rename(subject) }
                        .tint(.blue)
                }
                .contextMenu {
                    Button("Umbenennen", systemImage: "pencil") { nameSheet = .rename(subject) }
                    Button("Löschen", systemImage: "trash", role: .destructive) { requestDelete(subject) }
                }
                .accessibilityIdentifier("subject-\(subject.name)")
            }
        }
        .accessibilityIdentifier("subjectList")
        .overlay {
            if subjects.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Fächer", systemImage: "books.vertical")
                } description: {
                    Text("Lege dein erstes Fach an, zum Beispiel Mathe oder Deutsch, und importiere dann deinen Lernstoff.")
                } actions: {
                    Button("Fach anlegen") { nameSheet = .add }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("addFirstSubjectButton")
                }
            }
        }
        .navigationTitle("StudyHelper")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier("settingsButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fach hinzufügen", systemImage: "plus") { nameSheet = .add }
                    .accessibilityIdentifier("addSubjectButton")
            }
        }
        .sheet(item: $nameSheet) { mode in
            SubjectNameSheet(mode: mode)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert(
            "Fach löschen?",
            isPresented: Binding(get: { subjectToDelete != nil }, set: { if !$0 { subjectToDelete = nil } }),
            presenting: subjectToDelete
        ) { subject in
            Button("Löschen", role: .destructive) { delete(subject) }
            Button("Abbrechen", role: .cancel) {}
        } message: { subject in
            Text("„\(subject.name)“ wird mit allen Importen, erkannten Texten, Korrekturen und Themen gelöscht. Das kann nicht rückgängig gemacht werden.")
        }
        .errorAlert($errorMessage)
    }

    /// A subject with a running import cannot be deleted (the job writes into it).
    private func requestDelete(_ subject: Subject) {
        if coordinator.isBusy(with: subject) {
            errorMessage = ImportFailure.subjectBusy.errorDescription
        } else {
            subjectToDelete = subject
        }
    }

    private func delete(_ subject: Subject) {
        do { try coordinator.deleteSubject(subject) } catch { errorMessage = error.localizedDescription }
        subjectToDelete = nil
    }
}

private struct SubjectRow: View {
    let subject: Subject
    @State private var loader = PageSummaryLoader()

    var body: some View {
        // Imports are cheap; the open counts are computed in the background ("…" until they are ready).
        let reviewed = loader.pages
        let summary = SubjectSummary(subject, reviewed: reviewed ?? [])
        VStack(alignment: .leading, spacing: 2) {
            Text(subject.name).font(.headline)
            HStack(spacing: 8) {
                Text(summary.imports == 1 ? "1 Import" : "\(summary.imports) Importe")
                if summary.unreadablePages > 0 {
                    Text("beschädigt")
                        .foregroundStyle(.red)
                        .accessibilityLabel(summary.unreadablePages == 1 ? "1 Seite beschädigt" : "\(summary.unreadablePages) Seiten beschädigt")
                }
                if reviewed == nil, summary.imports > 0 {
                    Text("…")
                        .accessibilityLabel("Offene Stellen werden gezählt")
                        .accessibilityIdentifier("subjectCountPlaceholder")
                } else if summary.open > 0 {
                    Text("\(summary.open) offen")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(PageWordReview.description(words: summary.openWords, illegible: summary.illegible)) offen")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .task(priority: .utility) {
            let checker = AppSpellChecker.shared
            await loader.run(sources: { subject.imports.flatMap(\.sources) }, checker: checker)
        }
    }
}

/// Add or rename a subject.
struct SubjectNameSheet: View {
    enum Mode: Identifiable {
        case add
        case rename(Subject)

        var id: String {
            switch self {
            case .add: "add"
            case .rename(let subject): subject.id.uuidString
            }
        }
    }

    let mode: Mode
    /// Called with the new subject after "Neues Fach" was saved.
    var onCreated: ((Subject) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var title: String {
        switch mode {
        case .add: "Neues Fach"
        case .rename: "Fach umbenennen"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, z. B. Biologie", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("subjectNameField")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveSubjectButton")
                }
            }
            .errorAlert($errorMessage)
            .onAppear {
                if case .rename(let subject) = mode { name = subject.name }
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            switch mode {
            case .add:
                if let created = try repository?.createSubject(name: name) { onCreated?(created) }
            case .rename(let subject): try repository?.renameSubject(subject, to: name)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
