import Foundation
import StudyCore
import StudyData
import SwiftUI

// Pure logic of the topic screens (no views, no repository): building entries from selected
// text, suggestions from highlights, table editing, ordering and resolving source references.
// Kept separate so that it can be unit tested.

// MARK: - Taking text over from the stored page text

/// What the user takes over from the stored text of a page: whole lines, or single words of one line.
struct EntryDraft: Equatable {
    var kind: EntryKind
    var text = ""
    var term = ""
    var definition = ""
    var reference: SourceReference
    var highlight: EntryHighlight?
}

struct SourceSelection {
    var sourceID: UUID
    var digitizationID: UUID?
    var digitizationVersion: Int?
    /// The selected lines in any order.
    var lines: [RecognizedLine]
    /// Selected word indices per line; a line that is not listed (or has an empty set) is taken as a whole.
    var words: [UUID: Set<Int>] = [:]
    /// All highlights of the page.
    var highlights: [RecognizedHighlight]

    var orderedLines: [RecognizedLine] { lines.sorted { $0.order < $1.order } }

    private func selectedWordIndices(of line: RecognizedLine) -> [Int]? {
        guard line.hasReliableWords, let chosen = words[line.id], !chosen.isEmpty else { return nil }
        let valid = chosen.filter { line.words.indices.contains($0) }.sorted()
        return valid.isEmpty ? nil : valid
    }

    /// The taken text: lines (or their chosen words) joined by a space.
    var text: String {
        orderedLines.map { line -> String in
            if let indices = selectedWordIndices(of: line) {
                return indices.map { line.words[$0].text }.joined(separator: " ")
            }
            return line.text
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// Union of the rects of the selected lines (or of the chosen words), page fractions.
    var rect: NormalizedRect? {
        var result: NormalizedRect?
        for line in orderedLines {
            var part = line.rect
            if let indices = selectedWordIndices(of: line) {
                part = indices.map { line.words[$0].rect }.reduce(NormalizedRect.zero) { $0.union($1) }
                if part.isEmpty { part = line.rect }
            }
            result = result.map { $0.union(part) } ?? part
        }
        return result
    }

    /// The reference with a snapshot of the whole referenced lines (for "Quelle geändert").
    var reference: SourceReference {
        SourceReference(
            sourceID: sourceID, lineIDs: orderedLines.map(\.id), rect: rect,
            digitizationID: digitizationID, digitizationVersion: digitizationVersion
        )
        .withSnapshot(SourceFingerprint.make(lines: orderedLines, highlights: highlights))
    }

    /// An emphasis belongs to the taken text only if it covers at least this share of the taken words.
    static let minimumHighlightShare = 0.5

    /// The emphasis of the taken text in the original: the highlight that covers the most words of it, provided it
    /// covers at least half of them (a marked word in the middle of several taken lines is not the emphasis of all).
    var entryHighlight: EntryHighlight? {
        let total = takenWordCount
        guard total > 0 else { return nil }
        var best: (highlight: RecognizedHighlight, score: Int)?
        for highlight in highlights {
            let score = overlap(of: highlight)
            if score > 0, score > (best?.score ?? 0) { best = (highlight, score) }
        }
        guard let best, Double(best.score) / Double(total) >= Self.minimumHighlightShare else { return nil }
        return EntryHighlight(kind: best.highlight.kind, color: best.highlight.color)
    }

    /// Number of words in the taken text.
    private var takenWordCount: Int {
        lines.reduce(0) { $0 + takenWordCount(of: $1) }
    }

    private func takenWordCount(of line: RecognizedLine) -> Int {
        if let indices = selectedWordIndices(of: line) { return indices.count }
        return line.text.split(whereSeparator: \.isWhitespace).count
    }

    /// Number of taken words that the highlight covers; 0 = the highlight does not belong to the taken text.
    private func overlap(of highlight: RecognizedHighlight) -> Int {
        var score = 0
        for line in lines where highlight.applies(to: line) {
            if let indices = selectedWordIndices(of: line) {
                let chosen = Set(indices)
                // A highlight without word references cannot be narrowed down to words: it counts only if the
                // whole line is taken.
                score += highlight.words.filter { $0.lineID == line.id && chosen.contains($0.wordIndex) }.count
            } else if highlight.words.isEmpty {
                // Known only by its area: it covers the whole line.
                score += takenWordCount(of: line)
            } else {
                let covered = Set(highlight.words.filter { $0.lineID == line.id }.map(\.wordIndex)).count
                score += min(max(covered, 1), takenWordCount(of: line))
            }
        }
        return score
    }

    /// nil if nothing (or only blanks) is selected.
    func draft(kind: EntryKind) -> EntryDraft? {
        let taken = text
        guard !taken.isEmpty else { return nil }
        var draft = EntryDraft(kind: kind, reference: reference, highlight: entryHighlight)
        if kind == .term {
            let parts = TermSplitter.split(lines: orderedLines.map(\.text), text: taken)
            draft.term = parts.term
            draft.definition = parts.definition
        } else {
            draft.text = taken
        }
        return draft
    }
}

extension RecognizedLine {
    /// The stored word boxes still describe the line text (false after a correction of the text).
    var hasReliableWords: Bool {
        !words.isEmpty && words.map(\.text).joined(separator: " ") == text
    }
}

/// Splits a taken text into term and definition ("Ort: Chloroplasten", "Chlorophyll ist der grüne Blattfarbstoff").
enum TermSplitter {
    private static let separators = [":", " – ", " — ", " - ", " ist ", " sind ", " = "]

    static func split(lines: [String], text: String) -> (term: String, definition: String) {
        let joined = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in separators {
            guard let range = joined.range(of: separator) else { continue }
            let term = clean(String(joined[..<range.lowerBound]))
            let definition = clean(String(joined[range.upperBound...]))
            if !term.isEmpty { return (term, definition) }
        }
        let nonEmpty = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if nonEmpty.count > 1 {
            return (nonEmpty[0], nonEmpty.dropFirst().joined(separator: " "))
        }
        return (joined, "")
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":–—-=")))
    }
}

// MARK: - Suggestions from highlights

struct HighlightSuggestion: Identifiable, Equatable {
    enum Role: Equatable {
        /// A heading: can become the title or a key statement.
        case heading
        /// A highlighted term: becomes a term with the rest of its line as the definition hint.
        case term
        /// A rule or formula.
        case rule
        /// Anything else that was emphasized: a key statement.
        case statement

        var entryKind: EntryKind {
            switch self {
            case .heading, .statement: .keyStatement
            case .term: .term
            case .rule: .rule
            }
        }
    }

    var id: UUID
    var text: String
    var role: Role
    var definitionHint: String
    var reference: SourceReference
    var highlight: EntryHighlight

    /// The entry to create when the user takes the suggestion over as `kind` (default: its own kind).
    func draft(as kind: EntryKind? = nil) -> EntryDraft {
        let kind = kind ?? role.entryKind
        var draft = EntryDraft(kind: kind, reference: reference, highlight: highlight)
        if kind == .term {
            draft.term = text
            draft.definition = definitionHint
        } else {
            draft.text = text
        }
        return draft
    }
}

enum HighlightSuggestions {
    /// Suggestions of one page. Highlights whose text is already an entry of the topic (`existing`,
    /// see `normalized`) are left out.
    static func make(
        lines: [RecognizedLine], highlights: [RecognizedHighlight], sourceID: UUID,
        digitizationID: UUID?, digitizationVersion: Int?, existing: Set<String> = []
    ) -> [HighlightSuggestion] {
        let linesByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = existing
        var result: [(order: Int, y: Double, suggestion: HighlightSuggestion)] = []
        for highlight in highlights {
            let text = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(normalized(text)).inserted else { continue }
            let lineIDs = highlightLineIDs(highlight, lines: lines)
            let owners = lineIDs.compactMap { linesByID[$0] }
            let role = role(for: highlight, text: text)
            let reference = SourceReference(
                sourceID: sourceID, lineIDs: lineIDs, rect: rect(of: highlight, owners: owners),
                digitizationID: digitizationID, digitizationVersion: digitizationVersion
            )
            .withSnapshot(SourceFingerprint.make(lines: owners, highlights: highlights))
            let hint = role == .term ? definitionHint(term: text, line: owners.first) : ""
            result.append((
                owners.map(\.order).min() ?? Int.max, highlight.rect.y,
                HighlightSuggestion(
                    id: highlight.id, text: text, role: role, definitionHint: hint, reference: reference,
                    highlight: EntryHighlight(kind: highlight.kind, color: highlight.color))))
        }
        return result.sorted { ($0.order, $0.y) < ($1.order, $1.y) }.map(\.suggestion)
    }

    /// Case- and whitespace-insensitive key for "is this already an entry".
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func role(for highlight: RecognizedHighlight, text: String) -> HighlightSuggestion.Role {
        switch highlight.suggestedMeaning {
        case .heading: return .heading
        case .term: return .term
        case .rule, .formula: return .rule
        case .definition, .important: return .statement
        case nil:
            switch highlight.kind {
            case .circled, .underline, .doubleUnderline:
                // A short emphasized phrase is a term; a whole emphasized sentence is a statement.
                return text.split(whereSeparator: \.isWhitespace).count <= 4 ? .term : .statement
            default:
                return .statement
            }
        }
    }

    private static func highlightLineIDs(_ highlight: RecognizedHighlight, lines: [RecognizedLine]) -> [UUID] {
        var ids: [UUID] = []
        for reference in highlight.words where !ids.contains(reference.lineID) { ids.append(reference.lineID) }
        if ids.isEmpty {
            ids = lines.filter { highlight.applies(to: $0) }.map(\.id)
        }
        let order = Dictionary(lines.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
        return ids.sorted { (order[$0] ?? Int.max) < (order[$1] ?? Int.max) }
    }

    /// The highlighted words' boxes if known (precise), else the highlight's own area.
    private static func rect(of highlight: RecognizedHighlight, owners: [RecognizedLine]) -> NormalizedRect {
        var union = NormalizedRect.zero
        for reference in highlight.words {
            guard let line = owners.first(where: { $0.id == reference.lineID }),
                  line.hasReliableWords, line.words.indices.contains(reference.wordIndex) else { continue }
            union = union.union(line.words[reference.wordIndex].rect)
        }
        return union.isEmpty ? highlight.rect : union
    }

    /// The part of the line after the term ("Ort: Chloroplasten" for the term "Ort" gives "Chloroplasten").
    static func definitionHint(term: String, line: RecognizedLine?) -> String {
        guard let line, let range = line.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return "" }
        var rest = String(line.text[range.upperBound...])
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":–—-=")))
        for prefix in ["ist ", "sind "] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tables

extension TableData {
    var columnCount: Int { max(headers.count, rows.map(\.count).max() ?? 0) }

    /// A fresh table for the editor: two columns, one row.
    static var starter: TableData { TableData(headers: ["", ""], rows: [["", ""]]) }

    /// True if every header and cell is blank.
    var isBlank: Bool {
        headers.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && rows.allSatisfy { $0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }

    /// Makes headers and all rows exactly `columnCount` wide.
    mutating func normalize() {
        let width = columnCount
        headers += Array(repeating: "", count: width - headers.count)
        rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    mutating func addColumn(header: String = "") {
        normalize()
        headers.append(header)
        rows = rows.map { $0 + [""] }
    }

    /// Does nothing for an invalid index; the last column cannot be removed.
    mutating func removeColumn(at index: Int) {
        normalize()
        guard headers.indices.contains(index), headers.count > 1 else { return }
        headers.remove(at: index)
        rows = rows.map { row in var row = row; row.remove(at: index); return row }
    }

    mutating func addRow() {
        normalize()
        rows.append(Array(repeating: "", count: columnCount))
    }

    mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    mutating func setHeader(_ value: String, at column: Int) {
        normalize()
        if headers.indices.contains(column) { headers[column] = value }
    }

    mutating func setCell(_ value: String, row: Int, column: Int) {
        normalize()
        if rows.indices.contains(row), rows[row].indices.contains(column) { rows[row][column] = value }
    }
}

// MARK: - Ordering within a section

enum EntryOrdering {
    /// Entry ids in the new overall order after moving entries *within one kind* (`from`/`to` are offsets
    /// among the entries of that kind, as in `onMove`). The slots of other kinds stay where they are.
    static func reordered(
        all: [(id: UUID, kind: EntryKind)], kind: EntryKind, from: IndexSet, to: Int
    ) -> [UUID] {
        var ofKind = all.filter { $0.kind == kind }.map(\.id)
        ofKind.move(fromOffsets: from, toOffset: to)
        var iterator = ofKind.makeIterator()
        return all.map { $0.kind == kind ? (iterator.next() ?? $0.id) : $0.id }
    }
}

// MARK: - Source references

struct ResolvedMark: Equatable {
    var sourceID: UUID
    /// What to mark in the page image (nil: nothing known).
    var rect: NormalizedRect?
    /// Some referenced lines no longer exist: the stored rect is shown instead.
    var isStale: Bool
}

enum ReferenceResolver {
    /// Where to mark `reference` on the page. `resolvedLines` are the lines the repository still finds for it.
    /// Prefers the stored rect (it may be narrower, for single words) as long as it lies inside the current
    /// line area; follows the lines if the geometry moved; uses the stored rect if some or all lines are gone.
    static func mark(for reference: SourceReference, resolvedLines: [RecognizedLine]) -> ResolvedMark {
        let lineRect = resolvedLines.map(\.rect).reduce(NormalizedRect.zero) { $0.union($1) }
        let hasLines = !resolvedLines.isEmpty && !lineRect.isEmpty
        let stored = reference.rect.flatMap { $0.isEmpty ? nil : $0 }
        let stale = !reference.lineIDs.isEmpty && resolvedLines.count < reference.lineIDs.count
        let rect: NormalizedRect?
        if stale, let stored {
            // Some lines are gone: the stored area is all that is known about the whole place (as the note says).
            rect = stored
        } else if let stored, hasLines {
            rect = stored.coverage(by: lineRect) > 0.9 ? stored : lineRect
        } else if hasLines {
            rect = lineRect
        } else {
            rect = stored
        }
        return ResolvedMark(sourceID: reference.sourceID, rect: rect, isStale: stale)
    }
}

// MARK: - Lookup helpers

extension Subject {
    func source(withID id: UUID) -> Source? {
        imports.lazy.flatMap(\.sources).first { $0.id == id }
    }

    func topic(withID id: UUID) -> Topic? {
        topics.first { $0.id == id }
    }
}

/// A topic named in a hint (kept as id and title so that a deleted topic never gets touched).
struct AffectedTopic: Identifiable, Hashable {
    var id: UUID
    var title: String

    init(_ topic: Topic) {
        id = topic.id
        title = topic.title
    }

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}
