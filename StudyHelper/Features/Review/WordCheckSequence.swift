import StudyCore
import StudyData
import SwiftUI

/// One marked word of a page in the sequence "Wörter nacheinander prüfen".
struct WordRef: Hashable, Identifiable {
    let lineID: UUID
    let wordIndex: Int
    /// The word as it stood when the sequence started; a changed word is skipped.
    let text: String

    var id: String { "\(lineID)-\(wordIndex)" }

    /// The open words of a page in reading order.
    static func queue(lines: [RecognizedLine], review: PageWordReview) -> [WordRef] {
        lines.sorted { $0.order < $1.order }.flatMap { line in
            review.markedTokens(of: line.id).map { WordRef(lineID: line.id, wordIndex: $0.index, text: $0.text) }
        }
    }
}

/// Checks the open words of a page one after the other, like a quiz: pick the right reading for the first word, then
/// for the second, and so on. Every step is the word sheet (`WordCorrectionSheet`), which moves on instead of
/// closing; "Überspringen" leaves a word open, "Beenden" stops.
struct WordCheckSequence: View {
    let source: Source
    let queue: [WordRef]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    /// The first word from `index` on that is still there as it was; later words may have changed in the meantime.
    private var currentIndex: Int? {
        let lines = source.currentDigitization?.lines ?? []
        return (index..<queue.count).first { position in
            let ref = queue[position]
            guard let line = lines.first(where: { $0.id == ref.lineID }) else { return false }
            return WordReview.tokens(of: line).first { $0.index == ref.wordIndex }?.text == ref.text
        }
    }

    var body: some View {
        if let position = currentIndex {
            let ref = queue[position]
            WordCorrectionSheet(
                source: source, lineID: ref.lineID, wordIndex: ref.wordIndex,
                progress: .init(position: position + 1, total: queue.count),
                onDone: { index = position + 1 }, onSkip: { index = position + 1 })
                .id(ref.id)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
