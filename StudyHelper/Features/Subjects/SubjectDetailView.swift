import StudyCore
import StudyData
import SwiftData
import SwiftUI

/// One subject: its imports, its topics and the terms that help text recognition.
struct SubjectDetailView: View {
    let subject: Subject
    @Environment(\.studyRepository) private var repository
    @Environment(ImportCoordinator.self) private var coordinator
    /// Id and alert text, taken when the user asks: the alert must not read the batch while it is being deleted.
    @State private var batchToDelete: PendingBatchDeletion?
    @State private var newTerm = ""
    @State private var errorMessage: String?
    @State private var topicModel = TopicListModel()

    private var batches: [ImportBatch] {
        subject.imports.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                ImportMenu(subject: subject)
            }

            Section("Importe") {
                if batches.isEmpty {
                    Text("Noch kein Lernstoff importiert. Importiere Fotos, einen Scan, ein PDF oder einen Goodnotes-Export.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(batches) { batch in
                    NavigationLink {
                        ReviewScreen(batch: batch)
                    } label: {
                        BatchRow(batch: batch)
                    }
                    .accessibilityIdentifier("importRow")
                    .swipeActions(edge: .trailing) {
                        Button("Löschen", systemImage: "trash", role: .destructive) { batchToDelete = PendingBatchDeletion(id: batch.id, message: deleteMessage(for: batch)) }
                    }
                    BatchActions(batch: batch)
                }
            }

            if coordinator.affectedSubjectID == subject.id, !coordinator.affectedTopics.isEmpty {
                Section {
                    AffectedTopicsBanner(topics: coordinator.affectedTopics) { topicModel.openedTopicID = $0 } onDismiss: {
                        coordinator.dismissImpact()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            TopicsSection(subject: subject, model: topicModel)

            Section {
                ForEach(subject.confirmedTerms, id: \.self) { term in
                    Text(term)
                        .swipeActions {
                            Button("Entfernen", systemImage: "trash", role: .destructive) { remove(term) }
                        }
                }
                HStack {
                    TextField("Fachbegriff hinzufügen", text: $newTerm)
                        .submitLabel(.done)
                        .onSubmit(addTerm)
                        .accessibilityIdentifier("newTermField")
                    Button("Hinzufügen", systemImage: "plus.circle.fill", action: addTerm)
                        .labelStyle(.iconOnly)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Fachbegriffe für die Erkennung")
            } footer: {
                Text("Diese Wörter helfen der Texterkennung bei Fachwörtern. Beim Korrigieren einer Zeile kannst du Wörter hier aufnehmen.")
            }
        }
        .navigationTitle(subject.name)
        .navigationBarTitleDisplayMode(.large)
        .topicListDialogs(subject: subject, model: topicModel)
        .navigationDestination(item: $topicModel.openedTopicID) { id in
            TopicLookupView(subject: subject, topicID: id)
        }
        .alert(
            "Import löschen?",
            isPresented: Binding(get: { batchToDelete != nil }, set: { if !$0 { batchToDelete = nil } }),
            presenting: batchToDelete
        ) { pending in
            Button("Löschen", role: .destructive) { delete(pending) }
            Button("Abbrechen", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        .errorAlert($errorMessage)
    }

    private func deleteMessage(for batch: ImportBatch) -> String {
        var text = "Der Import wird mit allen Seiten, erkannten Texten und Korrekturen gelöscht. Das kann nicht rückgängig gemacht werden."
        let topics = TopicImpact.using(sourceIDs: Set(batch.sources.map(\.id)), in: subject)
        if !topics.isEmpty {
            text += " Diese Themen verwenden den Import und verlieren die Quelle ihrer Einträge: "
                + topics.map { "„\($0.title)“" }.joined(separator: ", ") + "."
        }
        return text
    }

    private func delete(_ pending: PendingBatchDeletion) {
        guard let batch = subject.imports.first(where: { $0.id == pending.id }) else { batchToDelete = nil; return }
        do { try coordinator.deleteBatch(batch) } catch { errorMessage = error.localizedDescription }
        batchToDelete = nil
    }

    private func addTerm() {
        do {
            try repository?.addConfirmedTerm(newTerm, to: subject)
            newTerm = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ term: String) {
        do { try repository?.removeConfirmedTerm(term, from: subject) } catch { errorMessage = error.localizedDescription }
    }
}

private struct PendingBatchDeletion: Equatable {
    let id: UUID
    let message: String
}

private struct BatchRow: View {
    let batch: ImportBatch
    @Environment(ImportCoordinator.self) private var coordinator
    @State private var summaryCache = DerivedValue<BatchSummary>()

    private var title: String {
        batch.originalFileName ?? batch.kind.germanName
    }

    var body: some View {
        let summary = summaryCache.value(key: batch.id) { BatchSummary(batch) }
        let isActive = coordinator.activeBatchID == batch.id
        HStack(spacing: 12) {
            Image(systemName: batch.kind.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(2)
                Text("\(batch.kind.germanName) · \(summary.pages == 1 ? "1 Seite" : "\(summary.pages) Seiten") · \(batch.createdAt.germanShort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isActive {
                    Label("wird erkannt…", systemImage: "hourglass").font(.caption).foregroundStyle(.blue)
                } else if summary.unreadablePages > 0 {
                    Label(
                        summary.unreadablePages == 1 ? "1 Seite beschädigt" : "\(summary.unreadablePages) Seiten beschädigt",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                } else if summary.failed > 0 {
                    Label(summary.failed == 1 ? "1 Seite fehlgeschlagen" : "\(summary.failed) Seiten fehlgeschlagen", systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                } else if summary.waiting > 0 {
                    Label(summary.waiting == 1 ? "1 Seite wartet auf Erkennung" : "\(summary.waiting) Seiten warten auf Erkennung", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if summary.open > 0 {
                Text("\(summary.open)")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(.orange.opacity(0.25), in: Capsule())
                    .accessibilityLabel("\(PageWordReview.description(words: summary.openWords, illegible: summary.illegible)) offen")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Buttons for imports that are not completely recognized.
private struct BatchActions: View {
    let batch: ImportBatch
    @Environment(ImportCoordinator.self) private var coordinator

    var body: some View {
        let isActive = coordinator.activeBatchID == batch.id
        let waiting = batch.sources.contains { $0.digitizationState == .pending }
        let failed = batch.sources.contains { $0.digitizationState == .failed }
        if !isActive, waiting || failed {
            Button {
                if waiting { coordinator.recognizePending(in: batch) } else { coordinator.retryFailed(in: batch) }
            } label: {
                Label(waiting ? "Jetzt erkennen" : "Erneut versuchen", systemImage: "text.viewfinder")
            }
            .disabled(coordinator.isRunning)
            .accessibilityIdentifier("recognizePendingButton")
        }
    }
}
