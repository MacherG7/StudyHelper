import StudyCore
import StudyData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Developer settings: the reported recognition errors, grouped by import and page. Copy as chat text, share as
/// a JSON file, delete single entries or all of them.
struct RecognitionReportListView: View {
    @Environment(RecognitionReportStore.self) private var store
    @Query(sort: \ImportBatch.createdAt) private var batches: [ImportBatch]
    /// Off by default: corrections are the user's own texts and only leave the list when asked for (not a secret, so
    /// UserDefaults is fine).
    @AppStorage(RecognitionReportCorrections.includeKey) private var includeCorrections = false
    /// Imports with corrections (loaded while the toggle is on).
    @State private var candidates: [CorrectionCandidate] = []
    /// The imports the user chose; nil means the default (imports that have reported errors).
    @State private var chosenImportIDs: Set<UUID>?
    @State private var copied = false
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            if let note = store.loadNote {
                Section {
                    Text(note)
                        .font(.footnote)
                        .accessibilityIdentifier("reportsLoadNote")
                    Button("Hinweis schließen") { store.clearLoadNote() }
                }
            }
            if let error = store.saveError {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Toggle("Korrekturen mitschicken", isOn: $includeCorrections)
                    .accessibilityIdentifier("includeCorrectionsToggle")
            } footer: {
                Text(includeCorrections
                     ? (candidates.isEmpty
                        ? "Deine Importe enthalten noch keine Textkorrekturen."
                        : "Beim Kopieren und Teilen werden zusätzlich die \(correctionCount) Textkorrekturen der gewählten Importe angehängt. Das sind deine eigenen Texte aus dem Lernstoff.")
                     : "Beim Kopieren und Teilen werden nur die gemeldeten Fehler verwendet. Deine Textkorrekturen bleiben auf dem Gerät.")
            }
            if includeCorrections, !candidates.isEmpty {
                Section("Importe mit Korrekturen") {
                    ForEach(candidates) { candidate in
                        Toggle(isOn: selectionBinding(for: candidate.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                Text(candidate.count == 1 ? "1 Korrektur" : "\(candidate.count) Korrekturen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("includeImportToggle")
                    }
                }
            }
            if store.isEmpty {
                Section {
                    Text("Noch keine Erkennungsfehler gemeldet. Wähle in der Prüfansicht eine Zeile und tippe auf „Fehler melden“ oder markiere einen Bereich.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("noReportsText")
                }
            } else {
                ForEach(groups, id: \.id) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            NavigationLink {
                                RecognitionReportEntryDetail(entry: entry)
                            } label: {
                                ReportEntryRow(entry: entry)
                            }
                            .swipeActions {
                                Button("Löschen", role: .destructive) { store.delete(entry.id) }
                            }
                            .accessibilityIdentifier("reportEntryRow")
                        }
                    }
                }
            }
        }
        .navigationTitle("Erkennungsfehler")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Bericht kopieren", systemImage: "doc.on.doc", action: copyReport)
                    .disabled(!hasExportableContent)
                    .accessibilityIdentifier("copyReportButton")
                ShareLink(
                    item: ReportFile(build: { try makeExportFile() }),
                    preview: SharePreview("Erkennungsfehler")
                ) {
                    Label("Als Datei teilen", systemImage: "square.and.arrow.up")
                }
                .disabled(!hasExportableContent)
                .accessibilityIdentifier("shareReportButton")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Alles löschen", role: .destructive) { confirmDeleteAll = true }
                    .disabled(store.isEmpty)
                    .accessibilityIdentifier("deleteAllReportsButton")
            }
        }
        .confirmationDialog("Alle Erkennungsfehler löschen?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Alles löschen", role: .destructive) { store.deleteAll() }
                .accessibilityIdentifier("confirmDeleteAllReportsButton")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die gemeldeten Fehler dieser Liste werden unwiderruflich gelöscht. Deine Importe und Korrekturen bleiben erhalten.")
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("Kopiert")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 60)
                    .transition(.opacity)
                    .accessibilityIdentifier("copiedConfirmation")
            }
        }
        .task(id: includeCorrections) { refreshCandidates() }
        .onAppear { refreshCandidates() }
    }

    // MARK: Chosen imports

    private struct CorrectionCandidate: Identifiable {
        let id: UUID
        let name: String
        let count: Int
    }

    /// The imports whose corrections are sent: the choice, or by default those with reported errors.
    private var effectiveImportIDs: Set<UUID> {
        chosenImportIDs ?? RecognitionReportCorrections.defaultSelection(
            candidates: Set(candidates.map(\.id)), reportedImports: Set(store.entries.map(\.importID)))
    }

    private var correctionCount: Int {
        let chosen = effectiveImportIDs
        return candidates.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.count }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { effectiveImportIDs.contains(id) },
            set: { isOn in
                var current = effectiveImportIDs
                if isOn { current.insert(id) } else { current.remove(id) }
                chosenImportIDs = current
            })
    }

    // MARK: Export

    private var hasExportableContent: Bool {
        !store.isEmpty || (includeCorrections && correctionCount > 0)
    }

    /// The imports whose corrections go into the report right now (none unless the toggle is on).
    private var selectedBatches: [ImportBatch] {
        guard includeCorrections else { return [] }
        let chosen = effectiveImportIDs
        return batches.filter { chosen.contains($0.id) }
    }

    /// The report as it is exported right now: stored entries plus (optionally) the current corrections.
    private func exportReport() -> RecognitionReport {
        guard includeCorrections else { return store.makeReport() }
        let corrections = RecognitionReportCorrections.collect(from: selectedBatches)
        return store.makeReport(extraEntries: corrections.entries, extraImports: corrections.imports)
    }

    private func refreshCandidates() {
        guard includeCorrections else { candidates = []; return }
        let collected = RecognitionReportCorrections.collect(from: batches)
        let counts = Dictionary(grouping: collected.entries, by: \.importID).mapValues(\.count)
        candidates = collected.imports.map {
            CorrectionCandidate(id: $0.id, name: $0.fileName.isEmpty ? "Quelle" : $0.fileName, count: counts[$0.id] ?? 0)
        }
    }

    private func copyReport() {
        UIPasteboard.general.string = exportReport().chatText()
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    /// Writes `StudyHelper-Erkennungsfehler-<date>.json` into a fresh temporary folder.
    private func makeExportFile() throws -> URL {
        let data = try exportReport().encodedJSON()
        let day = Date().formatted(.iso8601.year().month().day())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Erkennungsfehler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("StudyHelper-Erkennungsfehler-\(day).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Grouping

    private struct ReportGroup {
        let id: UUID
        let title: String
        let entries: [RecognitionReportEntry]
    }

    /// Entries by import (newest import entry first inside, ordered by page).
    private var groups: [ReportGroup] {
        Dictionary(grouping: store.entries, by: \.importID)
            .map { importID, entries in
                let info = store.importInfo(for: importID)
                let name = info.map { $0.fileName.isEmpty ? "Quelle" : $0.fileName } ?? "Unbekannte Quelle"
                let sorted = entries.sorted { ($0.page, $0.createdAt) < ($1.page, $1.createdAt) }
                return ReportGroup(id: importID, title: "\(name) (\(entries.count))", entries: sorted)
            }
            .sorted { $0.title < $1.title }
    }
}

// MARK: - Transferable file

/// A JSON file that is written when the share sheet asks for it (so it is always up to date).
struct ReportFile: Transferable {
    let build: @MainActor () throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try await file.build())
        }
    }
}

// MARK: - Row and detail

private struct ReportEntryRow: View {
    let entry: RecognitionReportEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = entry.imageJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 44)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("S. \(entry.page) · \(entry.kind.displayName)")
                    .font(.subheadline.weight(.semibold))
                if let recognized = entry.recognized {
                    Text(recognized).font(.footnote).lineLimit(2)
                }
                if let expected = entry.expected {
                    Text("→ \(expected)").font(.footnote).foregroundStyle(.green).lineLimit(2)
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// All data of one reported entry.
struct RecognitionReportEntryDetail: View {
    let entry: RecognitionReportEntry

    var body: some View {
        Form {
            Section {
                LabeledContent("Art", value: entry.kind.displayName)
                LabeledContent("Seite", value: "\(entry.page)")
                LabeledContent("Bereich", value: Self.areaText(entry.rect))
                LabeledContent("Erstellt", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Erkannt") { text(entry.recognized) }
            if entry.expected != nil { Section("Richtig wäre") { text(entry.expected) } }
            if let after = entry.after { Section("Gehört hinter") { text(after.text) } }
            if let note = entry.note, !note.isEmpty { Section("Notiz") { text(note) } }
            if entry.context.before != nil || entry.context.after != nil {
                Section("Umgebung") {
                    if let before = entry.context.before { LabeledContent("Davor", value: before) }
                    if let after = entry.context.after { LabeledContent("Danach", value: after) }
                }
            }
            Section("Erkennung") {
                LabeledContent("Verfahren", value: entry.method ?? "unbekannt")
                if let engine = entry.engine { LabeledContent("Engine", value: engine) }
            }
            if let data = entry.imageJPEG, let image = UIImage(data: data) {
                Section("Bildausschnitt") {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel("Bildausschnitt der gemeldeten Stelle")
                }
            }
        }
        .navigationTitle("Fehler auf Seite \(entry.page)")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("reportEntryDetail")
    }

    private static func areaText(_ rect: NormalizedRect) -> String {
        String(format: "x %.2f y %.2f b %.2f h %.2f", rect.x, rect.y, rect.width, rect.height)
    }

    @ViewBuilder private func text(_ value: String?) -> some View {
        if let value, !value.isEmpty {
            Text(value).textSelection(.enabled)
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }
}
