import Foundation
import StudyCore
import StudyData

// "Quelle geändert": an entry that was taken over from the stored text remembers what its source looked like
// (text and emphasis of the referenced lines). If the digitization is corrected, recognized again or restored
// later, the current state is compared with that snapshot, and the user decides per entry: take the new text
// over, or ignore the change. SPEC §5: the app shows which topics are affected and offers to update them.

// MARK: - Snapshot

/// What the referenced lines look like: their text and the emphasis on them.
struct SourceFingerprint: Equatable {
    var text: String
    var highlights: [EntryHighlight]

    static func make(lines: [RecognizedLine], highlights: [RecognizedHighlight]) -> SourceFingerprint {
        let ordered = lines.sorted { $0.order < $1.order }
        let text = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var emphasis: [EntryHighlight] = []
        for highlight in highlights where ordered.contains(where: { highlight.applies(to: $0) }) {
            let value = EntryHighlight(kind: highlight.kind, color: highlight.color)
            if !emphasis.contains(value) { emphasis.append(value) }
        }
        return SourceFingerprint(text: text, highlights: emphasis)
    }
}

extension SourceReference {
    /// The same reference with the snapshot of `fingerprint`.
    func withSnapshot(_ fingerprint: SourceFingerprint) -> SourceReference {
        var copy = self
        copy.snapshotText = fingerprint.text
        copy.snapshotHighlights = fingerprint.highlights
        return copy
    }
}

// MARK: - Detection

/// How the source of one entry changed since it was taken over.
struct SourceChangeReport: Equatable {
    /// The text of the referenced lines is not the text that was taken over.
    var textChanged = false
    /// The emphasis on the referenced lines is not the one that was taken over.
    var highlightChanged = false
    /// Some referenced lines no longer exist.
    var linesMissing = false
    /// Reference without snapshot (older data): only the digitization version can be compared.
    var versionChanged = false
    /// At least one referenced line still exists, so its text can be taken over again.
    var canAdopt = false

    var isChanged: Bool { textChanged || highlightChanged || linesMissing || versionChanged }

    /// German description of what changed, for the marker and the actions.
    var detail: String {
        var parts: [String] = []
        if textChanged { parts.append("Der Text wurde korrigiert") }
        if highlightChanged { parts.append("die Hervorhebung wurde geändert") }
        if linesMissing { parts.append("Zeilen fehlen jetzt") }
        if parts.isEmpty, versionChanged { parts.append("Die Seite wurde neu erkannt") }
        guard let first = parts.first else { return "" }
        let rest = parts.dropFirst()
        let joined = rest.isEmpty ? first : first + ", " + rest.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }
}

enum SourceChangeDetector {
    /// Compares the snapshot of `reference` with the current state. `lines` and `highlights` are those of the
    /// whole current digitization of the page (`version`: its version number).
    static func detect(
        reference: SourceReference, lines: [RecognizedLine], highlights: [RecognizedHighlight], version: Int?
    ) -> SourceChangeReport {
        let wanted = Set(reference.lineIDs)
        let referenced = lines.filter { wanted.contains($0.id) }
        var report = SourceChangeReport()
        report.linesMissing = referenced.count < wanted.count
        report.canAdopt = !referenced.isEmpty
        let current = SourceFingerprint.make(lines: referenced, highlights: highlights)
        if let text = reference.snapshotText { report.textChanged = current.text != text }
        if let taken = reference.snapshotHighlights { report.highlightChanged = Set(current.highlights) != Set(taken) }
        if reference.snapshotText == nil, reference.snapshotHighlights == nil,
           let taken = reference.digitizationVersion, let version {
            report.versionChanged = taken != version
        }
        return report
    }
}

// MARK: - Reading the current page

/// The current digitization of a page, decoded once.
struct PageContent {
    var digitizationID: UUID
    var version: Int
    var lines: [RecognizedLine]
    var highlights: [RecognizedHighlight]

    /// nil if the page has no digitization or it cannot be read.
    init?(_ source: Source) {
        guard let digitization = source.currentDigitization, !digitization.hasUnreadableData else { return nil }
        digitizationID = digitization.id
        version = digitization.versionNumber
        lines = digitization.lines.sorted { $0.order < $1.order }
        highlights = digitization.highlights
    }
}

@MainActor
enum SourceChecks {
    /// Entries (origin "Original") whose source changed since they were taken over, by entry id.
    /// Entries without reference, with a missing or unreadable source, and unchanged ones are left out.
    /// Reads model properties, so a `DerivedValue` around it refreshes after corrections.
    static func reports(for entries: [TopicEntry], subject: Subject?) -> [UUID: SourceChangeReport] {
        var pages: [UUID: PageContent] = [:]
        var unreadable: Set<UUID> = []
        var result: [UUID: SourceChangeReport] = [:]
        for entry in entries where entry.origin == .original {
            guard let reference = entry.sourceReferences.first,
                  let source = subject?.source(withID: reference.sourceID), !unreadable.contains(source.id) else { continue }
            if pages[source.id] == nil {
                guard let page = PageContent(source) else { unreadable.insert(source.id); continue }
                pages[source.id] = page
            }
            guard let page = pages[source.id] else { continue }
            let report = SourceChangeDetector.detect(
                reference: reference, lines: page.lines, highlights: page.highlights, version: page.version)
            if report.isChanged { result[entry.id] = report }
        }
        return result
    }
}

// MARK: - Resolving a change

enum SourceChangeError: LocalizedError {
    case sourceUnavailable
    case noLinesLeft

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "Die Quelle dieses Eintrags ist nicht verfügbar."
        case .noLinesLeft: "Die Zeilen dieses Eintrags gibt es in der Quelle nicht mehr. Es gibt keinen Text zum Übernehmen."
        }
    }
}

@MainActor
enum SourceChangeResolver {
    private static func context(of entry: TopicEntry, subject: Subject?) throws -> (SourceReference, PageContent, [RecognizedLine]) {
        guard let reference = entry.sourceReferences.first,
              let source = subject?.source(withID: reference.sourceID),
              let page = PageContent(source) else { throw SourceChangeError.sourceUnavailable }
        let wanted = Set(reference.lineIDs)
        return (reference, page, page.lines.filter { wanted.contains($0.id) })
    }

    /// "Text aus Quelle übernehmen": text, emphasis and reference of the entry follow the current source.
    /// Taking over from single words widens to the whole lines; the user can edit the entry afterwards.
    static func adopt(_ entry: TopicEntry, subject: Subject?, repository: StudyRepository) throws {
        let (reference, page, referenced) = try context(of: entry, subject: subject)
        guard !referenced.isEmpty else { throw SourceChangeError.noLinesLeft }
        let selection = SourceSelection(
            sourceID: reference.sourceID, digitizationID: page.digitizationID, digitizationVersion: page.version,
            lines: referenced, highlights: page.highlights)
        let text = selection.text
        let newReference = selection.reference
        let highlight = selection.entryHighlight
        try repository.editEntry(entry) { target in
            switch target.kind {
            case .term:
                let parts = TermSplitter.split(lines: selection.orderedLines.map(\.text), text: text)
                target.term = parts.term
                target.definition = parts.definition
            case .table:
                break
            default:
                target.text = text
            }
            target.highlight = highlight
            target.sourceReferences = [newReference]
        }
    }

    /// "Ignorieren": the entry keeps its content; the reference is brought up to date so that the marker goes away
    /// (the topic is not marked as edited, nothing about its content changed).
    static func acknowledge(_ entry: TopicEntry, subject: Subject?, repository: StudyRepository) throws {
        let (original, page, referenced) = try context(of: entry, subject: subject)
        var reference = original
        let kept = Set(referenced.map(\.id))
        reference.lineIDs = reference.lineIDs.filter { kept.contains($0) }
        reference.digitizationID = page.digitizationID
        reference.digitizationVersion = page.version
        reference = reference.withSnapshot(SourceFingerprint.make(lines: referenced, highlights: page.highlights))
        try repository.replaceSourceReferences(of: entry, with: [reference])
    }
}

// MARK: - Which topics are affected

@MainActor
enum TopicImpact {
    /// Topics of `subject` with at least one entry whose source changed, limited to entries that refer to one of
    /// `sourceIDs` (nil: all). In the order of the topic list.
    static func changed(in subject: Subject?, sourceIDs: Set<UUID>? = nil) -> [AffectedTopic] {
        guard let subject else { return [] }
        let topics = subject.topics.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        return topics.filter { topic in
            let entries = topic.entries.filter { entry in
                guard let sourceIDs else { return true }
                return entry.sourceReferences.contains { sourceIDs.contains($0.sourceID) }
            }
            return !SourceChecks.reports(for: entries, subject: subject).isEmpty
        }
        .map(AffectedTopic.init)
    }

    /// Topics that use one of `sourceIDs`: the page is assigned or an entry refers to it.
    static func using(sourceIDs: Set<UUID>, in subject: Subject?) -> [AffectedTopic] {
        guard let subject else { return [] }
        let topics = subject.topics.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        return topics.filter { topic in
            topic.sources.contains { sourceIDs.contains($0.id) }
                || topic.entries.contains { $0.sourceReferences.contains { sourceIDs.contains($0.sourceID) } }
        }
        .map(AffectedTopic.init)
    }
}
