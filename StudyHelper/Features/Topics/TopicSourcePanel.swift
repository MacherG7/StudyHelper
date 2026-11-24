import StudyCore
import StudyData
import SwiftUI

/// The stored text of the pages assigned to a topic, with highlights. Lines (or single words) can be taken over
/// as entries; highlighted headings and terms are offered as suggestions.
struct TopicSourcePanel: View {
    let topic: Topic

    @Environment(\.studyRepository) private var repository
    @State private var shownSourceID: UUID?
    @State private var selectedLineIDs: Set<UUID> = []
    @State private var wordSelection: [UUID: Set<Int>] = [:]
    @State private var wordPickerLineID: UUID?
    @State private var notice: String?
    @State private var showAssignment = false
    @State private var errorMessage: String?
    @State private var snapshotCache = DerivedValue<PageText>()

    /// The current digitization of a page, decoded once per change.
    private struct PageText {
        var digitizationID: UUID?
        var version: Int?
        var lines: [RecognizedLine] = []
        var highlights: [RecognizedHighlight] = []
        var unreadable = false

        init() {}

        init(_ source: Source) {
            guard let digitization = source.currentDigitization else { return }
            digitizationID = digitization.id
            version = digitization.versionNumber
            if digitization.hasUnreadableData { unreadable = true; return }
            lines = digitization.lines.sorted { $0.order < $1.order }
            highlights = digitization.highlights
        }
    }

    var body: some View {
        let sources = topic.sortedSources
        let source = sources.first { $0.id == shownSourceID } ?? sources.first
        VStack(spacing: 0) {
            if let source {
                header(sources: sources, current: source)
                Divider()
                content(source: source)
            } else {
                ContentUnavailableView {
                    Label("Keine Seiten zugeordnet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Ordne diesem Thema Seiten zu. Ihr gespeicherter Text erscheint dann hier, und du kannst Inhalte daraus übernehmen.")
                } actions: {
                    Button("Seiten zuordnen") { showAssignment = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("sourcePanelAssignButton")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAssignment) { PageAssignmentSheet(topic: topic) }
        .sheet(isPresented: Binding(get: { wordPickerLineID != nil }, set: { if !$0 { wordPickerLineID = nil } })) {
            if let source, let id = wordPickerLineID,
               let line = snapshotCache.value(key: source.id, { PageText(source) }).lines.first(where: { $0.id == id }) {
                WordPickerSheet(line: line, selected: wordSelection[id] ?? []) { chosen in
                    wordSelection[id] = chosen.isEmpty ? nil : chosen
                }
            }
        }
        .errorAlert($errorMessage)
        .onChange(of: shownSourceID) { clearSelection() }
    }

    private func clearSelection() {
        selectedLineIDs = []
        wordSelection = [:]
    }

    // MARK: Header

    private func header(sources: [Source], current: Source) -> some View {
        HStack(spacing: 10) {
            if sources.count > 1 {
                Menu {
                    ForEach(sources) { source in
                        Button(source.germanTitle) { shownSourceID = source.id }
                    }
                } label: {
                    Label(current.germanTitle, systemImage: "doc.text").lineLimit(2)
                }
                .accessibilityIdentifier("sourcePageMenu")
            } else {
                Label(current.germanTitle, systemImage: "doc.text").font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Seiten zuordnen", systemImage: "plus.circle") { showAssignment = true }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("sourcePanelAssignButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Text and suggestions

    @ViewBuilder
    private func content(source: Source) -> some View {
        let page = snapshotCache.value(key: source.id) { PageText(source) }
        if page.unreadable {
            ContentUnavailableView("Seite nicht lesbar", systemImage: "exclamationmark.triangle", description: Text("Der gespeicherte Text dieser Seite ist beschädigt."))
        } else if page.digitizationID == nil {
            ContentUnavailableView("Noch kein Text", systemImage: "text.page.slash", description: Text("Diese Seite wurde noch nicht erkannt. Starte die Erkennung im Import."))
        } else {
            let existing = Set(topic.entries.flatMap { [$0.text, $0.term] }.map(HighlightSuggestions.normalized).filter { !$0.isEmpty })
            let suggestions = HighlightSuggestions.make(
                lines: page.lines, highlights: page.highlights, sourceID: source.id,
                digitizationID: page.digitizationID, digitizationVersion: page.version, existing: existing)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !suggestions.isEmpty {
                        SuggestionsBlock(suggestions: suggestions, onTake: take, onTitle: useAsTitle)
                    }
                    if page.lines.isEmpty {
                        ContentUnavailableView("Kein Text erkannt", systemImage: "text.page.slash", description: Text("Auf dieser Seite wurde kein Text gefunden."))
                            .padding(.top, 24)
                    }
                    ForEach(page.lines) { line in
                        TakeoverLineRow(
                            line: line, highlights: page.highlights,
                            isSelected: selectedLineIDs.contains(line.id),
                            wordCount: wordSelection[line.id]?.count
                        ) { toggle(line) }
                    }
                }
                .padding(10)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar(source: source, page: page)
            }
        }
    }

    private func toggle(_ line: RecognizedLine) {
        notice = nil
        if selectedLineIDs.contains(line.id) {
            selectedLineIDs.remove(line.id)
            wordSelection[line.id] = nil
        } else {
            selectedLineIDs.insert(line.id)
        }
    }

    // MARK: Action bar

    @ViewBuilder
    private func actionBar(source: Source, page: PageText) -> some View {
        let selection = makeSelection(source: source, page: page)
        if let selection, !selection.text.isEmpty {
            let singleLine = selection.lines.count == 1 ? selection.lines.first : nil
            let bar = VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(selection.text)
                        .font(.callout)
                        .lineLimit(3)
                        .accessibilityIdentifier("takeoverPreview")
                    Spacer(minLength: 0)
                    Button("Auswahl aufheben", systemImage: "xmark.circle.fill") { clearSelection() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clearSelectionButton")
                }
                if let singleLine, singleLine.hasReliableWords, singleLine.words.count > 1 {
                    Button("Einzelne Wörter wählen", systemImage: "textformat.abc") { wordPickerLineID = singleLine.id }
                        .font(.footnote)
                        .accessibilityIdentifier("pickWordsButton")
                }
                Text("Übernehmen als")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(EntryKind.takeoverKinds, id: \.self) { kind in
                        Button(kind.takeoverTitle, systemImage: kind.symbolName) { takeOver(selection, as: kind) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityLabel("Übernehmen als \(kind.germanName)")
                            .accessibilityIdentifier("takeover-\(kind.rawValue)")
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Very large text: the bar scrolls instead of covering the whole screen.
            ViewThatFits(in: .vertical) {
                bar
                ScrollView { bar }.frame(maxHeight: 260)
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("takeoverBar")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("takeoverConfirmation")
                }
                Text("Tippe auf eine oder mehrere Zeilen, um sie in dieses Thema zu übernehmen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
        }
    }

    private func makeSelection(source: Source, page: PageText) -> SourceSelection? {
        guard !selectedLineIDs.isEmpty else { return nil }
        let chosen = page.lines.filter { selectedLineIDs.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        return SourceSelection(
            sourceID: source.id, digitizationID: page.digitizationID, digitizationVersion: page.version,
            lines: chosen, words: wordSelection, highlights: page.highlights)
    }

    // MARK: Taking over

    /// Shows the confirmation and announces it (VoiceOver users do not see the line appear).
    private func showNotice(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
    }

    private func takeOver(_ selection: SourceSelection, as kind: EntryKind) {
        guard let draft = selection.draft(kind: kind) else { return }
        if add(draft) {
            showNotice("Als \(kind.germanName) übernommen.")
            clearSelection()
        }
    }

    private func take(_ suggestion: HighlightSuggestion, as kind: EntryKind? = nil) {
        let draft = suggestion.draft(as: kind)
        if add(draft) { showNotice("Als \(draft.kind.germanName) übernommen.") }
    }

    private func useAsTitle(_ suggestion: HighlightSuggestion) {
        do {
            try repository?.renameTopic(topic, to: suggestion.text)
            showNotice("Als Titel übernommen.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stores the entry as "Original" with its source reference; false (and an alert) on failure.
    private func add(_ draft: EntryDraft) -> Bool {
        guard let repository else { return false }
        do {
            try repository.addEntry(
                to: topic, kind: draft.kind, text: draft.text, term: draft.term, definition: draft.definition,
                origin: .original, sourceReferences: [draft.reference], highlight: draft.highlight)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// A line of the stored text: tap to select (several allowed).
private struct TakeoverLineRow: View {
    let line: RecognizedLine
    let highlights: [RecognizedHighlight]
    let isSelected: Bool
    let wordCount: Int?
    let onTap: () -> Void

    var body: some View {
        let own = highlights.filter { $0.applies(to: line) }
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LineText.attributed(line: line, highlights: highlights))
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(own) { highlight in
                        Label(highlight.visibleDescription, systemImage: highlight.kind.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let wordCount {
                        Text(wordCount == 1 ? "1 Wort gewählt" : "\(wordCount) Wörter gewählt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
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
        .accessibilityLabel(line.spokenLabel(highlights: highlights))
        .accessibilityValue(isSelected ? "ausgewählt" : "")
        .accessibilityHint("Wählt die Zeile zum Übernehmen aus")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("topicLine-\(line.order)")
    }
}

/// "Vorschläge aus Hervorhebungen": chips for highlighted headings, terms and statements.
private struct SuggestionsBlock: View {
    let suggestions: [HighlightSuggestion]
    let onTake: (HighlightSuggestion, EntryKind?) -> Void
    let onTitle: (HighlightSuggestion) -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Text("Vorschläge aus Hervorhebungen (\(suggestions.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded ? "eingeblendet" : "ausgeblendet")
            .accessibilityIdentifier("suggestionsToggle")
            if expanded {
                FlowLayout(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        chip(suggestion)
                            .accessibilityIdentifier("suggestion-\(index)")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func chip(_ suggestion: HighlightSuggestion) -> some View {
        let label = Label(suggestion.text, systemImage: symbol(suggestion.role))
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(.primary)
        switch suggestion.role {
        case .heading:
            Menu {
                Button("Als Titel des Themas", systemImage: "textformat") { onTitle(suggestion) }
                Button("Als Kernaussage", systemImage: "text.quote") { onTake(suggestion, .keyStatement) }
            } label: { label }
            .accessibilityLabel("Überschrift: \(suggestion.text)")
            .accessibilityHint("Als Titel oder Kernaussage übernehmen")
        case .open:
            Menu {
                Button("Als Titel des Themas", systemImage: "textformat") { onTitle(suggestion) }
                Button("Als Begriff", systemImage: "character.book.closed") { onTake(suggestion, .term) }
                Button("Als Kernaussage", systemImage: "text.quote") { onTake(suggestion, .keyStatement) }
            } label: { label }
            .accessibilityLabel("Hervorgehoben: \(suggestion.text)")
            .accessibilityHint("Als Titel, Begriff oder Kernaussage übernehmen")
        case .term:
            Button { onTake(suggestion, nil) } label: { label }
                .accessibilityLabel("Begriff: \(suggestion.text)")
                .accessibilityHint("Als Begriff übernehmen")
        case .rule:
            Button { onTake(suggestion, nil) } label: { label }
                .accessibilityLabel("Formel oder Regel: \(suggestion.text)")
                .accessibilityHint("Als Formel oder Regel übernehmen")
        case .statement:
            Button { onTake(suggestion, nil) } label: { label }
                .accessibilityLabel("Hervorgehoben: \(suggestion.text)")
                .accessibilityHint("Als Kernaussage übernehmen")
        }
    }

    private func symbol(_ role: HighlightSuggestion.Role) -> String {
        switch role {
        case .heading: "textformat"
        case .term: "character.book.closed"
        case .rule: "function"
        case .statement: "text.quote"
        case .open: "underline"
        }
    }
}

/// Pick single words of one line.
private struct WordPickerSheet: View {
    let line: RecognizedLine
    let onDone: (Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<Int>

    init(line: RecognizedLine, selected: Set<Int>, onDone: @escaping (Set<Int>) -> Void) {
        self.line = line
        self.onDone = onDone
        _chosen = State(initialValue: selected)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tippe auf die Wörter, die du übernehmen willst.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                            let isChosen = chosen.contains(index)
                            Button {
                                if isChosen { chosen.remove(index) } else { chosen.insert(index) }
                            } label: {
                                Text(word.text)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isChosen ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                    .foregroundStyle(isChosen ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isChosen ? .isSelected : [])
                            .accessibilityValue(isChosen ? "ausgewählt" : "")
                            .accessibilityIdentifier("pickWord-\(index)")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Wörter wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { onDone(chosen); dismiss() }.accessibilityIdentifier("wordPickerDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
