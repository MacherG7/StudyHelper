import StudyCore
import StudyData
import SwiftUI

/// The fixed structure of a topic as editable fields: title, summary, entries per kind, assigned pages.
/// Only the title is required.
struct TopicEditorView: View {
    let topic: Topic

    enum EntrySheet: Identifiable {
        case add(EntryKind)
        case edit(TopicEntry)

        var id: String {
            switch self {
            case .add(let kind): "add-\(kind.rawValue)"
            case .edit(let entry): entry.id.uuidString
            }
        }
    }

    @Environment(\.studyRepository) private var repository
    @State private var entrySheet: EntrySheet?
    @State private var showPageAssignment = false
    @State private var sourceToMove: Source?
    @State private var editMode: EditMode = .inactive
    @State private var errorMessage: String?
    @State private var changeCache = DerivedValue<[UUID: SourceChangeReport]>()

    var body: some View {
        let changes = changeCache.value(key: topic.id) { SourceChecks.reports(for: topic.entries, subject: topic.subject) }
        List {
            Section("Titel") {
                CommitTextField(title: "Titel des Themas", value: topic.title) { newValue in
                    guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        errorMessage = StudyDataError.emptyTopicTitle.localizedDescription
                        return false
                    }
                    return perform { try $0.renameTopic(topic, to: newValue) }
                }
                .accessibilityIdentifier("topicTitleEditField")
            }

            Section {
                CommitTextField(title: "Kurze Zusammenfassung (freiwillig)", value: topic.summary, axis: .vertical, lineLimit: 2...8) { newValue in
                    perform { try $0.setSummary(newValue, for: topic) }
                }
                .accessibilityIdentifier("topicSummaryField")
            } header: {
                Text("Zusammenfassung")
            }

            ForEach(EntryKind.allCases, id: \.self) { kind in
                entriesSection(kind, changes: changes)
            }

            sourcesSection

            Section("Herkunft") {
                LabeledContent("Thema", value: topic.origin.germanName)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Fertig" : "Sortieren", systemImage: "arrow.up.arrow.down") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .accessibilityIdentifier("sortEntriesButton")
            }
        }
        .sheet(item: $entrySheet) { sheet in
            switch sheet {
            case .add(let kind): EntryEditSheet(topic: topic, kind: kind, entry: nil)
            case .edit(let entry): EntryEditSheet(topic: topic, kind: entry.kind, entry: entry)
            }
        }
        .sheet(isPresented: $showPageAssignment) {
            PageAssignmentSheet(topic: topic)
        }
        .sheet(item: $sourceToMove) { source in
            TopicChoiceSheet(
                title: "Quelle verschieben",
                explanation: "„\(source.germanTitle)“ wird aus „\(topic.title)“ entfernt und dem gewählten Thema zugeordnet. Bestehende Einträge bleiben unverändert.",
                topics: (topic.subject.flatMap { repository?.topics(in: $0) } ?? []).filter { $0 !== topic },
                confirmTitle: { "Quelle in „\($0.title)“ verschieben?" },
                confirmButton: "Verschieben"
            ) { target in
                try repository?.moveSource(source, from: topic, to: target)
            }
        }
        .errorAlert($errorMessage)
    }

    /// Runs a repository call; failures end in the error alert. Returns false on failure.
    private func perform(_ call: (StudyRepository) throws -> Void) -> Bool {
        guard let repository else { return false }
        do {
            try call(repository)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Entries

    private func entriesSection(_ kind: EntryKind, changes: [UUID: SourceChangeReport]) -> some View {
        let entries = topic.sortedEntries.filter { $0.kind == kind }
        return Section {
            ForEach(entries) { entry in
                Button { entrySheet = .edit(entry) } label: {
                    EditorEntryRow(entry: entry, topic: topic, change: changes[entry.id])
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entryRow-\(entry.kind.rawValue)-\(entries.firstIndex(where: { $0.id == entry.id }) ?? 0)")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Löschen", systemImage: "trash", role: .destructive) { delete(entry) }
                }
                .contextMenu {
                    Button("Bearbeiten", systemImage: "pencil") { entrySheet = .edit(entry) }
                    Button("Nach oben", systemImage: "arrow.up") { move(entry, in: entries, by: -1) }
                        .disabled(entries.first?.id == entry.id)
                    Button("Nach unten", systemImage: "arrow.down") { move(entry, in: entries, by: 1) }
                        .disabled(entries.last?.id == entry.id)
                    Button("Löschen", systemImage: "trash", role: .destructive) { delete(entry) }
                }
                .accessibilityAction(named: "Nach oben") { move(entry, in: entries, by: -1) }
                .accessibilityAction(named: "Nach unten") { move(entry, in: entries, by: 1) }
                .accessibilityAction(named: "Löschen") { delete(entry) }
            }
            .onMove { from, to in reorder(kind: kind, from: from, to: to) }
            Button(kind.addTitle, systemImage: "plus.circle") { entrySheet = .add(kind) }
                .accessibilityIdentifier("addEntry-\(kind.rawValue)")
        } header: {
            Text(kind.sectionTitle)
        }
    }

    private func delete(_ entry: TopicEntry) {
        _ = perform { try $0.deleteEntry(entry) }
    }

    private func move(_ entry: TopicEntry, in entries: [TopicEntry], by delta: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        // `to` of onMove semantics: moving down by one means "before the entry after the next".
        reorder(kind: entry.kind, from: IndexSet(integer: index), to: delta > 0 ? target + 1 : target)
    }

    private func reorder(kind: EntryKind, from: IndexSet, to: Int) {
        let all = topic.sortedEntries.map { (id: $0.id, kind: $0.kind) }
        let order = EntryOrdering.reordered(all: all, kind: kind, from: from, to: to)
        _ = perform { try $0.reorderEntries(in: topic, orderedIDs: order) }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section {
            if topic.sources.isEmpty {
                Text("Noch keine Seiten zugeordnet. Ordne Seiten zu, um ihren Text neben dem Editor zu sehen und Inhalte zu übernehmen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(topic.sortedSources) { source in
                Label(source.germanTitle, systemImage: "doc.text")
                    .accessibilityIdentifier("assignedSource-\(source.pageIndex)")
                    .swipeActions(edge: .trailing) {
                        Button("Entfernen", systemImage: "minus.circle", role: .destructive) {
                            _ = perform { try $0.remove(source, from: topic) }
                        }
                        Button("Verschieben", systemImage: "arrow.right.circle") { sourceToMove = source }
                            .tint(.indigo)
                    }
                    .contextMenu {
                        Button("In anderes Thema verschieben …", systemImage: "arrow.right.circle") { sourceToMove = source }
                        Button("Aus diesem Thema entfernen", systemImage: "minus.circle", role: .destructive) {
                            _ = perform { try $0.remove(source, from: topic) }
                        }
                    }
            }
            Button("Seiten zuordnen", systemImage: "plus.circle") { showPageAssignment = true }
                .accessibilityIdentifier("assignPagesButton")
        } header: {
            Text("Zugeordnete Quellen")
        } footer: {
            Text("Wische eine Quelle nach links, um sie zu entfernen oder in ein anderes Thema zu verschieben.")
        }
    }
}

/// One entry in the editor list: content, origin, and what is known about its source.
private struct EditorEntryRow: View {
    let entry: TopicEntry
    let topic: Topic
    let change: SourceChangeReport?

    var body: some View {
        let references = entry.sourceReferences
        let sourceText = Self.sourceText(references, subject: topic.subject)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                EntryMetaLine(entry: entry, sourceText: sourceText, change: change)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spokenLabel(sourceText: sourceText, sourceChanged: change != nil))
        .accessibilityHint("Zum Bearbeiten tippen")
        .accessibilityAddTraits(.isButton)
    }

    /// "Quelle: Fotosynthese.jpg · Seite 1" or nil.
    static func sourceText(_ references: [SourceReference], subject: Subject?) -> String? {
        guard let reference = references.first else { return nil }
        guard let source = subject?.source(withID: reference.sourceID) else { return "Quelle nicht mehr vorhanden" }
        return "Quelle: \(source.germanTitle)"
    }
}

/// Origin badge, highlight info and source of an entry (visible text).
struct EntryMetaLine: View {
    let entry: TopicEntry
    let sourceText: String?
    var change: SourceChangeReport?

    var body: some View {
        FlowLayout(spacing: 6) {
            Label(entry.origin.germanName, systemImage: entry.origin.symbolName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.origin.tint)
            if let highlight = entry.highlight {
                Label("Hervorgehoben: \(highlight.germanDescription)", systemImage: highlight.kind.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let sourceText {
                Label(sourceText, systemImage: "doc.text.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if change != nil {
                Label("Quelle geändert", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if entry.origin == .aiSupplement, let status = entry.supplementStatus {
                Text(status == .proposed ? "Noch nicht angenommen" : status == .accepted ? "Angenommen" : "Abgelehnt")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
        }
    }
}

/// Assign pages of the subject's imports to the topic (tap to toggle).
struct PageAssignmentSheet: View {
    let topic: Topic
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var errorMessage: String?

    var body: some View {
        let batches = (topic.subject?.imports ?? []).sorted { $0.createdAt < $1.createdAt }
        NavigationStack {
            List {
                if batches.isEmpty {
                    Text("In diesem Fach gibt es noch keinen Lernstoff. Importiere zuerst Fotos, ein PDF oder einen Goodnotes-Export.")
                        .foregroundStyle(.secondary)
                }
                ForEach(batches) { batch in
                    Section(batch.originalFileName ?? batch.kind.germanName) {
                        ForEach(batch.sortedSources) { source in
                            let assigned = topic.sources.contains { $0 === source }
                            Button { toggle(source, assigned: assigned) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Seite \(source.pageIndex + 1)").foregroundStyle(.primary)
                                        if let preview = Self.preview(of: source) {
                                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: assigned ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(assigned ? Color.accentColor : .secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(assigned ? .isSelected : [])
                            .accessibilityValue(assigned ? "zugeordnet" : "nicht zugeordnet")
                            .accessibilityIdentifier("pagePickRow-\(source.pageIndex)")
                        }
                    }
                }
            }
            .navigationTitle("Seiten zuordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.accessibilityIdentifier("pageAssignmentDoneButton")
                }
            }
            .errorAlert($errorMessage)
        }
    }

    private func toggle(_ source: Source, assigned: Bool) {
        guard let repository else { return }
        do {
            if assigned { try repository.remove(source, from: topic) } else { try repository.assign(source, to: topic) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// First words of the stored text, for recognizing the page.
    private static func preview(of source: Source) -> String? {
        guard let markdown = source.currentDigitization?.originalMarkdown else { return nil }
        let text = markdown.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#*_-")))
        return (text?.isEmpty ?? true) ? nil : text
    }
}
