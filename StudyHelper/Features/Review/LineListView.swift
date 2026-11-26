import StudyCore
import SwiftUI

/// The recognized text, one row per line, with status icons and visible highlights.
struct LineListView: View {
    let lines: [RecognizedLine]
    let highlights: [RecognizedHighlight]
    /// Highlights that belong to no line (listed after the lines so that VoiceOver users can reach them).
    var looseHighlights: [RecognizedHighlight] = []
    /// The marked words and illegible lines of the page.
    var review = PageWordReview()
    /// False while the page is locked (damaged, being recognized): the word buttons cannot be tapped.
    var wordsEnabled = true
    @Binding var selectedLineID: UUID?
    let onlyOpen: Bool
    /// A marked word was tapped (line id, word index).
    var onWordTap: (UUID, Int) -> Void = { _, _ in }

    var body: some View {
        let visible = lines.filter { !onlyOpen || review.isOpen($0.id) || $0.id == selectedLineID }
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
                            line: line, highlights: highlights, marked: review.markedTokens(of: line.id),
                            isIllegible: review.isIllegible(line.id), isSelected: line.id == selectedLineID, wordsEnabled: wordsEnabled,
                            onWordTap: { onWordTap(line.id, $0) }
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
    let marked: [ReviewToken]
    let isIllegible: Bool
    let isSelected: Bool
    let wordsEnabled: Bool
    let onWordTap: (Int) -> Void
    let onTap: () -> Void

    var body: some View {
        let status = line.displayStatus(hasMarks: !marked.isEmpty, isIllegible: isIllegible)
        let own = highlights.filter { $0.applies(to: line) }
        VStack(alignment: .leading, spacing: 6) {
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
                        Text(LineText.attributed(line: line, highlights: highlights, marked: marked))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.spokenLabel(
                highlights: highlights, markedWords: marked.map(\.core), isIllegible: isIllegible))
            .accessibilityValue(isSelected ? "ausgewählt" : "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Wählt die Zeile aus, um sie zu korrigieren")
            .accessibilityIdentifier("reviewLine-\(line.order)")

            if !marked.isEmpty {
                // The marked words as buttons of their own: a tap opens the word correction.
                FlowLayout(spacing: 6) {
                    ForEach(marked, id: \.index) { token in
                        Button { onWordTap(token.index) } label: {
                            Text(token.core.isEmpty ? token.text : token.core)
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.8), lineWidth: 1))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!wordsEnabled)
                        .opacity(wordsEnabled ? 1 : 0.45)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Unsicheres Wort: \(token.core.isEmpty ? token.text : token.core)")
                        .accessibilityHint(wordsEnabled ? "Öffnet die Wortkorrektur" : "Gerade nicht bearbeitbar")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("reviewWord-\(line.order)-\(token.index)")
                    }
                }
                .padding(.leading, 32)
            }
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
