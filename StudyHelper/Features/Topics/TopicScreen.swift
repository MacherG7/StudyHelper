import StudyData
import SwiftUI

/// Finds a topic of `subject` by id; used by navigation destinations that carry only an id.
struct TopicLookupView: View {
    let subject: Subject?
    let topicID: UUID

    var body: some View {
        if let topic = subject?.topic(withID: topicID) {
            TopicScreen(topic: topic)
        } else {
            ContentUnavailableView("Thema nicht gefunden", systemImage: "questionmark.folder", description: Text("Dieses Thema gibt es nicht mehr."))
        }
    }
}

/// One topic: status and confirmation on top, below the editor, the source text and the review view.
/// On a wide screen the editor and the source text sit side by side; on a narrow one they are switched.
struct TopicScreen: View {
    let topic: Topic

    init(topic: Topic) {
        self.topic = topic
        // Review once there is something to review, otherwise start with editing (decided once on opening).
        _pane = State(initialValue: (topic.isConfirmed || !topic.entries.isEmpty) ? .review : .edit)
    }

    enum Pane: String, Identifiable {
        case edit, source, review
        var id: String { rawValue }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.studyRepository) private var repository
    @State private var pane: Pane
    @State private var errorMessage: String?

    private var isWide: Bool { sizeClass == .regular }

    private var currentPane: Pane { (isWide && pane == .source) ? .edit : pane }

    var body: some View {
        let current = currentPane
        VStack(spacing: 0) {
            statusBar
            Picker("Ansicht", selection: Binding(get: { current }, set: { pane = $0 })) {
                Text(isWide ? "Bearbeiten" : "Felder").tag(Pane.edit)
                if !isWide { Text("Quelle").tag(Pane.source) }
                Text("Prüfen").tag(Pane.review)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("topicPanePicker")
            Divider()
            switch current {
            case .edit:
                if isWide {
                    HStack(spacing: 0) {
                        TopicEditorView(topic: topic)
                        Divider()
                        TopicSourcePanel(topic: topic)
                    }
                } else {
                    TopicEditorView(topic: topic)
                }
            case .source:
                TopicSourcePanel(topic: topic)
            case .review:
                TopicReviewView(topic: topic)
            }
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorMessage)
    }

    // MARK: Status and confirmation

    private var statusBar: some View {
        let topicStatus = TopicStatus(topic)
        let needsConfirmation = !topic.isReadyForLearning
        let status = VStack(alignment: .leading, spacing: 4) {
            switch topicStatus {
            case .ready:
                Label("Bestätigt", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("topicConfirmedBadge")
            case .modified:
                Label("Nach Bestätigung geändert", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHint("Erst nach erneuter Bestätigung kann dieses Thema gelernt werden.")
                    .accessibilityIdentifier("topicModifiedHint")
                if !typeSize.isAccessibilitySize {
                    Text("Erst nach erneuter Bestätigung kann dieses Thema gelernt werden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .draft:
                Label("Entwurf", systemImage: "pencil.line")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Erst nach der Bestätigung kann dieses Thema gelernt werden.")
                    .accessibilityIdentifier("topicDraftBadge")
                if !typeSize.isAccessibilitySize {
                    Text("Erst nach der Bestätigung kann dieses Thema gelernt werden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        let button = Button(topic.isConfirmed ? "Erneut bestätigen" : "Thema bestätigen", systemImage: "checkmark.seal") { confirm() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("confirmTopicButton")
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    status
                    if needsConfirmation { button }
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    status
                    Spacer(minLength: 4)
                    if needsConfirmation { button }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirm() {
        if topic.openSupplementCount > 0 {
            errorMessage = "Es sind noch KI-Ergänzungen offen. Nimm sie an oder lehne sie ab, bevor du das Thema bestätigst."
            return
        }
        do { try repository?.confirm(topic) } catch { errorMessage = error.localizedDescription }
    }
}
