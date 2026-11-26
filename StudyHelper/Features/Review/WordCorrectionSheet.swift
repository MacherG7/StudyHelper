import StudyAI
import StudyCore
import StudyData
import SwiftUI

/// Model suggestions already loaded in this session, per word and text (a sheet that is opened again does not ask
/// the model again).
@MainActor
enum WordSuggestionCache {
    struct Key: Hashable {
        var lineID: UUID
        var wordIndex: Int
        var text: String
    }

    static var storage: [Key: [String]] = [:]
}

/// Checks one marked word: the word cut out of the page, the line with the word highlighted, suggestions (at once
/// local ones, then the on-device model's), a field for the user's own reading, and the two ways to finish:
/// "Übernehmen" (corrects only this word) and "Wort ist richtig" (confirms it as written).
struct WordCorrectionSheet: View {
    let source: Source
    let lineID: UUID
    let wordIndex: Int
    /// The stored page image (handwriting); the word is cut out of it. nil: no picture is shown.
    let pageImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var coordinator
    @Environment(\.studyRepository) private var repository
    @Environment(AIService.self) private var ai

    enum ModelState: Equatable {
        case loading
        case ready
        /// The on-device model cannot be used (or failed); `message` is shown instead of its suggestions.
        case unavailable(String)
    }

    @State private var text = ""
    @State private var loaded = false
    @State private var remember = false
    @State private var local: [String] = []
    @State private var model: [String] = []
    @State private var modelState: ModelState = .loading
    @State private var crop: UIImage?
    @State private var errorMessage: String?

    /// Decoded once per change of the page, not on every render.
    @State private var linesCache = DerivedValue<[RecognizedLine]>()

    private var lines: [RecognizedLine] {
        linesCache.value(key: source.id) { source.currentDigitization?.lines ?? [] }
    }

    private var line: RecognizedLine? { lines.first { $0.id == lineID } }

    private var token: ReviewToken? {
        guard let line else { return nil }
        return WordReview.tokens(of: line).first { $0.index == wordIndex }
    }

    private var word: String { token.map { $0.core.isEmpty ? $0.text : $0.core } ?? "" }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var terms: Set<String> { Set(source.batch?.subject?.confirmedTerms ?? []) }

    /// Local suggestions first, then the model's that are new; the original word is never offered.
    private var suggestions: [(text: String, fromModel: Bool)] {
        let merged = WordReview.mergeSuggestions([local, model], original: word, limit: 10)
        let localKeys = Set(local.map { $0.lowercased() })
        return merged.map { ($0, !localKeys.contains($0.lowercased())) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let token, let line {
                    if let crop {
                        Section("Im Original") {
                            Image(uiImage: crop)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 110)
                                .accessibilityLabel("Ausschnitt aus dem Original: \(word)")
                                .accessibilityIdentifier("wordCrop")
                        }
                    }
                    Section("Zeile") {
                        Text(LineText.attributed(line: line, highlights: [], marked: [token]))
                            .accessibilityLabel("Zeile mit dem unsicheren Wort „\(word)“: \(line.text)")
                            .accessibilityIdentifier("wordLine")
                    }
                    suggestionSection
                    Section {
                        TextField("Wort", text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .accessibilityIdentifier("wordCorrectionField")
                        Toggle("Als Fachbegriff merken", isOn: $remember)
                            .accessibilityIdentifier("rememberWordToggle")
                    } header: {
                        Text("Dein Wort")
                    } footer: {
                        Text("Gemerkte Fachbegriffe gelten im ganzen Fach als richtig geschrieben und helfen der Texterkennung.")
                    }
                    Section {
                        Button(action: apply) {
                            Label("Übernehmen", systemImage: "checkmark").fontWeight(.semibold)
                        }
                        .disabled(trimmed.isEmpty || trimmed == word)
                        .accessibilityIdentifier("applyWordButton")
                        Button("Wort ist richtig", systemImage: "checkmark.seal", action: confirm)
                            .accessibilityIdentifier("confirmWordButton")
                    } footer: {
                        Text("Nur dieses Wort wird geändert. Die übrigen Wörter der Zeile bleiben, wie sie sind, und behalten ihre Markierungen.")
                    }
                } else {
                    ContentUnavailableView(
                        "Wort nicht gefunden", systemImage: "questionmark.square.dashed",
                        description: Text("Die Zeile hat sich geändert. Schließe das Fenster und wähle das Wort noch einmal."))
                }
            }
            .navigationTitle("Wort prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .accessibilityIdentifier("cancelWordButton")
                }
            }
            .errorAlert($errorMessage)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = word
                crop = Self.cropWord(token, from: pageImage)
            }
            // Cancelled when the sheet closes.
            .task { await loadSuggestions() }
        }
        .presentationDetents([.large])
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionSection: some View {
        let items = suggestions
        Section {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    text = item.text
                } label: {
                    HStack {
                        Text(item.text)
                        Spacer(minLength: 0)
                        if item.fromModel {
                            Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(item.fromModel ? "\(item.text), Vorschlag des Geräte-Modells" : item.text)
                .accessibilityIdentifier("wordSuggestion-\(index)")
            }
            if items.isEmpty, modelState != .loading {
                Text("Keine Vorschläge")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("noWordSuggestions")
            }
            switch modelState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Geräte-Modell denkt nach…").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wordModelLoading")
            case .unavailable(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wordModelHint")
            case .ready:
                EmptyView()
            }
        } header: {
            Text("Vorschläge")
        } footer: {
            Text("Die Vorschläge zeigen nur andere Lesarten dieses einen Wortes. Es wird nichts hinzugefügt.")
        }
    }

    private func loadSuggestions() async {
        guard let line, let token else { return }
        local = WordReview.localSuggestions(
            line: line, wordIndex: wordIndex, checker: AppSpellChecker.shared, terms: terms)
        let key = WordSuggestionCache.Key(lineID: lineID, wordIndex: wordIndex, text: token.text)
        if let cached = WordSuggestionCache.storage[key] {
            model = cached
            modelState = .ready
            return
        }
        modelState = .loading
        let context = WordReview.context(of: wordIndex, in: lineID, lines: lines)
        do {
            let result = try await ai.suggestWords(
                word: word, before: context.before, after: context.after, subject: source.batch?.subject?.name)
            guard !Task.isCancelled else { return }
            WordSuggestionCache.storage[key] = result
            model = result
            modelState = .ready
        } catch {
            guard !Task.isCancelled else { return }
            if let provider = error.providerError, case .unavailable = provider {
                modelState = .unavailable(AIService.onDeviceUnavailableMessage)
            } else {
                modelState = .unavailable("Das Geräte-Modell konnte keine Vorschläge liefern.")
            }
        }
    }

    // MARK: Finishing

    private func apply() {
        guard !trimmed.isEmpty else { return }
        finish(with: trimmed)
    }

    private func confirm() {
        finish(with: word)
    }

    private func finish(with newText: String) {
        guard let repository else { return }
        do {
            try repository.correctWord(source: source, lineID: lineID, wordIndex: wordIndex, newText: newText)
            if remember, let subject = source.batch?.subject {
                let term = WordReview.splitPunctuation(newText).core
                if !term.isEmpty { try repository.addConfirmedTerm(term, to: subject) }
            }
            // Topics whose entries took over the old text are now affected.
            coordinator.reportImpact(of: [source])
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Word picture

    /// The word with some of its surroundings, cut out of the page image.
    static func cropWord(_ token: ReviewToken?, from image: UIImage?) -> UIImage? {
        guard let token, let image, let cgImage = image.cgImage else { return nil }
        let width = Double(cgImage.width), height = Double(cgImage.height)
        let rect = token.rect
        guard !rect.isEmpty, width > 0, height > 0 else { return nil }
        let marginX = max(rect.height * height, 0.02 * width)
        let marginY = rect.height * height * 0.5
        let x0 = max(0, rect.x * width - marginX)
        let y0 = max(0, rect.y * height - marginY)
        let x1 = min(width, (rect.x + rect.width) * width + marginX)
        let y1 = min(height, (rect.y + rect.height) * height + marginY)
        guard x1 - x0 >= 2, y1 - y0 >= 2,
              let cropped = cgImage.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral)
        else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
