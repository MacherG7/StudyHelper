import StudyCore
import SwiftUI

/// The recognized text, one row per line, with status icons and visible highlights.
struct LineListView: View {
    let lines: [RecognizedLine]
    let highlights: [RecognizedHighlight]
    /// Highlights that belong to no line (listed after the lines so that VoiceOver users can reach them).
    var looseHighlights: [RecognizedHighlight] = []
    @Binding var selectedLineID: UUID?
    let onlyOpen: Bool

    var body: some View {
        let visible = lines.filter { !onlyOpen || $0.needsReview || $0.id == selectedLineID }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if visible.isEmpty {
                        ContentUnavailableView(
                            onlyOpen ? "Keine offenen Stellen" : "Kein Text erkannt",
                            systemImage: onlyOpen ? "checkmark.circle" : "text.page.slash",
                            description: Text(onlyOpen ? "Alle Stellen dieser Seite sind geprüft." : "Auf dieser Seite wurde kein Text gefunden.")
                        )
                        .padding(.top, 24)
                    }
                    ForEach(visible) { line in
                        LineRow(
                            line: line, highlights: highlights, isSelected: line.id == selectedLineID
                        ) {
                            selectedLineID = (selectedLineID == line.id) ? nil : line.id
                        }
                        .id(line.id)
                    }
                    if !looseHighlights.isEmpty {
                        LooseHighlights(highlights: looseHighlights)
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedLineID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityIdentifier("lineList")
    }
}

private struct LineRow: View {
    let line: RecognizedLine
    let highlights: [RecognizedHighlight]
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let status = line.displayStatus
        let own = highlights.filter { $0.applies(to: line) }
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let symbol = status.symbolName {
                        Image(systemName: symbol).foregroundStyle(status.tint)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(LineText.attributed(line: line, highlights: highlights))
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(own) { highlight in
                        Label(highlight.visibleDescription, systemImage: highlight.kind.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spokenLabel(highlights: highlights))
        .accessibilityValue(isSelected ? "ausgewählt" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Wählt die Zeile aus, um sie zu korrigieren")
        .accessibilityIdentifier("reviewLine-\(line.order)")
    }
}

/// Highlights without a line: shown as a list with a spoken description each.
private struct LooseHighlights: View {
    let highlights: [RecognizedHighlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weitere Hervorhebungen")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Diese Hervorhebungen gehören zu keiner erkannten Zeile.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(highlights) { highlight in
                Label(
                    highlight.text.isEmpty ? highlight.visibleDescription : "„\(highlight.text)“ · \(highlight.visibleDescription)",
                    systemImage: highlight.kind.symbolName)
                    .font(.callout)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Hervorhebung ohne Zeile: \(highlight.spokenDescription)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .accessibilityIdentifier("looseHighlights")
    }
}
