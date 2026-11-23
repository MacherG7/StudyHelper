import StudyCore
import StudyData
import SwiftUI

/// Corrections that found no counterpart after the last re-recognition (or version restore).
/// They stay stored until the user discards them.
struct UnmatchedCorrectionsView: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            let lineCorrections = source.corrections.filter(\.isUnmatched).sorted { $0.createdAt < $1.createdAt }
            let highlightCorrections = source.highlightCorrections.filter(\.isUnmatched).sorted { $0.createdAt < $1.createdAt }
            List {
                Section {
                    Text("Zu diesen Korrekturen wurde im neuen Ergebnis keine passende Stelle gefunden, zum Beispiel weil die Zeile anders erkannt oder geteilt wurde. Sie bleiben gespeichert, bis du sie verwirfst.")
                        .font(.footnote)
                }
                if !lineCorrections.isEmpty {
                    Section("Texte") {
                        ForEach(lineCorrections) { correction in
                            let value = correction.value
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Erkannt: \(value.recognizedText)").font(.footnote).foregroundStyle(.secondary)
                                Text("Dein Text: \(value.correctedText)")
                                Button("Verwerfen", systemImage: "trash", role: .destructive) { discard(correction) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("discardCorrectionButton")
                            }
                        }
                    }
                }
                if !highlightCorrections.isEmpty {
                    Section("Hervorhebungen") {
                        ForEach(highlightCorrections) { correction in
                            VStack(alignment: .leading, spacing: 4) {
                                if let value = correction.value {
                                    Text("„\(value.text)“").font(.subheadline)
                                    Text(description(of: value)).font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Text("Nicht lesbare Korrektur").foregroundStyle(.secondary)
                                }
                                Button("Verwerfen", systemImage: "trash", role: .destructive) { discard(correction) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("discardCorrectionButton")
                            }
                        }
                    }
                }
                if lineCorrections.isEmpty, highlightCorrections.isEmpty {
                    Section { Text("Keine offenen Korrekturen.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Nicht zugeordnet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .errorAlert($errorMessage)
        }
    }

    private func description(of value: HighlightCorrectionValue) -> String {
        switch value.action {
        case .add: "Hinzugefügt: \(value.kind?.germanName ?? "Hervorhebung")"
        case .modify: "Geändert: \(value.kind?.germanName ?? "Hervorhebung")"
        case .delete: "Gelöscht: \(value.originalKind?.germanName ?? "Hervorhebung")"
        }
    }

    private func discard(_ correction: LineCorrection) {
        do { try repository?.discard(correction) } catch { errorMessage = error.localizedDescription }
    }

    private func discard(_ correction: HighlightCorrection) {
        do { try repository?.discard(correction) } catch { errorMessage = error.localizedDescription }
    }
}
