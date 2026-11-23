import StudyCore
import StudyData
import SwiftUI

/// Edit the text of one line. The correction is saved by the repository, survives re-recognition and wins
/// over every automatic result.
struct CorrectionSheet: View {
    let source: Source
    let lineID: UUID
    /// Called after saving with a hint about topics that refer to the line (nil: none).
    let onSaved: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyRepository) private var repository
    @State private var text = ""
    @State private var loaded = false
    @State private var rememberedTerms: Set<String> = []
    @State private var errorMessage: String?

    /// Decoded once per change of the line, not on every render.
    @State private var lineCache = DerivedValue<RecognizedLine?>()

    private var line: RecognizedLine? {
        lineCache.value(key: lineID) { source.currentDigitization?.lines.first { $0.id == lineID } }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// New words of the entered text: candidates for the subject's recognition vocabulary.
    private var newWords: [String] {
        guard let line, trimmed != line.text else { return [] }
        let known = Set(line.text.split(separator: " ").map { Self.clean($0).lowercased() })
        var seen = Set<String>()
        return trimmed.split(separator: " ").map { Self.clean($0) }.filter { word in
            word.count >= 4 && !known.contains(word.lowercased()) && seen.insert(word.lowercased()).inserted
        }
        .prefix(6).map { $0 }
    }

    private static func clean(_ word: Substring) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text der Zeile", text: $text)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityIdentifier("correctionTextField")
                    if let line, line.isUserCorrected, line.automaticText != text {
                        Button("Auf erkannten Text zurücksetzen", systemImage: "arrow.uturn.backward") {
                            text = line.automaticText
                        }
                    }
                } header: {
                    Text("Text")
                } footer: {
                    if let line, line.isUserCorrected {
                        Text("Erkannt wurde: „\(line.automaticText)“")
                    } else {
                        Text("Speichern ohne Änderung bestätigt den erkannten Text.")
                    }
                }

                if let line {
                    let suggestions = line.candidates.filter { $0 != text }
                    if !suggestions.isEmpty {
                        Section("Vorschläge der Erkennung") {
                            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, candidate in
                                Button {
                                    text = candidate
                                } label: {
                                    Text(candidate).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityIdentifier("candidate-\(index)")
                            }
                        }
                    }
                }

                if !newWords.isEmpty {
                    Section {
                        ForEach(newWords, id: \.self) { word in
                            Toggle(word, isOn: Binding(
                                get: { rememberedTerms.contains(word) },
                                set: { if $0 { rememberedTerms.insert(word) } else { rememberedTerms.remove(word) } }
                            ))
                        }
                    } header: {
                        Text("Fachbegriffe merken")
                    } footer: {
                        Text("Gemerkte Wörter helfen der Texterkennung bei späteren Importen und beim Neu-Erkennen dieses Fachs.")
                    }
                }

                Section {
                    Text("Deine Korrektur hat Vorrang vor jeder automatischen Erkennung und bleibt auch bei „Neu erkennen“ erhalten.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Zeile korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("saveCorrectionButton")
                }
            }
            .errorAlert($errorMessage)
            .onAppear {
                guard !loaded else { return }
                text = line?.text ?? ""
                loaded = true
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let repository, !trimmed.isEmpty else { return }
        do {
            try repository.correctLine(source: source, lineID: lineID, newText: trimmed)
            if let subject = source.batch?.subject {
                for term in rememberedTerms { try repository.addConfirmedTerm(term, to: subject) }
            }
            let topics = try repository.affectedTopics(bySourceID: source.id, lineIDs: [lineID])
            onSaved(topics.isEmpty ? nil : "Betroffene Themen: " + topics.map(\.title).joined(separator: ", ") + ". Prüfe, ob der Inhalt dort noch stimmt.")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
