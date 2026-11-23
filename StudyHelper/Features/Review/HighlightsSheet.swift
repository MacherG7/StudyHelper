import StudyCore
import StudyData
import SwiftUI

/// The highlights of one line: change kind, color and meaning, delete, or add a new one.
/// Every edit is stored as a correction by the repository and survives re-recognition.
struct HighlightsSheet: View {
    let source: Source
    let lineID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var showAdd = false
    @State private var deleteTarget: RecognizedHighlight?
    @State private var errorMessage: String?

    /// The line and its highlights, decoded once per change instead of on every render.
    private struct LineContent {
        var line: RecognizedLine?
        var highlights: [RecognizedHighlight] = []
    }

    @State private var contentCache = DerivedValue<LineContent>()

    private var content: LineContent {
        contentCache.value(key: lineID) {
            guard let digitization = source.currentDigitization,
                  let line = digitization.lines.first(where: { $0.id == lineID }) else { return LineContent() }
            return LineContent(line: line, highlights: digitization.highlights.filter { $0.applies(to: line) })
        }
    }

    var body: some View {
        let line = content.line
        let highlights = content.highlights
        NavigationStack {
            List {
                if let line {
                    Section {
                        Text(line.text).font(.callout)
                    } header: {
                        Text("Zeile")
                    }
                }
                if highlights.isEmpty {
                    Section {
                        Text("Für diese Zeile ist keine Hervorhebung gespeichert.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(highlights) { highlight in
                    HighlightEditor(highlight: highlight, source: source, onError: { errorMessage = $0 }) {
                        deleteTarget = highlight
                    }
                }
                Section {
                    Button("Hervorhebung hinzufügen", systemImage: "plus.circle") { showAdd = true }
                        .accessibilityIdentifier("addHighlightButton")
                        .disabled((line?.words.isEmpty ?? true))
                } footer: {
                    if line?.words.isEmpty ?? true {
                        Text("Für diese Zeile sind keine einzelnen Wörter gespeichert.")
                    }
                }
            }
            .navigationTitle("Hervorhebungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) {
                if let line {
                    AddHighlightSheet(source: source, line: line)
                }
            }
            .alert(
                "Hervorhebung löschen?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                presenting: deleteTarget
            ) { highlight in
                Button("Löschen", role: .destructive) {
                    do { try repository?.deleteHighlight(id: highlight.id, in: source) } catch { errorMessage = error.localizedDescription }
                    deleteTarget = nil
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { highlight in
                Text("„\(highlight.text)“ (\(highlight.kind.germanName)) wird entfernt. Das bleibt auch bei „Neu erkennen“ so.")
            }
            .errorAlert($errorMessage)
        }
    }
}

private struct HighlightEditor: View {
    let highlight: RecognizedHighlight
    let source: Source
    let onError: (String) -> Void
    let onDelete: () -> Void
    @Environment(\.studyRepository) private var repository

    private func apply(_ change: (StudyRepository) throws -> Void) {
        guard let repository else { return }
        do { try change(repository) } catch { onError(error.localizedDescription) }
    }

    var body: some View {
        Section {
            Picker("Art", selection: Binding(
                get: { highlight.kind },
                set: { kind in apply { try $0.setHighlightKind(kind, id: highlight.id, in: source) } }
            )) {
                ForEach(HighlightKind.allCases, id: \.self) { Text($0.germanName).tag($0) }
            }
            Picker("Bedeutung", selection: Binding(
                get: { highlight.suggestedMeaning },
                set: { meaning in apply { try $0.setHighlightMeaning(meaning, id: highlight.id, in: source) } }
            )) {
                Text("Keine").tag(HighlightMeaning?.none)
                ForEach(HighlightMeaning.allCases, id: \.self) { Text($0.germanName).tag(Optional($0)) }
            }
            ColorChoice(color: highlight.color) { color in
                apply { try $0.setHighlightColor(color, id: highlight.id, in: source) }
            }
            Button("Hervorhebung löschen", systemImage: "trash", role: .destructive, action: onDelete)
        } header: {
            Text("„\(highlight.text)“")
        } footer: {
            if highlight.source != .user {
                Text(highlight.status == .confident ? "Automatisch erkannt (sicher)." : "Automatisch erkannt (unsicher).")
            } else {
                Text("Von dir angelegt oder geändert.")
            }
        }
    }
}

/// Row of color swatches plus "none".
struct ColorChoice: View {
    let color: RGBColor?
    let onChange: (RGBColor?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Farbe")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    swatch(name: "Keine Farbe", fill: nil, selected: color == nil) { onChange(nil) }
                    ForEach(HighlightPalette.colors, id: \.name) { entry in
                        swatch(
                            name: entry.name, fill: entry.color.swiftUIColor,
                            selected: color.map { $0.distance(to: entry.color) < 0.08 } ?? false
                        ) { onChange(entry.color) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func swatch(name: String, fill: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill ?? Color.clear)
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                if fill == nil { Image(systemName: "slash.circle").foregroundStyle(.secondary) }
                if selected { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(fill == nil ? Color.primary : .black.opacity(0.75)) }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Create a highlight from words of the line.
private struct AddHighlightSheet: View {
    let source: Source
    let line: RecognizedLine

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var selected: Set<Int> = []
    @State private var kind: HighlightKind = .highlighter
    @State private var meaning: HighlightMeaning?
    @State private var color: RGBColor? = HighlightPalette.colors.first?.color
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Wörter auswählen") {
                    ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                        Button {
                            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                        } label: {
                            HStack {
                                Text(word.text)
                                Spacer()
                                if selected.contains(index) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
                    }
                }
                Section {
                    Picker("Art", selection: $kind) {
                        ForEach(HighlightKind.allCases, id: \.self) { Text($0.germanName).tag($0) }
                    }
                    Picker("Bedeutung", selection: $meaning) {
                        Text("Keine").tag(HighlightMeaning?.none)
                        ForEach(HighlightMeaning.allCases, id: \.self) { Text($0.germanName).tag(Optional($0)) }
                    }
                    ColorChoice(color: color) { color = $0 }
                }
            }
            .navigationTitle("Hervorhebung hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen", action: add)
                        .disabled(selected.isEmpty)
                        .accessibilityIdentifier("confirmAddHighlightButton")
                }
            }
            .errorAlert($errorMessage)
        }
    }

    private func add() {
        let refs = selected.sorted().map { WordReference(lineID: line.id, wordIndex: $0) }
        do {
            try repository?.addHighlight(in: source, words: refs, kind: kind, color: color, meaning: meaning)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
