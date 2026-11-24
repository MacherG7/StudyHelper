import Foundation
import SwiftData
import StudyCore

/// Input for one page/photo when creating an import batch.
public struct SourceInput: Sendable {
    public var imageData: Data?
    public var pageSize: PageSize
    public var hasEmbeddedText: Bool

    public init(imageData: Data? = nil, pageSize: PageSize, hasEmbeddedText: Bool = false) {
        self.imageData = imageData
        self.pageSize = pageSize
        self.hasEmbeddedText = hasEmbeddedText
    }
}

/// Result of storing a digitization.
public struct SaveDigitizationOutcome {
    public var digitization: Digitization
    /// Corrections whose line was not found again; show them to the user.
    public var unmatchedCorrections: [LineCorrectionValue]
    /// Highlight edits (added/changed/deleted highlights) that found no counterpart.
    public var unmatchedHighlightCorrections: [HighlightCorrectionValue] = []
    /// Corrections whose stored data was unreadable (kept untouched, flagged unmatched).
    public var skippedCorrectionCount: Int = 0
}

/// All persistence operations of StudyHelper over a `ModelContext`.
///
/// Main actor only: use the container's `mainContext`. SwiftUI views observe
/// changes through `@Query` / the `@Observable` models themselves; every operation
/// here saves the context before returning.
@MainActor
public final class StudyRepository {
    public let context: ModelContext
    /// Keeps the container alive when the repository was created from it
    /// (a `ModelContext` does not retain its container).
    private let container: ModelContainer?

    public init(context: ModelContext) {
        self.context = context
        self.container = nil
    }

    /// Uses the container's `mainContext` and retains the container.
    public init(container: ModelContainer) {
        self.context = container.mainContext
        self.container = container
    }

    private func save() throws {
        if context.hasChanges { try context.save() }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Subjects

    @discardableResult
    public func createSubject(name: String) throws -> Subject {
        let name = Self.trimmed(name)
        guard !name.isEmpty else { throw StudyDataError.emptyName }
        let next = (try subjects().map(\.sortIndex).max() ?? -1) + 1
        let subject = Subject(name: name, sortIndex: next)
        context.insert(subject)
        try save()
        return subject
    }

    public func renameSubject(_ subject: Subject, to name: String) throws {
        let name = Self.trimmed(name)
        guard !name.isEmpty else { throw StudyDataError.emptyName }
        subject.name = name
        try save()
    }

    /// Deletes the subject with all imports, sources, digitizations, corrections and topics.
    public func deleteSubject(_ subject: Subject) throws {
        context.delete(subject)
        try save()
    }

    public func subjects() throws -> [Subject] {
        try context.fetch(FetchDescriptor<Subject>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]))
    }

    /// Adds a confirmed term (Vision `customWords`); duplicates are ignored case-insensitively.
    public func addConfirmedTerm(_ term: String, to subject: Subject) throws {
        let term = Self.trimmed(term)
        guard !term.isEmpty else { return }
        if !subject.confirmedTerms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            subject.confirmedTerms.append(term)
            try save()
        }
    }

    public func removeConfirmedTerm(_ term: String, from subject: Subject) throws {
        subject.confirmedTerms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        try save()
    }

    // MARK: - Imports and sources

    @discardableResult
    public func createBatch(
        in subject: Subject, kind: ImportKind, originalFileName: String? = nil,
        originalPDF: Data? = nil, goodnotesVariant: GoodnotesVariant? = nil,
        reducedPDF: Data? = nil, pages: [SourceInput]
    ) throws -> ImportBatch {
        let batch = ImportBatch(
            kind: kind, originalFileName: originalFileName, originalPDF: originalPDF,
            goodnotesVariant: goodnotesVariant, reducedPDF: reducedPDF)
        batch.subject = subject
        context.insert(batch)
        for (index, page) in pages.enumerated() {
            let source = Source(
                pageIndex: index, imageData: page.imageData, pageSize: page.pageSize,
                hasEmbeddedText: page.hasEmbeddedText)
            source.batch = batch
            context.insert(source)
        }
        try save()
        return batch
    }

    public func deleteBatch(_ batch: ImportBatch) throws {
        context.delete(batch)
        try save()
    }

    /// Sources waiting for recognition: state `.pending` only. New sources start
    /// pending; done sources become pending again only through `prepareReRecognition`.
    /// Loading, saving or structuring never changes the state of a done source.
    public func sourcesNeedingDigitization(in batch: ImportBatch? = nil) throws -> [Source] {
        let all = try batch.map { $0.sortedSources } ?? context.fetch(FetchDescriptor<Source>())
        return all.filter { $0.digitizationState == .pending }
    }

    /// Explicit user action "Neu erkennen": marks sources pending again, keeps all versions and corrections.
    public func prepareReRecognition(for sources: [Source]) throws {
        for source in sources {
            source.digitizationState = .pending
            source.digitizationError = nil
        }
        try save()
    }

    public func markDigitizationFailed(_ source: Source, message: String) throws {
        source.digitizationState = .failed
        source.digitizationError = message
        try save()
    }

    // MARK: Reading stored blobs (throwing)

    /// Maps a blob failure to the user-facing error; a digitization with unreadable
    /// data is flagged (and stays untouched) so that no operation overwrites it.
    private func surface(_ error: Error, digitization: Digitization? = nil) -> Error {
        guard let blobError = error as? JSONBlob.BlobError else { return error }
        JSONBlob.log(blobError, what: "digitization data")
        switch blobError {
        case .newerVersion:
            return StudyDataError.dataFromNewerVersion
        case .undecodable(let detail):
            if let digitization, !digitization.isDamaged {
                digitization.isDamaged = true
                digitization.damageNote = "Version \(digitization.versionNumber): \(detail)"
                try? context.save()
            }
            return StudyDataError.damagedData
        }
    }

    private func read<T>(_ digitization: Digitization, _ body: () throws -> T) throws -> T {
        if digitization.isDamaged { throw StudyDataError.damagedData }
        do { return try body() } catch { throw surface(error, digitization: digitization) }
    }

    private func lines(of digitization: Digitization) throws -> [RecognizedLine] {
        try read(digitization) { try digitization.decodedLines() }
    }

    private func highlights(of digitization: Digitization) throws -> [RecognizedHighlight] {
        try read(digitization) { try digitization.decodedHighlights() }
    }

    private func rawHighlights(of digitization: Digitization) throws -> [RecognizedHighlight] {
        try read(digitization) { try digitization.decodedRawHighlights() }
    }

    /// Line corrections of a source in creation order. Unreadable records are kept
    /// untouched, flagged as unmatched and skipped (counted in `skipped`).
    private func lineCorrections(of source: Source) -> (records: [LineCorrection], values: [LineCorrectionValue], skipped: Int) {
        var records: [LineCorrection] = []
        var values: [LineCorrectionValue] = []
        var skipped = 0
        for record in source.corrections.sorted(by: { $0.createdAt < $1.createdAt }) {
            do {
                values.append(try record.decodedValue())
                records.append(record)
            } catch {
                JSONBlob.log(error, what: "line correction")
                record.isUnmatched = true
                skipped += 1
            }
        }
        return (records, values, skipped)
    }

    private func highlightCorrections(of source: Source) -> (records: [HighlightCorrection], values: [HighlightCorrectionValue], skipped: Int) {
        var records: [HighlightCorrection] = []
        var values: [HighlightCorrectionValue] = []
        var skipped = 0
        for record in source.highlightCorrections.sorted(by: { $0.createdAt < $1.createdAt }) {
            do {
                var value = try record.decodedValue()
                value.id = record.id
                values.append(value)
                records.append(record)
            } catch {
                JSONBlob.log(error, what: "highlight correction")
                record.isUnmatched = true
                skipped += 1
            }
        }
        return (records, values, skipped)
    }

    /// Re-applies all stored corrections to automatic `lines`/`highlights` and updates the
    /// unmatched flags of the correction records.
    private struct Merged {
        var lines: [RecognizedLine]
        var highlights: [RecognizedHighlight]
        var unmatchedLines: [LineCorrectionValue]
        var unmatchedHighlights: [HighlightCorrectionValue]
        var skipped: Int
    }

    private func mergeCorrections(
        of source: Source, lines: [RecognizedLine], highlights: [RecognizedHighlight]
    ) -> Merged {
        let lineSet = lineCorrections(of: source)
        let lineOutcome = CorrectionMerger.apply(lineSet.values, to: lines)
        for (i, record) in lineSet.records.enumerated() {
            record.isUnmatched = lineOutcome.unmatchedIndices.contains(i)
        }
        let highlightSet = highlightCorrections(of: source)
        let highlightOutcome = HighlightCorrectionMerger.apply(
            highlightSet.values, to: highlights, lines: lineOutcome.lines)
        for (i, record) in highlightSet.records.enumerated() {
            record.isUnmatched = highlightOutcome.unmatchedIndices.contains(i)
        }
        return Merged(
            lines: lineOutcome.lines, highlights: highlightOutcome.highlights,
            unmatchedLines: lineOutcome.unmatched,
            unmatchedHighlights: highlightOutcome.unmatchedIndices.map { highlightSet.values[$0] },
            skipped: lineSet.skipped + highlightSet.skipped)
    }

    // MARK: Saving and restoring versions

    /// Stores a recognition result as a new version and makes it current.
    ///
    /// Only a `.pending` source can receive a digitization (new import, or after
    /// `prepareReRecognition`); otherwise `StudyDataError.digitizationNotPending` is thrown.
    /// Line ids are carried over from the previous current version by geometric matching so
    /// that references stay valid; stored line and highlight corrections are re-applied and
    /// win over the automatic result. The raw recognition is kept in the version.
    @discardableResult
    public func saveDigitization(_ result: DigitizationResult, for source: Source) throws -> SaveDigitizationOutcome {
        guard source.digitizationState == .pending else { throw StudyDataError.digitizationNotPending }

        var lines = result.lines
        var rawHighlights = result.highlights
        if let previous = source.currentDigitization, let old = try? self.lines(of: previous) {
            let carried = LineIdentity.carryOver(from: old, to: lines)
            lines = carried.lines
            rawHighlights = LineIdentity.remap(rawHighlights, using: carried.idMap)
        }

        let merged = mergeCorrections(of: source, lines: lines, highlights: rawHighlights)
        var markdown = result.originalMarkdown
        if merged.lines != lines || merged.highlights != rawHighlights
            || lines.map(\.id) != result.lines.map(\.id) {
            markdown = OriginalTextMarkdown.build(lines: merged.lines, highlights: merged.highlights)
        }

        let nextVersion = (source.digitizations.map(\.versionNumber).max() ?? 0) + 1
        for old in source.digitizations { old.isCurrent = false }
        let digitization = Digitization(
            versionNumber: nextVersion, isCurrent: true, metadata: result.metadata,
            originalMarkdown: markdown, lines: merged.lines, highlights: merged.highlights,
            warnings: result.warnings, rawHighlights: rawHighlights)
        digitization.source = source
        context.insert(digitization)
        source.pageSize = result.pageSize
        source.digitizationState = .done
        source.digitizationError = nil
        try save()
        return SaveDigitizationOutcome(
            digitization: digitization, unmatchedCorrections: merged.unmatchedLines,
            unmatchedHighlightCorrections: merged.unmatchedHighlights,
            skippedCorrectionCount: merged.skipped)
    }

    /// Makes an older version current again; line and highlight corrections are re-applied
    /// and still win, line ids are aligned with the version that was current before.
    /// Returns line corrections that no longer match a line of that version (highlight
    /// corrections without counterpart are flagged on their records, see
    /// `Source.unmatchedCorrectionCount`). Throws without changing anything if the
    /// version's data is unreadable.
    @discardableResult
    public func restoreVersion(_ digitization: Digitization) throws -> [LineCorrectionValue] {
        guard let source = digitization.source else { return [] }
        var lines = try self.lines(of: digitization)
        var raw = try rawHighlights(of: digitization)
        if let previous = source.currentDigitization, previous !== digitization,
           let old = try? self.lines(of: previous) {
            let carried = LineIdentity.carryOver(from: old, to: lines)
            lines = carried.lines
            raw = LineIdentity.remap(raw, using: carried.idMap)
        }
        let merged = mergeCorrections(of: source, lines: lines, highlights: raw)
        for other in source.digitizations { other.isCurrent = (other === digitization) }
        digitization.linesData = JSONBlob.encode(merged.lines)
        digitization.highlightsData = JSONBlob.encode(merged.highlights)
        digitization.rawHighlightsData = JSONBlob.encode(raw)
        digitization.originalMarkdown = OriginalTextMarkdown.build(lines: merged.lines, highlights: merged.highlights)
        try save()
        return merged.unmatchedLines
    }

    // MARK: Corrections

    /// Stores a manual correction (survives re-recognition) and updates the current version.
    /// Throws `.damagedData` (changing nothing) if the version's data is unreadable.
    public func correctLine(source: Source, lineID: UUID, newText: String) throws {
        guard let digitization = source.currentDigitization else { throw StudyDataError.noCurrentDigitization }
        var lines = try self.lines(of: digitization)
        let highlights = try self.highlights(of: digitization)
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { throw StudyDataError.lineNotFound }
        let line = lines[index]
        let value = LineCorrectionValue(rect: line.rect, recognizedText: line.automaticText, correctedText: newText)

        // Reuse the correction that belongs to this line (same one-to-one matching as the
        // merge) instead of stacking duplicates.
        let existing = lineCorrections(of: source)
        let matching = CorrectionMerger.matching(existing.values, lines)
        if let i = existing.records.indices.first(where: { matching[$0] == index }) {
            var updated = existing.values[i]
            updated.correctedText = newText
            updated.rect = line.rect
            existing.records[i].value = updated
            existing.records[i].isUnmatched = false
        } else {
            let correction = LineCorrection(value: value)
            correction.source = source
            context.insert(correction)
        }

        lines[index] = CorrectionMerger.apply([value], to: [line]).lines[0]
        digitization.lines = lines
        digitization.originalMarkdown = OriginalTextMarkdown.build(lines: lines, highlights: highlights)
        try save()
    }

    /// Drops a correction the user no longer wants (e.g. an unmatched one). Takes effect on the next re-recognition.
    public func discard(_ correction: LineCorrection) throws {
        context.delete(correction)
        try save()
    }

    public func discard(_ correction: HighlightCorrection) throws {
        context.delete(correction)
        try save()
    }

    /// Lines of the current digitization of the referenced source that `reference` points to.
    public func lines(for reference: SourceReference) throws -> [RecognizedLine] {
        let id = reference.sourceID
        guard let source = try context.fetch(FetchDescriptor<Source>(predicate: #Predicate { $0.id == id })).first,
              let digitization = source.currentDigitization else { return [] }
        let wanted = Set(reference.lineIDs)
        return try lines(of: digitization).filter { wanted.contains($0.id) }.sorted { $0.order < $1.order }
    }

    // MARK: Review counts

    public func openReviewCount(for source: Source) -> Int {
        source.currentDigitization?.openReviewCount ?? 0
    }

    public func openReviewCount(for batch: ImportBatch) -> Int {
        batch.sources.reduce(0) { $0 + openReviewCount(for: $1) }
    }

    // MARK: Highlights (current digitization)

    /// Every edit also records a `HighlightCorrection` (identified by position and text,
    /// not by UUID) so that it survives re-recognition and version restore.
    private func editHighlights(
        of source: Source,
        _ change: (inout [RecognizedHighlight], [RecognizedLine]) throws -> Void
    ) throws {
        guard let digitization = source.currentDigitization else { throw StudyDataError.noCurrentDigitization }
        let lines = try self.lines(of: digitization)
        var highlights = try self.highlights(of: digitization)
        try change(&highlights, lines)
        digitization.highlights = highlights
        digitization.originalMarkdown = OriginalTextMarkdown.build(lines: lines, highlights: highlights)
        try save()
    }

    private func correctionRecord(for id: UUID?, in source: Source) -> HighlightCorrection? {
        guard let id else { return nil }
        return source.highlightCorrections.first { $0.id == id }
    }

    private func insertCorrection(_ value: HighlightCorrectionValue, into source: Source) {
        let record = HighlightCorrection(value: value)
        record.source = source
        context.insert(record)
    }

    private func updateHighlight(
        _ id: UUID, in source: Source, field: HighlightField, _ change: (inout RecognizedHighlight) -> Void
    ) throws {
        try editHighlights(of: source) { highlights, _ in
            guard let index = highlights.firstIndex(where: { $0.id == id }) else {
                throw StudyDataError.highlightNotFound
            }
            let before = highlights[index]
            var after = before
            change(&after)
            after.source = .user
            after.status = .confident

            if let record = correctionRecord(for: before.correctionID, in: source) {
                var value = try record.decodedValue()
                switch value.action {
                case .add:
                    value.kind = after.kind
                    value.color = after.color
                    value.meaning = after.suggestedMeaning
                case .modify, .delete:
                    switch field {
                    case .kind: value.kind = after.kind
                    case .color: value.color = after.color
                    case .meaning: value.meaning = after.suggestedMeaning
                    }
                    value.markChanged(field)
                }
                record.value = value
                record.isUnmatched = false
                after.correctionID = record.id
            } else if before.source == .user {
                // User-created highlight without a record (older data): record it as an addition.
                let value = HighlightCorrectionValue(
                    id: before.id, action: .add, rect: before.rect, text: before.text,
                    changedFields: [.kind, .color, .meaning], kind: after.kind, color: after.color,
                    meaning: after.suggestedMeaning)
                insertCorrection(value, into: source)
                after.correctionID = value.id
            } else {
                var value = HighlightCorrectionValue(
                    action: .modify, rect: before.rect, text: before.text, originalKind: before.kind)
                switch field {
                case .kind: value.kind = after.kind
                case .color: value.color = after.color
                case .meaning: value.meaning = after.suggestedMeaning
                }
                value.markChanged(field)
                insertCorrection(value, into: source)
                after.correctionID = value.id
            }
            highlights[index] = after
        }
    }

    public func setHighlightKind(_ kind: HighlightKind, id: UUID, in source: Source) throws {
        try updateHighlight(id, in: source, field: .kind) { $0.kind = kind }
    }

    public func setHighlightColor(_ color: RGBColor?, id: UUID, in source: Source) throws {
        try updateHighlight(id, in: source, field: .color) { $0.color = color }
    }

    public func setHighlightMeaning(_ meaning: HighlightMeaning?, id: UUID, in source: Source) throws {
        try updateHighlight(id, in: source, field: .meaning) { $0.suggestedMeaning = meaning }
    }

    public func deleteHighlight(id: UUID, in source: Source) throws {
        try editHighlights(of: source) { highlights, _ in
            guard let index = highlights.firstIndex(where: { $0.id == id }) else {
                throw StudyDataError.highlightNotFound
            }
            let before = highlights[index]
            if let record = correctionRecord(for: before.correctionID, in: source) {
                var value = try record.decodedValue()
                if value.action == .add {
                    context.delete(record)
                } else {
                    value.action = .delete
                    record.value = value
                    record.isUnmatched = false
                }
            } else if before.source != .user {
                insertCorrection(
                    HighlightCorrectionValue(
                        action: .delete, rect: before.rect, text: before.text, originalKind: before.kind),
                    into: source)
            }
            highlights.remove(at: index)
        }
    }

    /// Creates a highlight from selected words (source `.user`).
    @discardableResult
    public func addHighlight(
        in source: Source, words: [WordReference], kind: HighlightKind,
        color: RGBColor? = nil, meaning: HighlightMeaning? = nil
    ) throws -> RecognizedHighlight {
        guard !words.isEmpty else { throw StudyDataError.noWordsSelected }
        var created: RecognizedHighlight?
        try editHighlights(of: source) { highlights, lines in
            let byID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var texts: [String] = []
            var rect = NormalizedRect.zero
            for ref in words {
                guard let line = byID[ref.lineID], line.words.indices.contains(ref.wordIndex) else {
                    throw StudyDataError.lineNotFound
                }
                let word = line.words[ref.wordIndex]
                texts.append(word.text)
                rect = rect.union(word.rect)
            }
            let value = HighlightCorrectionValue(
                action: .add, rect: rect, text: texts.joined(separator: " "),
                changedFields: [.kind, .color, .meaning], kind: kind, color: color, meaning: meaning)
            let highlight = RecognizedHighlight(
                id: value.id, text: value.text, kind: kind, color: color, rect: rect,
                suggestedMeaning: meaning, source: .user, words: words, correctionID: value.id)
            insertCorrection(value, into: source)
            highlights.append(highlight)
            created = highlight
        }
        return created!
    }

    // MARK: - Topics

    @discardableResult
    public func createTopic(
        in subject: Subject, title: String, summary: String = "", origin: TopicOrigin = .manual
    ) throws -> Topic {
        let title = Self.trimmed(title)
        guard !title.isEmpty else { throw StudyDataError.emptyTopicTitle }
        let next = (subject.topics.map(\.sortIndex).max() ?? -1) + 1
        let topic = Topic(title: title, summary: summary, origin: origin, sortIndex: next)
        topic.subject = subject
        context.insert(topic)
        try save()
        return topic
    }

    public func topics(in subject: Subject) -> [Topic] {
        subject.topics.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    /// Records an edit: a confirmed topic stays confirmed but gets `modifiedAt`.
    private func touch(_ topic: Topic) {
        if topic.isConfirmed { topic.modifiedAt = Date() }
    }

    public func renameTopic(_ topic: Topic, to title: String) throws {
        let title = Self.trimmed(title)
        guard !title.isEmpty else { throw StudyDataError.emptyTopicTitle }
        topic.title = title
        touch(topic)
        try save()
    }

    public func setSummary(_ summary: String, for topic: Topic) throws {
        topic.summary = summary
        touch(topic)
        try save()
    }

    public func deleteTopic(_ topic: Topic) throws {
        context.delete(topic)
        try save()
    }

    public func assign(_ source: Source, to topic: Topic) throws {
        if !topic.sources.contains(where: { $0 === source }) {
            topic.sources.append(source)
            touch(topic)
            try save()
        }
    }

    public func remove(_ source: Source, from topic: Topic) throws {
        topic.sources.removeAll { $0 === source }
        touch(topic)
        try save()
    }

    public func moveSource(_ source: Source, from: Topic, to: Topic) throws {
        from.sources.removeAll { $0 === source }
        if !to.sources.contains(where: { $0 === source }) { to.sources.append(source) }
        touch(from)
        touch(to)
        try save()
    }

    /// Confirms a topic (requires a title). Later edits keep it confirmed and set `modifiedAt`.
    public func confirm(_ topic: Topic) throws {
        guard !Self.trimmed(topic.title).isEmpty else { throw StudyDataError.emptyTopicTitle }
        topic.isConfirmed = true
        topic.confirmedAt = Date()
        topic.modifiedAt = nil
        try save()
    }

    // MARK: Entries

    @discardableResult
    public func addEntry(
        to topic: Topic, kind: EntryKind, text: String = "", term: String = "",
        definition: String = "", tableData: TableData? = nil, origin: EntryOrigin = .user,
        sourceReferences: [SourceReference] = [], highlight: EntryHighlight? = nil,
        supplementStatus: SupplementStatus? = nil, supplementReason: String? = nil
    ) throws -> TopicEntry {
        let next = (topic.entries.map(\.sortIndex).max() ?? -1) + 1
        let entry = TopicEntry(
            kind: kind, sortIndex: next, text: text, term: term, definition: definition,
            tableData: tableData, origin: origin, sourceReferences: sourceReferences,
            highlight: highlight, supplementStatus: supplementStatus ?? (origin == .aiSupplement ? .proposed : nil),
            supplementReason: supplementReason)
        entry.topic = topic
        context.insert(entry)
        touch(topic)
        try save()
        return entry
    }

    /// Applies `change` to the entry and records the edit on its topic.
    /// Throws `.damagedData` without calling `change` if the entry's stored blobs are unreadable.
    public func editEntry(_ entry: TopicEntry, _ change: (TopicEntry) -> Void) throws {
        guard entry.isReadable else { throw StudyDataError.damagedData }
        change(entry)
        if let topic = entry.topic { touch(topic) }
        try save()
    }

    /// Replaces the source references of an entry without recording an edit of the topic: the content
    /// is unchanged (used when the user acknowledges a changed source with "Ignorieren").
    /// Throws `.damagedData` if the entry's stored blobs are unreadable.
    public func replaceSourceReferences(of entry: TopicEntry, with references: [SourceReference]) throws {
        guard entry.isReadable else { throw StudyDataError.damagedData }
        entry.sourceReferences = references
        try save()
    }

    public func setSupplementStatus(_ status: SupplementStatus, for entry: TopicEntry) throws {
        try editEntry(entry) { $0.supplementStatus = status }
    }

    public func deleteEntry(_ entry: TopicEntry) throws {
        let topic = entry.topic
        context.delete(entry)
        if let topic {
            topic.entries.removeAll { $0 === entry }
            renumber(topic)
            touch(topic)
        }
        try save()
    }

    /// Moves an entry to `index` in the sorted entry list of its topic.
    public func moveEntry(_ entry: TopicEntry, toIndex index: Int) throws {
        guard let topic = entry.topic else { return }
        var sorted = topic.sortedEntries
        sorted.removeAll { $0 === entry }
        sorted.insert(entry, at: min(max(index, 0), sorted.count))
        for (i, e) in sorted.enumerated() { e.sortIndex = i }
        touch(topic)
        try save()
    }

    /// Reorders entries to match `orderedIDs` (unknown ids ignored, missing entries keep their relative order at the end).
    public func reorderEntries(in topic: Topic, orderedIDs: [UUID]) throws {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        let sorted = topic.sortedEntries.sorted {
            (rank[$0.id] ?? Int.max, $0.sortIndex) < (rank[$1.id] ?? Int.max, $1.sortIndex)
        }
        for (i, e) in sorted.enumerated() { e.sortIndex = i }
        touch(topic)
        try save()
    }

    private func renumber(_ topic: Topic) {
        for (i, e) in topic.sortedEntries.enumerated() { e.sortIndex = i }
    }

    // MARK: Merge / split

    /// Moves all entries and sources of `a` into `b` and deletes `a`.
    /// Unreviewed content must not become confirmed content: if `a` is not confirmed, `b` becomes an
    /// unconfirmed draft (a confirmed `b` that receives content gets `modifiedAt`, see `touch`).
    public func merge(_ a: Topic, into b: Topic) throws {
        guard a !== b else { throw StudyDataError.sameTopic }
        guard a.subject === b.subject else { throw StudyDataError.differentSubjects }
        var next = (b.entries.map(\.sortIndex).max() ?? -1) + 1
        for entry in a.sortedEntries {
            entry.topic = b
            entry.sortIndex = next
            next += 1
        }
        for source in a.sources where !b.sources.contains(where: { $0 === source }) {
            b.sources.append(source)
        }
        if b.summary.isEmpty { b.summary = a.summary }
        if a.origin != b.origin { b.origin = .mixed }
        a.entries.removeAll()
        a.sources.removeAll()
        let takesUnconfirmedContent = !a.isConfirmed
        context.delete(a)
        if takesUnconfirmedContent {
            b.isConfirmed = false
            b.confirmedAt = nil
            b.modifiedAt = nil
        } else {
            touch(b)
        }
        try save()
    }

    /// Moves `entries` into a new topic of the same subject. The new topic gets the
    /// sources referenced by the moved entries (all sources if none are referenced).
    @discardableResult
    public func split(_ topic: Topic, movingEntries entries: [TopicEntry], newTitle: String) throws -> Topic {
        let title = Self.trimmed(newTitle)
        guard !title.isEmpty else { throw StudyDataError.emptyTopicTitle }
        guard entries.allSatisfy({ $0.topic === topic }) else { throw StudyDataError.entryNotInTopic }
        let new = Topic(title: title, origin: topic.origin, sortIndex: (topic.subject?.topics.map(\.sortIndex).max() ?? -1) + 1)
        new.subject = topic.subject
        context.insert(new)

        let referenced = Set(entries.flatMap { $0.sourceReferences.map(\.sourceID) })
        let moved = topic.sources.filter { referenced.contains($0.id) }
        new.sources = moved.isEmpty ? topic.sources : moved

        let ordered = entries.sorted { $0.sortIndex < $1.sortIndex }
        for (i, entry) in ordered.enumerated() {
            entry.topic = new
            entry.sortIndex = i
        }
        renumber(topic)
        touch(topic)
        try save()
        return new
    }

    // MARK: Impact of corrections

    /// Topics with entries that reference one of `lineIDs` on the source `sourceID`.
    public func affectedTopics(bySourceID sourceID: UUID, lineIDs: [UUID]) throws -> [Topic] {
        let wanted = Set(lineIDs)
        let all = try context.fetch(FetchDescriptor<Topic>())
        return try all.filter { topic in
            try topic.entries.contains { entry in
                let references: [SourceReference]
                do { references = try entry.decodedSourceReferences() } catch {
                    JSONBlob.log(error, what: "source references")
                    throw StudyDataError.damagedData
                }
                return references.contains { $0.sourceID == sourceID && !wanted.isDisjoint(with: $0.lineIDs) }
            }
        }
    }
}

/// Non-secret app settings. Secrets (API keys) never go here.
public struct StudySettings: @unchecked Sendable {
    private let defaults: UserDefaults
    static let multiPassKey = "multiPassRecognition"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Run Vision recognition twice and flag differences. Default: off.
    public var multiPassRecognition: Bool {
        get { defaults.bool(forKey: Self.multiPassKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.multiPassKey) }
    }
}
