import StudyCore
import StudyData
import SwiftUI

/// One page: image and text side by side (regular width) or switchable (compact width),
/// open-points counter, banners, and the actions for the selected line.
struct ReviewPageView: View {
    let source: Source
    let batch: ImportBatch

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ImportCoordinator.self) private var coordinator
    @Environment(\.studyRepository) private var repository
    @Environment(AIService.self) private var ai

    enum Mode: String, CaseIterable, Identifiable {
        case image = "Bild"
        case text = "Text"
        var id: String { rawValue }
    }

    enum PageSheet: Identifiable {
        case correction(UUID)
        case highlights(UUID)
        case word(UUID, Int)
        case wordSequence([WordRef])
        case unmatched
        var id: String {
            switch self {
            case .correction(let id): "c-\(id)"
            case .highlights(let id): "h-\(id)"
            case .word(let id, let index): "w-\(id)-\(index)"
            case .wordSequence: "word-sequence"
            case .unmatched: "unmatched"
            }
        }
    }

    @State private var mode: Mode = .image
    @State private var selectedLineID: UUID?
    @State private var onlyOpen = false
    @State private var sheet: PageSheet?
    @State private var openedTopicID: UUID?
    @State private var pageImage: UIImage?
    @State private var snapshotCache = DerivedValue<PageSnapshot>()
    @State private var report = ReportFlow()
    /// Computes the best reading of the marked words in the background (D-044).
    @State private var prefetcher = WordCandidatePrefetcher()
    @State private var errorMessage: String?

    private struct ImageKey: Hashable {
        var digitizationID: UUID?
        var state: DigitizationState
    }

    /// Restarts the background reading when the page, its marks or the editing state change.
    private struct PrefetchKey: Hashable {
        var digitizationID: UUID?
        var marks: [UUID: [Int]]
        var enabled: Bool
        var terms: Int
    }

    /// The current digitization decoded once per change (the JSON blobs are not read on every render).
    private struct PageSnapshot {
        var digitizationID: UUID?
        var lines: [RecognizedLine] = []
        var highlights: [RecognizedHighlight] = []
        var warnings: [String] = []
        var damageNote: String?
        /// A stored blob cannot be read (flagged damaged, or undecodable right now): no lines, no editing.
        var unreadable = false
        /// Marked words and illegible lines (`WordReview`); `open` counts both.
        var review = PageWordReview()
        var open: Int { review.open }
        /// Highlights that belong to no line; listed in the text view so that VoiceOver can reach them.
        var looseHighlights: [RecognizedHighlight] = []

        init() {}

        init(_ source: Source) {
            guard let digitization = source.currentDigitization else { return }
            digitizationID = digitization.id
            warnings = digitization.warnings
            if digitization.hasUnreadableData {
                unreadable = true
                damageNote = digitization.damageNote
                return
            }
            lines = digitization.lines.sorted { $0.order < $1.order }
            highlights = digitization.highlights
            // Words of the subject's other pages (filled by the summaries in the background, D-047).
            let otherPageWords = SubjectWords.shared.otherPageWords(
                subjectID: source.batch?.subject?.id, excluding: source.id)
            review = PageWordReview.cached(
                digitization: digitization, lines: lines, terms: Set(source.batch?.subject?.confirmedTerms ?? []),
                otherPageWords: otherPageWords)
            looseHighlights = highlights.filter { highlight in !lines.contains { highlight.applies(to: $0) } }
        }
    }

    var body: some View {
        let stored = snapshotCache.value(key: source.id) { PageSnapshot(source) }
        // Marks whose reading the ink confirmed are left out of what is shown and counted (D-047). The background
        // reading keeps following the stored marks (`PrefetchKey`), so a confirmation does not restart it.
        let snapshot = Self.withoutConfirmed(stored)
        let hasDigitization = snapshot.digitizationID != nil
        let damaged = snapshot.unreadable
        let lines = snapshot.lines
        let highlights = snapshot.highlights
        let isActive = coordinator.activeBatchID == batch.id && source.digitizationState == .pending
        let editingDisabled = isEditingDisabled(damaged: damaged)
        let prefetchKey = PrefetchKey(
            digitizationID: snapshot.digitizationID, marks: stored.review.result.marks,
            enabled: !editingDisabled && !damaged && hasDigitization,
            terms: (batch.subject?.confirmedTerms ?? []).hashValue)

        VStack(spacing: 0) {
            banners(snapshot: snapshot, isActive: isActive)
            if hasDigitization, !damaged {
                header(review: snapshot.review, lines: lines, editingDisabled: editingDisabled)
                Divider()
            }
            content(snapshot: snapshot, isActive: isActive, editingDisabled: editingDisabled)
            if hasDigitization, !damaged {
                Divider()
                lineBar(lines: lines, highlights: highlights, review: snapshot.review, editingDisabled: editingDisabled)
            }
        }
        .reportFlow($report, source: source, batch: batch, lines: lines, pageImage: pageImage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ReportToolbarButton { report.startDrawing() }
            }
        }
        .task(id: ImageKey(digitizationID: snapshot.digitizationID, state: source.digitizationState)) {
            if let data = source.imageData {
                pageImage = await UIImage(data: data)?.byPreparingForDisplay()
            } else {
                pageImage = nil
            }
        }
        .task(id: prefetchKey) { await startPrefetch(prefetchKey) }
        .onDisappear { prefetcher.cancel() }
        .errorAlert($errorMessage)
        .navigationDestination(item: $openedTopicID) { id in
            TopicLookupView(subject: batch.subject, topicID: id)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .correction(let id):
                CorrectionSheet(source: source, lineID: id)
            case .highlights(let id):
                HighlightsSheet(source: source, lineID: id)
            case .word(let id, let index):
                WordCorrectionSheet(source: source, lineID: id, wordIndex: index)
            case .wordSequence(let queue):
                WordCheckSequence(source: source, queue: queue)
            case .unmatched:
                UnmatchedCorrectionsView(source: source)
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private func banners(snapshot: PageSnapshot, isActive: Bool) -> some View {
        let unmatched = source.unmatchedCorrectionCount
        let warnings = snapshot.warnings
        let damaged = snapshot.unreadable
        let hasDigitization = snapshot.digitizationID != nil
        let affectedTopics = coordinator.affectedSubjectID == batch.subject?.id ? coordinator.affectedTopics : []
        if damaged || unmatched > 0 || !warnings.isEmpty || !affectedTopics.isEmpty
            || source.digitizationState == .failed
            || (source.digitizationState == .pending && !isActive) {
            VStack(spacing: 6) {
                if damaged {
                    InfoBanner(
                        "Diese Version ist beschädigt und kann nicht gelesen werden. Bearbeiten ist deaktiviert, es wurde nichts verändert. \(snapshot.damageNote ?? "") Stelle unter „Versionen“ einen älteren Stand wieder her oder erkenne die Seite neu.",
                        style: .error)
                        .accessibilityIdentifier("damagedBanner")
                }
                if source.digitizationState == .failed {
                    InfoBanner(source.digitizationError ?? "Die Erkennung dieser Seite ist fehlgeschlagen.", style: .error) {
                        Button("Erneut versuchen") { coordinator.reRecognize([source], in: batch) }
                            .font(.footnote.weight(.semibold))
                            .disabled(coordinator.isRunning)
                    }
                }
                if source.digitizationState == .pending, !isActive {
                    InfoBanner(
                        !hasDigitization
                            ? "Diese Seite wartet auf die Erkennung."
                            : "Die neue Erkennung wurde nicht abgeschlossen. Du siehst noch den bisherigen Stand.",
                        style: .warning
                    ) {
                        Button("Jetzt erkennen") { coordinator.reRecognize([source], in: batch) }
                            .font(.footnote.weight(.semibold))
                            .disabled(coordinator.isRunning)
                            .accessibilityIdentifier("recognizeThisPageButton")
                    }
                }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    InfoBanner(warning, style: .warning)
                }
                if unmatched > 0 {
                    InfoBanner(
                        unmatched == 1
                            ? "Eine deiner Korrekturen passt zur neuen Erkennung nicht mehr zu einer Stelle."
                            : "\(unmatched) deiner Korrekturen passen zur neuen Erkennung nicht mehr zu einer Stelle.",
                        style: .warning
                    ) {
                        Button("Anzeigen und verwerfen") { sheet = .unmatched }
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("showUnmatchedButton")
                    }
                }
                if !affectedTopics.isEmpty {
                    AffectedTopicsBanner(topics: affectedTopics) { openedTopicID = $0 } onDismiss: { coordinator.dismissImpact() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: Header

    private func header(review: PageWordReview, lines: [RecognizedLine], editingDisabled: Bool) -> some View {
        let open = review.open
        let status = Group {
            if open == 0 {
                Label("Alles geprüft", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(
                    PageWordReview.headline(words: review.openWords, illegible: review.illegible),
                    systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Offene Stellen")
        .accessibilityValue("\(open)")
        .accessibilityIdentifier("reviewOpenCount")
        let toggle = Toggle(isOn: $onlyOpen) {
            Text("Nur offene Stellen").font(.subheadline)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .accessibilityIdentifier("onlyOpenToggle")
        // The open words one after the other, like a quiz.
        let sequence = Button {
            sheet = .wordSequence(WordRef.queue(lines: lines, review: review))
        } label: {
            Label("Nacheinander prüfen", systemImage: "list.number").font(.subheadline)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("startWordCheckButton")
        let showsSequence = review.openWords > 0 && !editingDisabled
        // Side by side if it fits, stacked at large text sizes (nothing is cut off).
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                status
                Spacer(minLength: 4)
                if showsSequence { sequence }
                toggle
            }
            VStack(alignment: .leading, spacing: 8) {
                status
                if showsSequence { sequence }
                toggle
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private func content(snapshot: PageSnapshot, isActive: Bool, editingDisabled: Bool) -> some View {
        let lines = snapshot.lines
        let highlights = snapshot.highlights
        if snapshot.unreadable {
            imagePane(lines: [], highlights: [])
        } else if snapshot.digitizationID == nil {
            VStack(spacing: 12) {
                if isActive {
                    ProgressView()
                    Text("Diese Seite wird erkannt…").foregroundStyle(.secondary)
                }
                if pageImage != nil { imagePane(lines: [], highlights: []) }
                else { Spacer() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sizeClass == .regular {
            HStack(spacing: 0) {
                imagePane(lines: lines, highlights: highlights, review: snapshot.review, wordsEnabled: !editingDisabled)
                Divider()
                textPane(snapshot: snapshot, wordsEnabled: !editingDisabled)
            }
        } else {
            VStack(spacing: 0) {
                Picker("Ansicht", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("modePicker")
                switch mode {
                case .image: imagePane(lines: lines, highlights: highlights, review: snapshot.review, wordsEnabled: !editingDisabled)
                case .text: textPane(snapshot: snapshot, wordsEnabled: !editingDisabled)
                }
            }
        }
    }

    @ViewBuilder
    private func imagePane(
        lines: [RecognizedLine], highlights: [RecognizedHighlight], review: PageWordReview = PageWordReview(),
        wordsEnabled: Bool = true
    ) -> some View {
        if let pageImage {
            LayeredPageImageView(
                source: source, image: pageImage, lines: lines, highlights: highlights,
                selectedLineID: $selectedLineID, onlyOpen: onlyOpen, review: review, wordsEnabled: wordsEnabled, onWordTap: openWord)
        } else {
            ContentUnavailableView("Kein Bild", systemImage: "photo", description: Text("Das Bild dieser Seite ist nicht gespeichert."))
        }
    }

    private func textPane(snapshot: PageSnapshot, wordsEnabled: Bool) -> some View {
        LineListView(
            lines: snapshot.lines, highlights: snapshot.highlights, looseHighlights: snapshot.looseHighlights,
            review: snapshot.review, wordsEnabled: wordsEnabled, selectedLineID: $selectedLineID, onlyOpen: onlyOpen,
            onWordTap: openWord, guesses: guesses(in: snapshot, enabled: wordsEnabled), onQuickFix: quickFix)
    }

    // MARK: Selected line

    /// Opens the word correction for a marked word with one tap; the line stays as it is.
    private func openWord(lineID: UUID, wordIndex: Int) {
        guard !isEditingDisabled(damaged: source.currentDigitization?.hasUnreadableData ?? false) else { return }
        sheet = .word(lineID, wordIndex)
    }

    // MARK: Best reading

    /// The snapshot without the marks whose reading is confirmed (`WordCandidateCache.isConfirmed`; views re-render
    /// when a confirmation arrives).
    private static func withoutConfirmed(_ snapshot: PageSnapshot) -> PageSnapshot {
        guard let digitizationID = snapshot.digitizationID, !snapshot.review.result.confirmable.isEmpty else {
            return snapshot
        }
        var copy = snapshot
        copy.review = snapshot.review.excludingConfirmed(digitizationID: digitizationID) {
            WordCandidateCache.shared.isConfirmed($0)
        }
        return copy
    }

    /// The best reading found so far for each marked word of the page ("→ word?" next to it).
    private func guesses(in snapshot: PageSnapshot, enabled: Bool) -> [WordReference: String] {
        guard enabled, let digitizationID = snapshot.digitizationID else { return [:] }
        let cache = WordCandidateCache.shared
        var result: [WordReference: String] = [:]
        for line in snapshot.lines {
            for token in snapshot.review.markedTokens(of: line.id) {
                let key = WordKey(digitizationID: digitizationID, lineID: line.id, wordIndex: token.index, text: token.text)
                if let guess = cache.bestGuess(for: key) {
                    result[WordReference(lineID: line.id, wordIndex: token.index)] = guess
                }
            }
        }
        return result
    }

    /// Computes the readings of the page's marked words in the background; nothing runs while editing is disabled.
    private func startPrefetch(_ key: PrefetchKey) async {
        prefetcher.cancel()
        guard key.enabled, let digitizationID = key.digitizationID else { return }
        // Let the page appear and settle first.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let snapshot = snapshotCache.value(key: source.id) { PageSnapshot(source) }
        guard snapshot.digitizationID == digitizationID, !snapshot.unreadable,
              let context = WordCandidateContext.make(
                source: source, digitizationID: digitizationID, lines: snapshot.lines, ai: ai)
        else { return }
        prefetcher.start(context.jobs(for: snapshot.review))
    }

    /// Applies the best reading of a word without opening it.
    private func quickFix(lineID: UUID, wordIndex: Int, text: String) {
        guard let repository,
              !isEditingDisabled(damaged: source.currentDigitization?.hasUnreadableData ?? false) else { return }
        do {
            try repository.correctWord(source: source, lineID: lineID, wordIndex: wordIndex, newText: text)
            coordinator.reportImpact(of: [source])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Editing is blocked while the page is damaged or its import is being recognized or re-recognized.
    private func isEditingDisabled(damaged: Bool) -> Bool {
        Self.editingDisabled(damaged: damaged, activeBatchID: coordinator.activeBatchID, batchID: batch.id)
    }

    /// The rule behind `isEditingDisabled` (testable without a view).
    static func editingDisabled(damaged: Bool, activeBatchID: UUID?, batchID: UUID) -> Bool {
        damaged || activeBatchID == batchID
    }

    @ViewBuilder
    private func lineBar(
        lines: [RecognizedLine], highlights: [RecognizedHighlight], review: PageWordReview, editingDisabled: Bool
    ) -> some View {
        if let line = lines.first(where: { $0.id == selectedLineID }) {
            let own = highlights.filter { $0.applies(to: line) }
            let marked = review.markedTokens(of: line.id)
            let status = line.displayStatus(hasMarks: !marked.isEmpty, isIllegible: review.isIllegible(line.id))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let symbol = status.symbolName {
                        Image(systemName: symbol).foregroundStyle(status.tint).accessibilityHidden(true)
                    }
                    Text(line.text.isEmpty ? "(leer)" : line.text)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Text kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
                        .labelStyle(.iconOnly)
                        .disabled(line.text.isEmpty)
                        .accessibilityIdentifier("copyLineButton")
                    Button("Auswahl aufheben", systemImage: "xmark.circle.fill") { selectedLineID = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                if !marked.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Unsichere Wörter:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        FlowLayout(spacing: 6) {
                            ForEach(marked, id: \.index) { token in
                                Button(token.core.isEmpty ? token.text : token.core) { openWord(lineID: line.id, wordIndex: token.index) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.orange)
                                    .disabled(editingDisabled)
                                    .accessibilityLabel("Unsicheres Wort: \(token.core.isEmpty ? token.text : token.core)")
                                    .accessibilityIdentifier("wordChip-\(token.index)")
                            }
                        }
                    }
                }
                let buttons = Group {
                    Button("Korrigieren", systemImage: "pencil") { sheet = .correction(line.id) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("correctLineButton")
                    Button(own.isEmpty ? "Hervorhebungen" : "Hervorhebungen (\(own.count))", systemImage: "highlighter") {
                        sheet = .highlights(line.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("highlightsButton")
                }
                .disabled(editingDisabled)
                // Wraps to a second row when the buttons do not fit (narrow screens, large text, developer button).
                FlowLayout(spacing: 8) {
                    buttons
                    ReportLineButton { report.reportLine(line.id) }
                }
            }
            .padding(12)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("selectedLineBar")
        } else {
            Text("Tippe auf eine Zeile, um sie zu korrigieren oder ihre Hervorhebungen zu ändern.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.bar)
        }
    }
}
