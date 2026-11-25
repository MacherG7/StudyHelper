import StudyCore
import StudyData
import SwiftUI

/// One page: image and text side by side (regular width) or switchable (compact width),
/// open-points counter, banners, and the actions for the selected line.
struct ReviewPageView: View {
    let source: Source
    let batch: ImportBatch

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ImportCoordinator.self) private var coordinator

    enum Mode: String, CaseIterable, Identifiable {
        case image = "Bild"
        case text = "Text"
        var id: String { rawValue }
    }

    enum PageSheet: Identifiable {
        case correction(UUID)
        case highlights(UUID)
        case unmatched
        var id: String {
            switch self {
            case .correction(let id): "c-\(id)"
            case .highlights(let id): "h-\(id)"
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

    private struct ImageKey: Hashable {
        var digitizationID: UUID?
        var state: DigitizationState
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
        var open = 0
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
            open = lines.filter(\.needsReview).count
            looseHighlights = highlights.filter { highlight in !lines.contains { highlight.applies(to: $0) } }
        }
    }

    var body: some View {
        let snapshot = snapshotCache.value(key: source.id) { PageSnapshot(source) }
        let hasDigitization = snapshot.digitizationID != nil
        let damaged = snapshot.unreadable
        let lines = snapshot.lines
        let highlights = snapshot.highlights
        let isActive = coordinator.activeBatchID == batch.id && source.digitizationState == .pending
        let editingDisabled = damaged || coordinator.activeBatchID == batch.id

        VStack(spacing: 0) {
            banners(snapshot: snapshot, isActive: isActive)
            if hasDigitization, !damaged {
                header(open: snapshot.open)
                Divider()
            }
            content(snapshot: snapshot, isActive: isActive)
            if hasDigitization, !damaged {
                Divider()
                lineBar(lines: lines, highlights: highlights, editingDisabled: editingDisabled)
            }
        }
        .task(id: ImageKey(digitizationID: snapshot.digitizationID, state: source.digitizationState)) {
            if let data = source.imageData {
                pageImage = await UIImage(data: data)?.byPreparingForDisplay()
            } else {
                pageImage = nil
            }
        }
        .navigationDestination(item: $openedTopicID) { id in
            TopicLookupView(subject: batch.subject, topicID: id)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .correction(let id):
                CorrectionSheet(source: source, lineID: id)
            case .highlights(let id):
                HighlightsSheet(source: source, lineID: id)
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

    private func header(open: Int) -> some View {
        let status = Group {
            if open == 0 {
                Label("Alles geprüft", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(open == 1 ? "Noch 1 Stelle offen" : "Noch \(open) Stellen offen", systemImage: "exclamationmark.triangle.fill")
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
        // Side by side if it fits, stacked at large text sizes (nothing is cut off).
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                status
                Spacer(minLength: 4)
                toggle
            }
            VStack(alignment: .leading, spacing: 8) {
                status
                toggle
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private func content(snapshot: PageSnapshot, isActive: Bool) -> some View {
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
                imagePane(lines: lines, highlights: highlights)
                Divider()
                textPane(snapshot: snapshot)
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
                case .image: imagePane(lines: lines, highlights: highlights)
                case .text: textPane(snapshot: snapshot)
                }
            }
        }
    }

    @ViewBuilder
    private func imagePane(lines: [RecognizedLine], highlights: [RecognizedHighlight]) -> some View {
        if let pageImage {
            LayeredPageImageView(
                source: source, image: pageImage, lines: lines, highlights: highlights,
                selectedLineID: $selectedLineID, onlyOpen: onlyOpen)
        } else {
            ContentUnavailableView("Kein Bild", systemImage: "photo", description: Text("Das Bild dieser Seite ist nicht gespeichert."))
        }
    }

    private func textPane(snapshot: PageSnapshot) -> some View {
        LineListView(
            lines: snapshot.lines, highlights: snapshot.highlights, looseHighlights: snapshot.looseHighlights,
            selectedLineID: $selectedLineID, onlyOpen: onlyOpen)
    }

    // MARK: Selected line

    @ViewBuilder
    private func lineBar(lines: [RecognizedLine], highlights: [RecognizedHighlight], editingDisabled: Bool) -> some View {
        if let line = lines.first(where: { $0.id == selectedLineID }) {
            let own = highlights.filter { $0.applies(to: line) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let symbol = line.displayStatus.symbolName {
                        Image(systemName: symbol).foregroundStyle(line.displayStatus.tint).accessibilityHidden(true)
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
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading) { buttons }
                } else {
                    HStack { buttons }
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
