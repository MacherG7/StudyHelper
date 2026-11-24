import StudyCore
import StudyData
import SwiftUI

/// Add a new entry (typed by the user) or edit an existing one. Every field is optional.
/// A new entry has the origin "Eigene Eingabe" and no source reference; editing the content of an entry
/// taken from the learning material makes it "Eigene Eingabe" (the text is now yours), the source
/// reference stays so that the original place can still be shown.
struct EntryEditSheet: View {
    let topic: Topic
    let kind: EntryKind
    let entry: TopicEntry?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var text = ""
    @State private var term = ""
    @State private var definition = ""
    @State private var table = TableData.starter
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var changeCache = DerivedValue<[UUID: SourceChangeReport]>()

    private var isNew: Bool { entry == nil }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .term:
                    Section("Begriff") {
                        TextField("Begriff", text: $term, axis: .vertical)
                            .accessibilityIdentifier("entryTermField")
                    }
                    Section("Definition") {
                        TextField("Definition", text: $definition, axis: .vertical)
                            .lineLimit(2...10)
                            .accessibilityIdentifier("entryDefinitionField")
                    }
                case .table:
                    Section {
                        TableEditorView(table: $table)
                    } header: {
                        Text("Tabelle")
                    } footer: {
                        Text("Die erste Zeile enthält die Spaltenüberschriften.")
                    }
                default:
                    Section(kind.germanName) {
                        TextField(kind.germanName, text: $text, axis: .vertical)
                            .lineLimit(3...12)
                            .accessibilityIdentifier("entryTextField")
                    }
                }
                if let entry { infoSection(entry) }
            }
            .navigationTitle(isNew ? kind.newTitle : "\(kind.germanName) bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).accessibilityIdentifier("saveEntryButton")
                }
            }
            .errorAlert($errorMessage)
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func infoSection(_ entry: TopicEntry) -> some View {
        let change = changeCache.value(key: entry.id) { SourceChecks.reports(for: [entry], subject: topic.subject) }[entry.id]
        if let change {
            Section {
                SourceChangeActions(entry: entry, subject: topic.subject, report: change) { dismiss() }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        Section {
            LabeledContent("Herkunft") {
                Label(entry.origin.germanName, systemImage: entry.origin.symbolName)
                    .foregroundStyle(entry.origin.tint)
            }
            if let highlight = entry.highlight {
                LabeledContent("Im Original", value: "Hervorgehoben: \(highlight.germanDescription)")
            }
            if let reference = entry.sourceReferences.first {
                let source = topic.subject?.source(withID: reference.sourceID)
                LabeledContent("Quelle", value: source?.germanTitle ?? "nicht mehr vorhanden")
                Button("Verweis auf die Quelle entfernen", systemImage: "link.badge.minus", role: .destructive) {
                    removeReference(from: entry)
                }
            }
        } header: {
            Text("Angaben")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let entry else { return }
        text = entry.text
        term = entry.term
        definition = entry.definition
        if kind == .table {
            var data = entry.tableData ?? .starter
            data.normalize()
            table = data
        }
    }

    private func save() {
        guard let repository else { return }
        var data = table
        data.normalize()
        do {
            if let entry {
                let changed = entry.text != text || entry.term != term || entry.definition != definition
                    || (kind == .table && entry.tableData != data)
                try repository.editEntry(entry) { target in
                    target.text = text
                    target.term = term
                    target.definition = definition
                    if kind == .table { target.tableData = data }
                    if changed, target.origin == .original { target.origin = .user }
                }
            } else {
                let isBlank = kind == .table
                    ? data.isBlank
                    : [text, term, definition].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if isBlank { dismiss(); return }
                try repository.addEntry(
                    to: topic, kind: kind, text: text, term: term, definition: definition,
                    tableData: kind == .table ? data : nil, origin: .user)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeReference(from entry: TopicEntry) {
        do {
            try repository?.editEntry(entry) { target in
                target.sourceReferences = []
                target.highlight = nil
                // Without a source it is no longer content taken from the learning material.
                if target.origin == .original { target.origin = .user }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// An editable grid: headers in the first row, cells below; add and remove rows and columns.
struct TableEditorView: View {
    @Binding var table: TableData

    private static let cellWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Color.clear.frame(width: 28, height: 1)
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Spalte \(column + 1)", text: Binding(
                                    get: { table.headers.indices.contains(column) ? table.headers[column] : "" },
                                    set: { table.setHeader($0, at: column) }
                                ))
                                .font(.body.weight(.semibold))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("tableHeader-\(column)")
                                Button("Spalte \(column + 1) entfernen", systemImage: "minus.circle") {
                                    table.removeColumn(at: column)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .disabled(table.columnCount <= 1)
                            }
                            .frame(minWidth: Self.cellWidth, alignment: .leading)
                        }
                    }
                    ForEach(0..<table.rows.count, id: \.self) { row in
                        GridRow {
                            Button("Zeile \(row + 1) entfernen", systemImage: "minus.circle") {
                                table.removeRow(at: row)
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                TextField("Zeile \(row + 1)", text: Binding(
                                    get: { cell(row, column) },
                                    set: { table.setCell($0, row: row, column: column) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: Self.cellWidth)
                                .accessibilityLabel("Zeile \(row + 1), Spalte \(column + 1)")
                                .accessibilityIdentifier("tableCell-\(row)-\(column)")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            ViewThatFits(in: .horizontal) {
                HStack { addButtons }
                VStack(alignment: .leading) { addButtons }
            }
        }
        .padding(.vertical, 4)
    }

    private var addButtons: some View {
        Group {
            Button("Zeile hinzufügen", systemImage: "plus.rectangle.on.rectangle") { table.addRow() }
                .accessibilityIdentifier("addTableRowButton")
            Button("Spalte hinzufügen", systemImage: "plus.square.on.square") { table.addColumn() }
                .accessibilityIdentifier("addTableColumnButton")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func cell(_ row: Int, _ column: Int) -> String {
        guard table.rows.indices.contains(row), table.rows[row].indices.contains(column) else { return "" }
        return table.rows[row][column]
    }
}
