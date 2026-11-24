import StudyAI
import StudyData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Developer mode: every AI request with tokens, cost and details (SPEC §10).
struct RequestLogView: View {
    @Environment(\.studyRepository) private var repository
    @Query(sort: \RequestLog.date, order: .reverse) private var logs: [RequestLog]

    @State private var exportDocument: JSONExportDocument?
    @State private var showExporter = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if logs.isEmpty {
                ContentUnavailableView(
                    "Noch keine Anfragen", systemImage: "list.bullet.rectangle",
                    description: Text("Jede Anfrage an die KI, auch jede fehlgeschlagene, erscheint hier."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    NavigationLink("Summen nach Tag und Monat") { RequestLogTotalsView(logs: logs) }
                        .accessibilityIdentifier("totalsLink")
                }
                Section {
                    ForEach(logs) { log in
                        NavigationLink {
                            RequestLogDetailView(log: log)
                        } label: {
                            RequestLogRow(log: log)
                        }
                        .accessibilityIdentifier("requestLogRow")
                    }
                } header: {
                    Text("\(logs.count) Anfragen, neueste zuerst")
                }
            }
        }
        .navigationTitle("Anfrage-Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Mehr", systemImage: "ellipsis.circle") {
                    Button("Als JSON exportieren", systemImage: "square.and.arrow.up") { prepareExport() }
                        .disabled(logs.isEmpty)
                        .accessibilityIdentifier("exportLogsButton")
                    Button("Logs löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(logs.isEmpty)
                        .accessibilityIdentifier("deleteLogsButton")
                }
                .accessibilityIdentifier("logMenu")
            }
        }
        .fileExporter(
            isPresented: $showExporter, document: exportDocument, contentType: .json,
            defaultFilename: "StudyHelper-Anfrage-Log"
        ) { result in
            if case .failure = result { errorMessage = "Der Export konnte nicht gespeichert werden." }
        }
        .confirmationDialog("Alle Logs löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Logs löschen", role: .destructive) { deleteAll() }
                .accessibilityIdentifier("confirmDeleteLogsButton")
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Einträge des Anfrage-Logs werden gelöscht. Das kann nicht rückgängig gemacht werden.")
        }
        .errorAlert($errorMessage)
    }

    private func prepareExport() {
        guard let repository else { return }
        do {
            exportDocument = JSONExportDocument(data: try repository.exportRequestLogsJSON())
            showExporter = true
        } catch {
            errorMessage = "Der Export konnte nicht erstellt werden."
        }
    }

    private func deleteAll() {
        do { try repository?.deleteAllRequestLogs() } catch { errorMessage = "Die Logs konnten nicht gelöscht werden." }
    }
}

/// JSON file for `fileExporter`.
struct JSONExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct RequestLogRow: View {
    let log: RequestLog

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(AITask(rawValue: log.task)?.germanName ?? log.task).font(.headline)
                if log.errorMessage != nil {
                    Text("Fehler")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.2), in: Capsule())
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("logErrorBadge")
                }
                Spacer()
                Text(log.date, format: .dateTime.day().month().hour().minute().second())
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("\(log.providerName) · \(log.model)").font(.footnote).foregroundStyle(.secondary)
            Text("Eingabe \(LogFormat.tokens(log.inputTokens)) · Ausgabe \(LogFormat.tokens(log.outputTokens)) Tokens · \(LogFormat.cost(of: log))")
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Totals

struct RequestLogTotalsView: View {
    let logs: [RequestLog]
    @State private var period: RequestLogTotals.Period = .day

    private var totals: [PeriodTotals] {
        RequestLogTotals.totals(logs.map(LogUsage.init), by: period)
    }

    var body: some View {
        List {
            Section {
                Picker("Zeitraum", selection: $period) {
                    Text("Tag").tag(RequestLogTotals.Period.day)
                    Text("Monat").tag(RequestLogTotals.Period.month)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("totalsPeriodPicker")
            }
            ForEach(totals) { entry in
                Section {
                    summaryRow("Gesamt", entry.total)
                    group("Nach Anbieter", entry.byProvider)
                    group("Nach Modell", entry.byModel)
                    group("Nach Aufgabe", entry.byTask)
                } header: {
                    Text(
                        period == .day
                            ? entry.start.formatted(.dateTime.day().month(.wide).year())
                            : entry.start.formatted(.dateTime.month(.wide).year()))
                }
            }
            Section {
                Text("Alle Kosten sind geschätzt. Anfragen ohne bekannten Preis fehlen in den Kostensummen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Summen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ title: String, _ sums: [String: UsageSum]) -> some View {
        DisclosureGroup(title) {
            ForEach(sums.keys.sorted(), id: \.self) { key in
                if let sum = sums[key] { summaryRow(key, sum) }
            }
        }
    }

    private func summaryRow(_ title: String, _ sum: UsageSum) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text("\(sum.requests) Anfragen · \(LogFormat.tokens(sum.inputTokens)) Eingabe · \(LogFormat.tokens(sum.outputTokens)) Ausgabe")
                .font(.footnote).foregroundStyle(.secondary)
            Text("\(LogFormat.amount(sum.costEUR, symbol: "€")) · \(LogFormat.amount(sum.costUSD, symbol: "$")) geschätzt"
                + (sum.unknownCostRequests > 0 ? " · \(sum.unknownCostRequests) ohne Preis" : ""))
                .font(.footnote)
        }
    }
}

// MARK: - Detail

struct RequestLogDetailView: View {
    let log: RequestLog

    private var detail: RequestLogDetail? { try? JSONDecoder().decode(RequestLogDetail.self, from: log.detailData) }

    var body: some View {
        List {
            Section("Anfrage") {
                row("Aufgabe", AITask(rawValue: log.task)?.germanName ?? log.task)
                row("Anbieter", "\(log.providerName) (\(ProviderKind(rawValue: log.providerKind)?.germanName ?? log.providerKind))")
                row("Modell", log.model)
                row("Denktiefe", log.reasoning.flatMap { ReasoningLevel(rawValue: $0)?.germanName } ?? "Standard")
                row("Gesendet", sentText)
                if let units = detail?.metadata.learningUnitIDsInContext, !units.isEmpty {
                    row("Lerneinheiten", units.joined(separator: ", "))
                }
                row("Werkzeugaufrufe", "\(log.toolCallCount)")
            }
            Section("Tokens") {
                row("Eingabe", LogFormat.tokens(log.inputTokens))
                row("Ausgabe", LogFormat.tokens(log.outputTokens))
                row("Cache gelesen", LogFormat.tokens(log.cacheReadTokens))
                row("Cache geschrieben", LogFormat.tokens(log.cacheWriteTokens))
                row("Denk-Tokens", LogFormat.tokens(log.reasoningTokens))
            }
            Section {
                row("Kosten", LogFormat.cost(of: log))
                row("Dauer", LogFormat.seconds(log.duration))
                if let first = log.timeToFirstToken { row("Bis zum ersten Token", LogFormat.seconds(first)) }
                if let speed = detail?.metadata.outputTokensPerSecond {
                    row("Tokens pro Sekunde", speed.formatted(.number.precision(.fractionLength(1))))
                }
            } header: {
                Text("Kosten und Zeit")
            } footer: {
                Text("Alle Kosten sind geschätzt.")
            }
            if let error = log.errorMessage {
                Section("Fehler") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("logErrorMessage")
                }
            }
            if let parsing = log.parsingError {
                Section("Auswertungsfehler") { Text(parsing).textSelection(.enabled) }
            }
            if let detail {
                Section("Inhalte") {
                    textGroup("System-Prompt", detail.systemPrompt, id: "systemPrompt")
                    textGroup("Prompt", detail.prompt, id: "prompt")
                    textGroup("Rohe Anfrage", detail.metadata.rawRequest, id: "rawRequest")
                    textGroup("Rohe Antwort", detail.metadata.rawResponse, id: "rawResponse")
                    if let reasoning = detail.metadata.reasoningText, !reasoning.isEmpty {
                        textGroup("Denktext", reasoning, id: "reasoningText")
                    }
                    ForEach(detail.metadata.toolCalls, id: \.id) { call in
                        textGroup("Werkzeugaufruf \(call.name)", call.arguments, id: "toolCall-\(call.id)")
                    }
                }
            }
        }
        .navigationTitle("Anfrage")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("requestLogDetail")
    }

    private var sentText: String {
        switch (log.sentText, log.sentImage) {
        case (true, true): "Text und Bild"
        case (false, true): "Bild"
        case (true, false): "Text"
        default: "nichts"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }

    private func textGroup(_ title: String, _ text: String, id: String) -> some View {
        DisclosureGroup(title) {
            Text(text.isEmpty ? "(leer)" : text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                .font(.footnote)
        }
        .accessibilityIdentifier("disclosure-\(id)")
    }
}
