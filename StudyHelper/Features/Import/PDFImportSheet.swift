import StudyCore
import StudyData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Import of one PDF, optionally with the reduced Goodnotes export of the same note.
/// Used from the subject screen (`subject` set) and for files opened via "Öffnen in" (subject chosen here).
struct PDFImportSheet: View {
    let subject: Subject?
    let urls: [URL]
    let incoming: IncomingFiles.File?

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var coordinator
    @Environment(IncomingFiles.self) private var incomingFiles
    @Query(sort: [SortDescriptor(\Subject.sortIndex), SortDescriptor(\Subject.createdAt)])
    private var subjects: [Subject]

    @State private var files: [PickedPDF] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var chosenSubjectID: UUID?
    @State private var showSecondImporter = false
    @State private var confirmPairing = false
    @State private var showNewSubject = false
    @State private var confirmDiscard = false

    private var pairing: PDFPairing? { PDFPairing(files: files) }

    private var targetSubject: Subject? {
        subject ?? subjects.first { $0.id == chosenSubjectID } ?? subjects.first
    }

    private var canImport: Bool {
        !isLoading && pairing != nil && targetSubject != nil && !coordinator.isRunning
    }

    var body: some View {
        NavigationStack {
            Form {
                if subject == nil {
                    Section("Fach") {
                        if subjects.isEmpty {
                            Text("Lege zuerst ein Fach an, dann kannst du die Datei importieren.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Fach", selection: Binding(
                                get: { chosenSubjectID ?? subjects.first?.id },
                                set: { chosenSubjectID = $0 }
                            )) {
                                ForEach(subjects) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .accessibilityIdentifier("incomingSubjectPicker")
                        }
                        Button("Neues Fach anlegen", systemImage: "plus.circle") { showNewSubject = true }
                            .accessibilityIdentifier("newSubjectFromImportButton")
                    }
                }

                Section("Dateien") {
                    if isLoading {
                        HStack { ProgressView(); Text("Datei wird gelesen…").padding(.leading, 8) }
                    }
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.headline).lineLimit(2)
                            Text("\(file.variantName) · \(file.pageCount == 1 ? "1 Seite" : "\(file.pageCount) Seiten")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let loadError {
                        InfoBanner(loadError, style: .error)
                    }
                    if !isLoading, files.count == 1 {
                        Button("Reduziertes Goodnotes-PDF hinzufügen (optional)", systemImage: "plus.circle") {
                            showSecondImporter = true
                        }
                        .accessibilityIdentifier("addReducedPDFButton")
                    }
                }

                if let pairing {
                    switch pairing.state {
                    case .single:
                        if pairing.main.variant == .editable {
                            Section {
                                Text("Mit dem reduzierten PDF derselben Notiz kann die App die erkannte Handschrift abgleichen und unsichere Stellen besser finden.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    case .compatible:
                        if let reduced = pairing.reduced {
                            Section {
                                Text("Beide Exporte haben dieselbe Seitenzahl und Seitengröße (bearbeitbar: \(pairing.main.pageCount), reduziert: \(reduced.pageCount) Seiten). Vor dem Import bestätigst du, dass sie zur selben Notiz gehören.")
                                    .font(.footnote)
                            }
                        }
                    case .incompatible(let reason):
                        Section { InfoBanner(reason, style: .warning) }
                    }
                }

                if coordinator.isRunning {
                    Section { InfoBanner("Es läuft bereits ein Import. Starte diesen, sobald er fertig ist.", style: .info) }
                }
            }
            .navigationTitle("PDF importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { cancelTapped() }
                        .accessibilityIdentifier("cancelPDFImportButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importieren") { importTapped() }
                        .disabled(!canImport)
                        .accessibilityIdentifier("startPDFImportButton")
                }
            }
            .confirmationDialog(
                "Gehören diese beiden Exporte zur selben Notiz?",
                isPresented: $confirmPairing, titleVisibility: .visible
            ) {
                Button("Ja, zusammen importieren") { startImport(withReduced: true) }
                Button("Nein, nur das bearbeitbare PDF importieren") { startImport(withReduced: false) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                if let pairing, let reduced = pairing.reduced {
                    Text("„\(pairing.main.name)“: \(pairing.main.pageCount) Seiten\n„\(reduced.name)“: \(reduced.pageCount) Seiten")
                }
            }
            .confirmationDialog(
                "Datei verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible
            ) {
                Button("Verwerfen", role: .destructive) { discardIncoming() }
                    .accessibilityIdentifier("discardIncomingButton")
                Button("Zurück zum Import", role: .cancel) {}
            } message: {
                Text("„\(incoming?.originalName ?? "Die Datei")“ wurde noch nicht importiert. Wenn du sie verwirfst, wird die Kopie in StudyHelper gelöscht; die Originaldatei bleibt in der anderen App.")
            }
            .sheet(isPresented: $showNewSubject) {
                SubjectNameSheet(mode: .add) { created in chosenSubjectID = created.id }
            }
            .fileImporter(
                isPresented: $showSecondImporter,
                allowedContentTypes: [.pdf, UTType(filenameExtension: "goodnotes") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let picked):
                    if let url = picked.first { Task { await add(url) } }
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
            .task { await loadInitial() }
        }
        // A file opened via "Öffnen in" is only dropped on purpose (import or "Verwerfen"), never by a swipe.
        .interactiveDismissDisabled(incoming != nil)
    }

    private func cancelTapped() {
        // Ask before throwing a readable, not yet imported file away.
        if incoming != nil, !files.isEmpty {
            confirmDiscard = true
        } else {
            discardIncoming()
        }
    }

    private func discardIncoming() {
        if let incoming { incomingFiles.finish(incoming) }
        dismiss()
    }

    private func loadInitial() async {
        guard files.isEmpty else { return }
        for (index, url) in urls.enumerated() {
            let name = index == 0 ? incoming?.originalName : nil
            do {
                files.append(try await PDFLoader.load(url: url, displayName: name))
            } catch {
                loadError = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func add(_ url: URL) async {
        loadError = nil
        do {
            files.append(try await PDFLoader.load(url: url))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func importTapped() {
        guard let pairing else { return }
        if case .compatible = pairing.state {
            confirmPairing = true
        } else {
            startImport(withReduced: false)
        }
    }

    private func startImport(withReduced: Bool) {
        guard let pairing, let target = targetSubject else { return }
        coordinator.importPDF(main: pairing.main, reduced: withReduced ? pairing.reduced : nil, into: target)
        if let incoming { incomingFiles.finish(incoming) }
        dismiss()
    }
}
