import Observation
import StudyData
import SwiftUI

/// State of the topic list's sheets and alerts (kept outside the `Section`, see `topicListDialogs`).
@MainActor
@Observable
final class TopicListModel {
    var titleSheet: TopicTitleSheet.Mode?
    /// Id and title only: the alert must not read a model that is deleted while the alert is dismissed.
    var topicToDelete: AffectedTopic?
    var mergeSource: Topic?
    var splitSource: Topic?
    /// Set to open a topic (e.g. right after creating it).
    var openedTopicID: UUID?
}

/// The "Themen" section of a subject: topics with status and the actions rename, delete, merge and split.
/// The sheets and alerts belong to the list: apply `topicListDialogs` to the enclosing `List`.
struct TopicsSection: View {
    let subject: Subject
    let model: TopicListModel
    @Environment(\.studyRepository) private var repository

    var body: some View {
        let topics = repository?.topics(in: subject) ?? []
        Section {
            if topics.isEmpty {
                Text("Noch keine Themen. Lege ein Thema an und übernimm Inhalte aus deinem Lernstoff.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("topicsEmptyHint")
            }
            ForEach(topics) { topic in
                NavigationLink {
                    TopicScreen(topic: topic)
                } label: {
                    TopicRow(topic: topic)
                }
                .accessibilityIdentifier("topic-\(topic.title)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Not `role: .destructive`: that would remove the row visually even if the user cancels the alert.
                    Button("Löschen", systemImage: "trash") { model.topicToDelete = AffectedTopic(topic) }
                        .tint(.red)
                    Button("Umbenennen", systemImage: "pencil") { model.titleSheet = .rename(topic) }
                        .tint(.blue)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button("Zusammenlegen", systemImage: "arrow.triangle.merge") { model.mergeSource = topic }
                        .tint(.indigo)
                    Button("Aufteilen", systemImage: "arrow.triangle.branch") { model.splitSource = topic }
                        .tint(.teal)
                }
                .contextMenu {
                    Button("Umbenennen", systemImage: "pencil") { model.titleSheet = .rename(topic) }
                    Button("Zusammenlegen mit …", systemImage: "arrow.triangle.merge") { model.mergeSource = topic }
                    Button("Thema aufteilen …", systemImage: "arrow.triangle.branch") { model.splitSource = topic }
                    Button("Löschen", systemImage: "trash", role: .destructive) { model.topicToDelete = AffectedTopic(topic) }
                }
            }
            Button("Thema anlegen", systemImage: "plus.circle.fill") { model.titleSheet = .add }
                .accessibilityIdentifier("addTopicButton")
        } header: {
            Text("Themen")
        }
    }
}

private struct TopicListDialogs: ViewModifier {
    let subject: Subject
    @Bindable var model: TopicListModel
    @Environment(\.studyRepository) private var repository
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.titleSheet) { mode in
                TopicTitleSheet(subject: subject, mode: mode) { created in model.openedTopicID = created.id }
            }
            .sheet(item: $model.mergeSource) { topic in
                // Values, not the model: the merged topic is deleted while the confirmation is dismissed.
                let sourceTitle = topic.title
                let sourceConfirmed = topic.isConfirmed
                TopicChoiceSheet(
                    title: "Zusammenlegen mit …",
                    explanation: "Alle Einträge und Quellen von „\(sourceTitle)“ wandern in das gewählte Thema. „\(sourceTitle)“ wird danach gelöscht.",
                    topics: (repository?.topics(in: subject) ?? []).filter { $0 !== topic },
                    confirmTitle: { "„\(sourceTitle)“ mit „\($0.title)“ zusammenlegen?" },
                    confirmMessage: { TopicMergeHint.text(mergingTitle: sourceTitle, isConfirmed: sourceConfirmed, into: $0) },
                    confirmButton: "Zusammenlegen"
                ) { target in
                    try repository?.merge(topic, into: target)
                    // The merged topic is gone: drop it from the sheet state before anything reads it again.
                    model.mergeSource = nil
                }
            }
            .sheet(item: $model.splitSource) { topic in
                SplitTopicSheet(topic: topic) { created in model.openedTopicID = created.id }
            }
            .alert(
                "Thema löschen?",
                isPresented: Binding(get: { model.topicToDelete != nil }, set: { if !$0 { model.topicToDelete = nil } }),
                presenting: model.topicToDelete
            ) { topic in
                Button("Löschen", role: .destructive) { delete(topic) }
                    .accessibilityIdentifier("confirmDeleteTopicButton")
                Button("Abbrechen", role: .cancel) {}
            } message: { topic in
                Text("„\(topic.title)“ wird mit allen Einträgen gelöscht. Die Seiten und ihr Text bleiben erhalten. Das kann nicht rückgängig gemacht werden.")
            }
            .errorAlert($errorMessage)
    }

    private func delete(_ ref: AffectedTopic) {
        // Look the topic up again: it may be gone already.
        if let topic = subject.topic(withID: ref.id) {
            do { try repository?.deleteTopic(topic) } catch { errorMessage = error.localizedDescription }
        }
        model.topicToDelete = nil
    }
}

extension View {
    /// Sheets and alerts of `TopicsSection` (create, rename, merge, split, delete).
    func topicListDialogs(subject: Subject, model: TopicListModel) -> some View {
        modifier(TopicListDialogs(subject: subject, model: model))
    }
}

struct TopicRow: View {
    let topic: Topic

    var body: some View {
        let entries = topic.entries.count
        let pages = topic.sources.count
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title).font(.headline).lineLimit(3)
                Text("\(entries == 1 ? "1 Eintrag" : "\(entries) Einträge") · \(pages == 1 ? "1 Seite" : "\(pages) Seiten")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if topic.needsReconfirmation {
                    Label("Nach Bestätigung geändert – erneut bestätigen", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if topic.openSupplementCount > 0 {
                    Label(
                        topic.openSupplementCount == 1 ? "1 KI-Ergänzung offen" : "\(topic.openSupplementCount) KI-Ergänzungen offen",
                        systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            Spacer(minLength: 4)
            TopicStatusBadge(status: TopicStatus(topic))
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Bestätigt", "Geändert" (confirmed, edited since) or "Entwurf".
struct TopicStatusBadge: View {
    let status: TopicStatus

    var body: some View {
        Label(status.germanName, systemImage: status.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == .draft ? Color.secondary : status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.15), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a merge does to the status of the target topic (shown in the confirmation).
enum TopicMergeHint {
    static func text(mergingTitle sourceTitle: String, isConfirmed sourceConfirmed: Bool, into target: Topic) -> String? {
        guard target.isConfirmed else { return nil }
        if !sourceConfirmed {
            return "„\(sourceTitle)“ ist noch nicht bestätigt. „\(target.title)“ wird dadurch wieder zum Entwurf und muss erneut bestätigt werden."
        }
        return "„\(target.title)“ muss danach erneut bestätigt werden, weil neue Inhalte dazukommen."
    }
}

/// Create a topic or rename one. The title is the only required field.
struct TopicTitleSheet: View {
    enum Mode: Identifiable {
        case add
        case rename(Topic)

        var id: String {
            switch self {
            case .add: "add"
            case .rename(let topic): topic.id.uuidString
            }
        }
    }

    let subject: Subject
    let mode: Mode
    var onCreated: ((Topic) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var title = ""
    @State private var showValidation = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var isEmpty: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel, z. B. Fotosynthese", text: $title)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("topicTitleField")
                } footer: {
                    if showValidation, isEmpty {
                        Text("Gib dem Thema einen Titel. Alle anderen Felder sind freiwillig.")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("topicTitleValidation")
                    }
                }
            }
            .navigationTitle({ if case .add = mode { "Neues Thema" } else { "Thema umbenennen" } }())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).accessibilityIdentifier("saveTopicButton")
                }
            }
            .errorAlert($errorMessage)
            .onAppear {
                if case .rename(let topic) = mode { title = topic.title }
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard !isEmpty else { showValidation = true; return }
        do {
            switch mode {
            case .add:
                if let topic = try repository?.createTopic(in: subject, title: title) { onCreated?(topic) }
            case .rename(let topic):
                try repository?.renameTopic(topic, to: title)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Pick another topic (merge target, new home of a source) and confirm.
struct TopicChoiceSheet: View {
    let title: String
    let explanation: String
    let topics: [Topic]
    let confirmTitle: (Topic) -> String
    /// Optional text under the confirmation title (e.g. what happens to the status).
    var confirmMessage: (Topic) -> String? = { _ in nil }
    let confirmButton: String
    let action: (Topic) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target: Topic?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(explanation).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if topics.isEmpty {
                        Text("Es gibt kein anderes Thema in diesem Fach.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("noOtherTopics")
                    }
                    ForEach(topics) { topic in
                        Button { target = topic } label: {
                            HStack {
                                Text(topic.title).foregroundStyle(.primary)
                                Spacer()
                                TopicStatusBadge(status: TopicStatus(topic))
                            }
                        }
                        .accessibilityIdentifier("choice-\(topic.title)")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .alert(
                target.map(confirmTitle) ?? "",
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                presenting: target
            ) { chosen in
                Button(confirmButton) {
                    do {
                        try action(chosen)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    target = nil
                }
                .accessibilityIdentifier("confirmChoiceButton")
                Button("Abbrechen", role: .cancel) {}
            } message: { chosen in
                if let message = confirmMessage(chosen) { Text(message) }
            }
            .errorAlert($errorMessage)
        }
    }
}

/// Moves chosen entries of a topic into a new topic.
struct SplitTopicSheet: View {
    let topic: Topic
    var onCreated: ((Topic) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var newTitle = ""
    @State private var chosen: Set<UUID> = []
    @State private var showValidation = false
    @State private var errorMessage: String?

    var body: some View {
        let entries = topic.sortedEntries
        NavigationStack {
            Form {
                Section {
                    TextField("Titel des neuen Themas", text: $newTitle)
                        .accessibilityIdentifier("splitTitleField")
                } header: {
                    Text("Neues Thema")
                } footer: {
                    if showValidation, newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Gib dem neuen Thema einen Titel.").foregroundStyle(.red)
                    } else if showValidation, chosen.isEmpty {
                        Text("Wähle mindestens einen Eintrag aus.").foregroundStyle(.red)
                    }
                }
                Section {
                    if entries.isEmpty {
                        Text("„\(topic.title)“ hat noch keine Einträge, die verschoben werden könnten.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        let isChosen = chosen.contains(entry.id)
                        Button {
                            if isChosen { chosen.remove(entry.id) } else { chosen.insert(entry.id) }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.kind.germanName).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.displayText).foregroundStyle(.primary).lineLimit(3)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                        .accessibilityValue(isChosen ? "ausgewählt" : "")
                        .accessibilityIdentifier("splitEntry-\(entry.sortIndex)")
                    }
                } header: {
                    Text("Einträge verschieben")
                } footer: {
                    Text("Das neue Thema bekommt die Seiten, auf die die gewählten Einträge verweisen.")
                }
            }
            .navigationTitle("Thema aufteilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aufteilen", action: split).accessibilityIdentifier("confirmSplitButton")
                }
            }
            .errorAlert($errorMessage)
        }
    }

    private func split() {
        guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chosen.isEmpty else {
            showValidation = true
            return
        }
        do {
            let moving = topic.entries.filter { chosen.contains($0.id) }
            if let created = try repository?.split(topic, movingEntries: moving, newTitle: newTitle) { onCreated?(created) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
