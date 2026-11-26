import StudyCore
import StudyData
import SwiftUI

/// Developer mode: form to report a recognition error at a line (or at an area drawn on the page).
/// Saves a `RecognitionReportEntry` into the `RecognitionReportStore`.
struct ReportErrorSheet: View {
    let source: Source
    let batch: ImportBatch
    let selectedLineID: UUID?
    let drawnRect: NormalizedRect?
    private let lines: [RecognizedLine]

    @Environment(\.dismiss) private var dismiss
    @Environment(RecognitionReportStore.self) private var store
    @State private var draft: ReportDraft
    @State private var isSaving = false

    /// - Parameters:
    ///   - lines: the lines of the page as the review screen shows them.
    ///   - selectedLineID: the line the user wants to report, nil for an area drawn on the page.
    ///   - drawnRect: the drawn area (used when no line is selected).
    init(source: Source, batch: ImportBatch, lines: [RecognizedLine], selectedLineID: UUID?, drawnRect: NormalizedRect?) {
        self.source = source
        self.batch = batch
        self.lines = lines.sorted { $0.order < $1.order }
        self.selectedLineID = selectedLineID
        self.drawnRect = drawnRect
        _draft = State(initialValue: .initial(for: lines.first { $0.id == selectedLineID }))
    }

    private var selectedLine: RecognizedLine? { lines.first { $0.id == selectedLineID } }
    private var canSave: Bool { selectedLine != nil || (drawnRect.map { !$0.isEmpty } ?? false) }
    private var otherLines: [RecognizedLine] { lines.filter { $0.id != selectedLineID } }

    var body: some View {
        NavigationStack {
            Form {
                placeSection
                Section("Art des Fehlers") {
                    Picker("Art", selection: $draft.kind) {
                        ForEach(RecognitionReportKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("reportKindPicker")
                }
                if draft.kind != .order {
                    Section {
                        TextField("Richtig wäre", text: $draft.expected, axis: .vertical)
                            .lineLimit(1...6)
                            .accessibilityIdentifier("reportExpectedField")
                    } header: {
                        Text("Richtig wäre")
                    } footer: {
                        Text(draft.kind == .missing
                             ? "Der Text, der an dieser Stelle fehlt."
                             : "Der Text, wie er erkannt werden sollte.")
                    }
                }
                if draft.kind == .order { orderSection }
                if draft.kind == .split { splitSection }
                Section("Notiz") {
                    TextField("Notiz (optional)", text: $draft.note, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("reportNoteField")
                }
                Section {
                    Toggle("Bildausschnitt mitsenden", isOn: $draft.includeImage)
                        .accessibilityIdentifier("reportImageToggle")
                } footer: {
                    Text("Ein kleiner Ausschnitt der Seite (höchstens 600 Pixel) wird zum Eintrag gespeichert.")
                }
            }
            .navigationTitle("Fehler melden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .accessibilityIdentifier("reportCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                        .accessibilityIdentifier("reportSaveButton")
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: draft.kind) { _, kind in
            // "Fehlt": the prefilled line text is not what is missing; back to another kind: prefill again.
            guard let line = selectedLine else { return }
            if kind == .missing, draft.expected == line.text {
                draft.expected = ""
            } else if kind != .missing, draft.expected.isEmpty {
                draft.expected = line.text
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var placeSection: some View {
        Section("Stelle") {
            if let line = selectedLine {
                Text(line.text.isEmpty ? "(leer)" : line.text)
                    .accessibilityIdentifier("reportPlaceText")
            } else if drawnRect != nil {
                Label("Markierter Bereich auf Seite \(source.pageIndex + 1)", systemImage: "rectangle.dashed")
                    .accessibilityIdentifier("reportPlaceText")
            } else {
                Text("Keine Stelle gewählt.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var orderSection: some View {
        Section {
            Picker("Gehört hinter …", selection: $draft.afterLineID) {
                Text("Nicht angegeben").tag(UUID?.none)
                ForEach(otherLines) { line in
                    Text("\(line.order + 1). \(Self.shortText(line.text))").tag(Optional(line.id))
                }
            }
            .accessibilityIdentifier("reportAfterPicker")
        } footer: {
            Text("Die Zeile, hinter der die gemeldete Stelle stehen müsste.")
        }
    }

    private var splitSection: some View {
        Section {
            ForEach(otherLines) { line in
                Button {
                    if draft.extraLineIDs.contains(line.id) {
                        draft.extraLineIDs.remove(line.id)
                    } else {
                        draft.extraLineIDs.insert(line.id)
                    }
                } label: {
                    HStack {
                        Text("\(line.order + 1). \(Self.shortText(line.text))")
                            .foregroundStyle(.primary)
                        Spacer()
                        if draft.extraLineIDs.contains(line.id) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityIdentifier("reportSplitLine-\(line.order)")
                .accessibilityAddTraits(draft.extraLineIDs.contains(line.id) ? .isSelected : [])
            }
        } header: {
            Text("Weitere Zeilen")
        } footer: {
            Text("Zeilen, die zu derselben Stelle gehören (falsch getrennt oder zusammengefügt).")
        }
    }

    // MARK: Saving

    private func save() async {
        guard canSave else { return }
        isSaving = true
        let metadata = source.currentDigitization.map(\.metadata)
        // The image area is the union of all reported lines (the entry's rect), computed the same way as the entry.
        let preview = draft.makeEntry(
            importID: batch.id, page: source.pageIndex + 1, pageSize: source.pageSize, lines: lines,
            selectedLineID: selectedLineID, drawnRect: drawnRect, method: metadata?.method,
            engine: metadata?.engineVersion ?? metadata?.modelName, imageJPEG: nil)
        var jpeg: Data?
        if draft.includeImage, let data = source.imageData {
            jpeg = await ReportImageCropper.jpeg(from: data, rect: preview.rect)
        }
        var entry = preview
        entry.imageJPEG = jpeg
        store.add(entry, importInfo: RecognitionReportImport(batch: batch))
        dismiss()
    }

    private static func shortText(_ text: String, limit: Int = 48) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.isEmpty { return "(leer)" }
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
