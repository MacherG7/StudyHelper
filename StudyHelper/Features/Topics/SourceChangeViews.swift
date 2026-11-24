import StudyData
import SwiftUI

/// "Quelle geändert" for one entry, with the two ways to resolve it: take the current text over, or ignore the change.
struct SourceChangeActions: View {
    let entry: TopicEntry
    let subject: Subject?
    let report: SourceChangeReport
    /// Called after one of the actions succeeded.
    var onResolved: () -> Void = {}

    @Environment(\.studyRepository) private var repository
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Quelle geändert", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("\(report.detail) Dieser Eintrag zeigt noch den Stand vom Übernehmen. Übernimm den aktuellen Text aus der Quelle oder ignoriere die Änderung.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8) {
                Button("Text aus Quelle übernehmen", systemImage: "arrow.down.doc") { resolve(adopt: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!report.canAdopt)
                    .accessibilityIdentifier("adoptSourceButton")
                Button("Ignorieren", systemImage: "eye.slash") { resolve(adopt: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("ignoreSourceChangeButton")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sourceChangeActions")
        .errorAlert($errorMessage)
    }

    private func resolve(adopt: Bool) {
        guard let repository else { return }
        do {
            if adopt {
                try SourceChangeResolver.adopt(entry, subject: subject, repository: repository)
            } else {
                try SourceChangeResolver.acknowledge(entry, subject: subject, repository: repository)
            }
            onResolved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Topics whose entries refer to a changed source, as buttons that open the topic.
/// Used after a correction, a highlight edit, a version restore and a re-recognition.
struct AffectedTopicsBanner: View {
    let topics: [AffectedTopic]
    let onOpen: (UUID) -> Void
    let onDismiss: () -> Void

    var body: some View {
        InfoBanner("Betroffene Themen – ihre Quelle hat sich geändert. Prüfe, ob der Inhalt dort noch stimmt:", style: .info) {
            FlowLayout(spacing: 8) {
                ForEach(topics) { topic in
                    Button(topic.title) { onOpen(topic.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Öffnet das Thema")
                        .accessibilityIdentifier("affectedTopic-\(topic.title)")
                }
            }
            Button("OK", action: onDismiss)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("dismissAffectedTopicsButton")
        }
        .accessibilityIdentifier("affectedTopicsHint")
    }
}
