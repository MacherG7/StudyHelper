import StudyAI
import StudyCore
import StudyData
import StudyImport
import SwiftUI

/// Checks one marked word (D-044): a sharp picture of just the word with the line as a small preview, the most likely
/// reading on top with "Übernehmen", further readings below, a field for the user's own reading, and the other ways
/// to finish: "Wort ist richtig" (confirms it as written) and "Als Fachbegriff merken".
struct WordCorrectionSheet: View {
    let source: Source
    let lineID: UUID
    let wordIndex: Int
    /// Set when the sheet is a step of `WordCheckSequence`: "Wort 2 von 7", and finishing moves on instead of closing.
    var progress: Progress?
    var onDone: (() -> Void)?
    var onSkip: (() -> Void)?

    struct Progress: Equatable {
        var position: Int
        var total: Int
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ImportCoordinator.self) private var coordinator
    @Environment(\.studyRepository) private var repository
    @Environment(AIService.self) private var ai

    @State private var text = ""
    @State private var loaded = false
    @State private var remember = false
    @State private var crop: UIImage?
    @State private var candidates: [WordCandidate] = []
    /// The ink was read again the same way: the word is most likely right as written (D-047).
    @State private var readingConfirmed = false
    @State private var isLoading = true
    @State private var modelMissing = false
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

    /// The candidates that differ from the word as written.
    private var options: [WordCandidate] {
        candidates.filter { $0.text != word && !$0.text.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let token, let line {
                    Section {
                        picture(token: token, line: line)
                    }
                    if readingConfirmed {
                        confirmedSection
                    }
                    suggestionSection
                    Section {
                        TextField("Wort", text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .accessibilityIdentifier("wordCorrectionField")
                        Button(action: { finish(with: trimmed) }) {
                            Label("Übernehmen", systemImage: "checkmark").fontWeight(.semibold)
                        }
                        .disabled(trimmed.isEmpty || trimmed == word)
                        .accessibilityIdentifier("applyWordButton")
                    } header: {
                        Text("Dein Wort")
                    }
                    Section {
                        if !readingConfirmed {
                            Button("Wort ist richtig", systemImage: "checkmark.seal") { finish(with: word) }
                                .accessibilityIdentifier("confirmWordButton")
                        }
                        Toggle("Als Fachbegriff merken", isOn: $remember)
                            .accessibilityIdentifier("rememberWordToggle")
                    } footer: {
                        Text("Gemerkte Fachbegriffe gelten im ganzen Fach als richtig geschrieben und helfen der Texterkennung. Nur dieses Wort wird geändert; die übrigen Markierungen der Zeile bleiben.")
                    }
                } else {
                    ContentUnavailableView(
                        "Wort nicht gefunden", systemImage: "questionmark.square.dashed",
                        description: Text("Die Zeile hat sich geändert. Schließe das Fenster und wähle das Wort noch einmal."))
                }
            }
            .navigationTitle(progress.map { "Wort \($0.position) von \($0.total)" } ?? "Wort prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(progress == nil ? "Abbrechen" : "Beenden") { dismiss() }
                        .accessibilityIdentifier("cancelWordButton")
                }
                if let onSkip {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Überspringen", action: onSkip)
                            .accessibilityIdentifier("skipWordButton")
                    }
                }
            }
            .errorAlert($errorMessage)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = word
            }
            // Cancelled when the sheet closes.
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    // MARK: Picture and line

    @ViewBuilder
    private func picture(token: ReviewToken, line: RecognizedLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let crop {
                    Image(uiImage: crop)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 130)
                        .accessibilityLabel("Ausschnitt aus dem Original: \(word)")
                        .accessibilityIdentifier("wordCrop")
                } else {
                    Text(word)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Unsicheres Wort: \(word)")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            Text(LineText.attributed(line: line, highlights: [], marked: [token]))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Zeile mit dem unsicheren Wort „\(word)“: \(line.text)")
                .accessibilityIdentifier("wordLine")
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    // MARK: Suggestions

    /// The ink was read again the same way (D-047): "Wort ist richtig" comes first.
    private var confirmedSection: some View {
        Section {
            Label("Lesung bestätigt – Wort ist wahrscheinlich richtig", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("readingConfirmedNote")
            Button(action: { finish(with: word) }) {
                Label("Wort ist richtig", systemImage: "checkmark.seal").fontWeight(.semibold)
            }
            .accessibilityIdentifier("confirmWordButton")
        } footer: {
            Text("Die Texterkennung hat das Wort beim erneuten Lesen genauso gelesen.")
        }
    }

    @ViewBuilder
    private var suggestionSection: some View {
        let options = options
        Section {
            if readingConfirmed {
                // Other real words only, no "Wahrscheinlich": the reading speaks for the word as written.
                ForEach(Array(options.enumerated()), id: \.offset) { index, item in
                    Button(item.text) { text = item.text }
                        .accessibilityHint("Trägt das Wort unten ein")
                        .accessibilityIdentifier("wordSuggestion-\(index)")
                }
            } else if let best = options.first {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wahrscheinlich")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(best.text)
                                .font(.title2.weight(.bold))
                            if best.sources.contains(.model) {
                                Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Übernehmen") { finish(with: best.text) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("\(best.text) übernehmen")
                        .accessibilityIdentifier("applyBestButton")
                }
                ForEach(Array(options.dropFirst().enumerated()), id: \.offset) { index, item in
                    Button {
                        text = item.text
                    } label: {
                        HStack {
                            Text(item.text)
                            Spacer(minLength: 0)
                            if item.sources.contains(.model) {
                                Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(item.sources.contains(.model) ? "\(item.text), Vorschlag des Geräte-Modells" : item.text)
                    .accessibilityHint("Trägt das Wort unten ein")
                    .accessibilityIdentifier("wordSuggestion-\(index)")
                }
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Lesarten werden gesucht…").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wordCandidatesLoading")
            } else if options.isEmpty {
                Text(readingConfirmed
                     ? "Keine anderen Lesungen."
                     : "Keine passenden Vorschläge. Ist das Wort richtig, tippe auf „Wort ist richtig“, sonst schreibe es unten selbst.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("noWordSuggestions")
            }
            if modelMissing, ai.settings.developerModeEnabled {
                Text("Ohne Geräte-Modell geordnet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wordModelHint")
            }
        } header: {
            Text(readingConfirmed ? "Andere Lesungen" : "Vorschläge")
        } footer: {
            Text("Die Vorschläge zeigen nur andere Lesarten dieses einen Wortes, die echte Wörter sind. Es wird nichts hinzugefügt.")
        }
    }

    // MARK: Loading

    private func load() async {
        guard let line, let token else { return }
        let digitizationID = source.currentDigitization?.id ?? source.id
        let context = WordCandidateContext.make(source: source, digitizationID: digitizationID, lines: lines, ai: ai)
        async let cropped: Void = showCrop(context: context, line: line, token: token)
        await loadCandidates(context: context, line: line)
        await cropped
    }

    private func showCrop(context: WordCandidateContext?, line: RecognizedLine, token: ReviewToken) async {
        guard let context else { return }
        let band = WordGeometry.bandRect(for: token.rect, line: line, pageLines: lines)
        let image = await WordCrop.image(background: context.background, band: band)
        if !Task.isCancelled { crop = image }
    }

    private func loadCandidates(context: WordCandidateContext?, line: RecognizedLine) async {
        defer { isLoading = false }
        guard let context, let job = context.job(lineID: lineID, wordIndex: wordIndex) else {
            // No original to read from: the local readings only, and only real words (D-047).
            let terms = Set(source.batch?.subject?.confirmedTerms ?? [])
            let local = WordReview.localSuggestions(
                line: line, wordIndex: wordIndex, checker: AppSpellChecker.shared, terms: terms)
                .enumerated().map { WordCandidate(text: $1, score: 1 - Double($0) * 0.1, sources: [.spelling]) }
            candidates = WordCandidateRanking.plausible(
                local, written: word, checker: AppSpellChecker.shared, terms: terms,
                limit: VisionWordCandidateProvider.plausibleCount)
            return
        }
        let cache = WordCandidateCache.shared
        if let cached = cache.result(for: job.key) {
            candidates = cached.candidates
            readingConfirmed = cached.readingConfirmed
            return
        }
        let result = await WordCandidateReader.read(job.request, with: AppWordCandidates.provider)
        guard !Task.isCancelled else { return }
        cache.store(result, for: job.key)
        candidates = result.candidates
        readingConfirmed = result.readingConfirmed
        modelMissing = context.rerankStatus.modelMissing
    }

    // MARK: Finishing

    private func finish(with newText: String) {
        guard let repository else { return }
        let new = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return }
        do {
            try repository.correctWord(source: source, lineID: lineID, wordIndex: wordIndex, newText: new)
            if remember, let subject = source.batch?.subject {
                let term = WordReview.splitPunctuation(new).core
                if !term.isEmpty { try repository.addConfirmedTerm(term, to: subject) }
            }
            // Topics whose entries took over the old text are now affected.
            coordinator.reportImpact(of: [source])
            if let onDone { onDone() } else { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Runs the provider off the main actor (the sheet's task is on it).
nonisolated enum WordCandidateReader {
    @concurrent
    static func read(_ request: WordRereadRequest, with provider: any WordCandidateProviding) async -> WordRereadResult {
        (try? await provider.reread(for: request)) ?? WordRereadResult()
    }
}
