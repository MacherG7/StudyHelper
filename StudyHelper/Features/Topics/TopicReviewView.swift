import StudyCore
import StudyData
import SwiftUI

/// A topic in its fixed structure next to the original source. Tapping an entry marks its place in the page image.
struct TopicReviewView: View {
    let topic: Topic

    @Environment(\.studyRepository) private var repository
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedEntryID: UUID?
    @State private var shownSourceID: UUID?
    @State private var mark: ResolvedMark?
    @State private var note: String?
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var highlightsCache = DerivedValue<[RecognizedHighlight]>()
    @State private var changeCache = DerivedValue<[UUID: SourceChangeReport]>()

    private var changes: [UUID: SourceChangeReport] {
        changeCache.value(key: topic.id) { SourceChecks.reports(for: topic.entries, subject: topic.subject) }
    }

    private var isWide: Bool { sizeClass == .regular }
    /// Narrow screen with very large text: the page image gets its own sheet instead of sharing the screen.
    private var usesImageSheet: Bool { !isWide && typeSize.isAccessibilitySize }

    /// The page shown next to (or below) the structure: the selected entry's page, else the first assigned page.
    private var shownSource: Source? {
        if let shownSourceID, let source = topic.subject?.source(withID: shownSourceID) { return source }
        return topic.sortedSources.first
    }

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    structure
                    Divider()
                    imagePane
                }
            } else {
                VStack(spacing: 0) {
                    structure
                    if selectedEntryID != nil, !usesImageSheet {
                        Divider()
                        imagePane
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { usesImageSheet && selectedEntryID != nil },
            set: { if !$0 { deselect() } }
        )) {
            imagePane.presentationDetents([.medium, .large])
        }
        .errorAlert($errorMessage)
        .onChange(of: topic.entries.map(\.id)) { _, ids in
            // The selected entry was deleted or moved to another topic.
            if let selectedEntryID, !ids.contains(selectedEntryID) { deselect() }
        }
    }

    // MARK: Structure

    private var structure: some View {
        let entries = topic.sortedEntries
        let changes = changes
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !topic.summary.isEmpty {
                    block(title: "Zusammenfassung") {
                        Text(topic.summary).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(EntryKind.allCases, id: \.self) { kind in
                    let ofKind = entries.filter { $0.kind == kind }
                    if !ofKind.isEmpty {
                        block(title: kind.sectionTitle) {
                            VStack(spacing: 8) {
                                ForEach(ofKind) { entry in
                                    ReviewEntryRow(
                                        entry: entry, subject: topic.subject, isSelected: entry.id == selectedEntryID,
                                        ordinal: entries.firstIndex { $0.id == entry.id } ?? 0, change: changes[entry.id]
                                    ) { select(entry) }
                                }
                            }
                        }
                    }
                }
                if entries.isEmpty, topic.summary.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Inhalte", systemImage: "square.and.pencil",
                        description: Text("Wechsle zu „\(isWide ? "Bearbeiten" : "Felder")“, um Inhalte einzutragen oder aus der Quelle zu übernehmen."))
                }
                if !topic.sortedSources.isEmpty {
                    block(title: "Zugeordnete Quellen") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(topic.sortedSources) { source in
                                Label(source.germanTitle, systemImage: "doc.text").font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                LabeledContent("Herkunft des Themas", value: topic.origin.germanName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func block<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: Selecting

    private func deselect() {
        selectedEntryID = nil
        mark = nil
        note = nil
    }

    private func select(_ entry: TopicEntry) {
        if selectedEntryID == entry.id { deselect(); return }
        selectedEntryID = entry.id
        mark = nil
        note = nil
        let references = entry.sourceReferences
        guard let reference = references.first else {
            note = entry.origin == .user
                ? "Diesen Eintrag hast du selbst eingegeben. Er hat keine Quelle im Lernstoff."
                : "Für diesen Eintrag ist keine Quelle gespeichert."
            return
        }
        var lines: [RecognizedLine] = []
        do {
            lines = try repository?.lines(for: reference) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        let resolved = ReferenceResolver.mark(for: reference, resolvedLines: lines)
        if topic.subject?.source(withID: reference.sourceID) == nil {
            note = "Die Quelle dieses Eintrags gibt es nicht mehr."
            return
        }
        shownSourceID = reference.sourceID
        mark = resolved
        if resolved.rect == nil {
            note = "Die Stelle im Original wurde nicht gefunden."
        } else if resolved.isStale {
            note = "Die Stelle wurde seit dem Übernehmen verändert. Gezeigt wird der gespeicherte Bereich."
        }
    }

    // MARK: Image

    @ViewBuilder
    private var imagePane: some View {
        if let source = shownSource {
            let sources = topic.sortedSources
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if sources.count > 1 {
                        Menu {
                            ForEach(sources) { candidate in
                                Button(candidate.germanTitle) {
                                    shownSourceID = candidate.id
                                    mark = nil
                                }
                            }
                        } label: {
                            Label(source.germanTitle, systemImage: "doc.text").lineLimit(2)
                        }
                        .accessibilityIdentifier("reviewPageMenu")
                    } else {
                        Label(source.germanTitle, systemImage: "doc.text")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if !isWide {
                        Button("Quelle schließen", systemImage: "xmark.circle.fill") { deselect() }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("closeSourceButton")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                if let selected = topic.entries.first(where: { $0.id == selectedEntryID }), let change = changes[selected.id] {
                    SourceChangeActions(entry: selected, subject: topic.subject, report: change)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("sourceNote")
                }
                if let image {
                    let highlights = highlightsCache.value(key: source.id) { source.currentDigitization?.highlights ?? [] }
                    PageImageView(
                        image: image, lines: [], highlights: highlights, selectedLineID: .constant(nil), onlyOpen: false,
                        markedRect: mark?.sourceID == source.id ? mark?.rect : nil)
                } else if source.imageData == nil {
                    ContentUnavailableView("Kein Bild", systemImage: "photo", description: Text("Das Bild dieser Seite ist nicht gespeichert."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: source.id) {
                image = nil
                if let data = source.imageData {
                    image = await UIImage(data: data)?.byPreparingForDisplay()
                }
            }
        } else {
            ContentUnavailableView("Keine Quelle", systemImage: "doc", description: Text("Diesem Thema sind noch keine Seiten zugeordnet."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One entry in the topic view: content, origin, highlight and source. Tap selects it (and marks its place).
private struct ReviewEntryRow: View {
    let entry: TopicEntry
    let subject: Subject?
    let isSelected: Bool
    let ordinal: Int
    let change: SourceChangeReport?
    let onTap: () -> Void

    var body: some View {
        let sourceText = entry.sourceReferences.first.map { reference -> String in
            if let source = subject?.source(withID: reference.sourceID) { return "Quelle: \(source.germanTitle)" }
            return "Quelle nicht mehr vorhanden"
        }
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.kind.symbolName)
                    .foregroundStyle(entry.origin.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    content
                    EntryMetaLine(entry: entry, sourceText: sourceText, change: change)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spokenLabel(sourceText: sourceText, sourceChanged: change != nil))
        .accessibilityValue(isSelected ? "ausgewählt" : "")
        .accessibilityHint(entry.sourceReferences.isEmpty ? "" : "Zeigt die Stelle im Originalbild")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("reviewEntry-\(ordinal)")
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .term:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term.isEmpty ? "(ohne Begriff)" : entry.term).font(.body.weight(.semibold))
                if !entry.definition.isEmpty { Text(entry.definition).font(.body) }
            }
            .multilineTextAlignment(.leading)
        case .table:
            if let data = entry.tableData {
                TableGrid(data: data)
            } else {
                Text("Tabelle")
            }
        default:
            Text(entry.displayText).font(.body).multilineTextAlignment(.leading)
        }
    }
}

/// A read-only table.
private struct TableGrid: View {
    let data: TableData

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                if data.headers.contains(where: { !$0.isEmpty }) {
                    GridRow {
                        ForEach(Array(data.headers.enumerated()), id: \.offset) { _, header in
                            Text(header).font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider()
                }
                ForEach(Array(data.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.subheadline)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}
