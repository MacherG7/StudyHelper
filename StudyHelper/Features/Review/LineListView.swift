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
    /// The best reading found for marked words (shown as "→ word?" next to them) and its use (line id, word index, text).
    var guesses: [WordReference: String] = [:]
    var onQuickFix: (UUID, Int, String) -> Void = { _, _, _ in }

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
                            guesses: guesses,
                            onWordTap: { onWordTap(line.id, $0) },
                            onQuickFix: { onQuickFix(line.id, $0, $1) }
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
    let guesses: [WordReference: String]
    let onWordTap: (Int) -> Void
    let onQuickFix: (Int, String) -> Void
    let onTap: () -> Void

    var body: some View {
        let status = line.displayStatus(hasMarks: !marked.isEmpty, isIllegible: isIllegible)
        let own = highlights.filter { $0.applies(to: line) }
        HStack(alignment: .top, spacing: 10) {
            // The line as one element for VoiceOver (its label reads the whole line); tapping anywhere else on the row
            // selects it, too. The marked words are buttons of their own.
            Button(action: onTap) {
                Group {
                    if let symbol = status.symbolName {
                        Image(systemName: symbol).foregroundStyle(status.tint)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line.spokenLabel(
                highlights: highlights, markedWords: marked.map(\.core), isIllegible: isIllegible))
            .accessibilityValue(isSelected ? "ausgewählt" : "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Wählt die Zeile aus, um sie zu korrigieren")
            .accessibilityIdentifier("reviewLine-\(line.order)")

            VStack(alignment: .leading, spacing: 4) {
                if marked.isEmpty {
                    Text(LineText.attributed(line: line, highlights: highlights, marked: marked))
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                } else {
                    // The marked words are the tap targets: one tap opens the word.
                    FlowLayout(spacing: 4) {
                        ForEach(LineText.pieces(line: line, highlights: highlights, marked: marked)) { piece in
                            if let token = piece.token {
                                WordButton(
                                    order: line.order, token: token, text: piece.text, enabled: wordsEnabled,
                                    guess: wordsEnabled ? guesses[WordReference(lineID: line.id, wordIndex: token.index)] : nil,
                                    onTap: { onWordTap(token.index) }, onQuickFix: { onQuickFix(token.index, $0) })
                            } else {
                                Text(piece.text).font(.body).accessibilityHidden(true)
                            }
                        }
                    }
                }
                ForEach(own) { highlight in
                    Label(highlight.visibleDescription, systemImage: highlight.kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

/// A marked word inside its line: a tap opens the word correction; the best reading found so far follows as a small
/// "→ word?" button that applies it at once.
private struct WordButton: View {
    let order: Int
    let token: ReviewToken
    let text: AttributedString
    let enabled: Bool
    let guess: String?
    let onTap: () -> Void
    let onQuickFix: (String) -> Void

    var body: some View {
        let name = token.core.isEmpty ? token.text : token.core
        HStack(spacing: 3) {
            Button(action: onTap) {
                Text(text)
                    .font(.body)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange.opacity(0.7), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Unsicheres Wort: \(name)")
            .accessibilityHint(enabled ? "Öffnet die Wortkorrektur" : "Gerade nicht bearbeitbar")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("reviewWord-\(order)-\(token.index)")

            if let guess {
                Button { onQuickFix(guess) } label: {
                    Text("→ \(guess)?")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vorschlag übernehmen: \(guess)")
                .accessibilityHint("Ersetzt \(name) durch \(guess)")
                .accessibilityIdentifier("quickFix-\(order)-\(token.index)")
            }
        }
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
