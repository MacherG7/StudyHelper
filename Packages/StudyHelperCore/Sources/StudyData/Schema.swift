import Foundation
import SwiftData
import StudyCore

// Storage decisions
// - Lines, highlights, recognition metadata, source references, table data and entry
//   highlight are stored as JSON-encoded `Data` with typed computed accessors. The
//   values are always read and written as a whole, they are shared Codable types from
//   StudyCore, and SwiftData's handling of nested Codable arrays is fragile across
//   schema versions; a JSON blob stays stable and migrates trivially.
// - Blobs are wrapped as `{ "v": n, "data": … }` (see JSONBlob); the bare pre-versioning
//   format is still read. Decoding failures are never swallowed: accessors log, the
//   repository throws and flags the digitization as damaged, and setters refuse to
//   overwrite unreadable data.
// - Large binaries (PDFs, page images, line/highlight blobs) use `.externalStorage`.
// - Every model has a unique stable `id`.
// - Models are nested in `SchemaV1` so that a later `SchemaV2` can freeze this shape.

public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            Subject.self, ImportBatch.self, Source.self, Digitization.self,
            LineCorrection.self, HighlightCorrection.self, Topic.self, TopicEntry.self,
        ]
    }

    // MARK: Subject

    @Model
    public final class Subject {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var sortIndex: Int
        public var createdAt: Date
        /// Terms the user confirmed; fed to Vision as `customWords`.
        public var confirmedTerms: [String]
        /// Later: subject specific addition to AI prompts.
        public var promptAddition: String?
        @Relationship(deleteRule: .cascade, inverse: \ImportBatch.subject)
        public var imports: [ImportBatch] = []
        @Relationship(deleteRule: .cascade, inverse: \Topic.subject)
        public var topics: [Topic] = []

        public init(id: UUID = UUID(), name: String, sortIndex: Int = 0, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.sortIndex = sortIndex
            self.createdAt = createdAt
            self.confirmedTerms = []
        }
    }

    // MARK: ImportBatch

    @Model
    public final class ImportBatch {
        @Attribute(.unique) public var id: UUID
        public var subject: Subject?
        public var createdAt: Date
        public var kind: ImportKind
        public var originalFileName: String?
        /// Kept for explicit re-recognition (never re-read automatically).
        @Attribute(.externalStorage) public var originalPDF: Data?
        public var goodnotesVariant: GoodnotesVariant?
        /// Paired reduced Goodnotes PDF used for cross-checking.
        @Attribute(.externalStorage) public var reducedPDF: Data?
        @Relationship(deleteRule: .cascade, inverse: \Source.batch)
        public var sources: [Source] = []

        public init(
            id: UUID = UUID(), kind: ImportKind, originalFileName: String? = nil,
            originalPDF: Data? = nil, goodnotesVariant: GoodnotesVariant? = nil,
            reducedPDF: Data? = nil, createdAt: Date = Date()
        ) {
            self.id = id
            self.kind = kind
            self.originalFileName = originalFileName
            self.originalPDF = originalPDF
            self.goodnotesVariant = goodnotesVariant
            self.reducedPDF = reducedPDF
            self.createdAt = createdAt
        }

        /// Sources in page order.
        public var sortedSources: [Source] { sources.sorted { $0.pageIndex < $1.pageIndex } }
    }

    // MARK: Source

    @Model
    public final class Source {
        @Attribute(.unique) public var id: UUID
        public var batch: ImportBatch?
        public var pageIndex: Int
        /// Rendered page or photo.
        @Attribute(.externalStorage) public var imageData: Data?
        public var pageWidth: Double
        public var pageHeight: Double
        public var hasEmbeddedText: Bool
        public var digitizationState: DigitizationState
        /// German message when `digitizationState == .failed`.
        public var digitizationError: String?
        @Relationship(deleteRule: .cascade, inverse: \Digitization.source)
        public var digitizations: [Digitization] = []
        @Relationship(deleteRule: .cascade, inverse: \LineCorrection.source)
        public var corrections: [LineCorrection] = []
        @Relationship(deleteRule: .cascade, inverse: \HighlightCorrection.source)
        public var highlightCorrections: [HighlightCorrection] = []
        @Relationship(inverse: \Topic.sources)
        public var topics: [Topic] = []

        public init(
            id: UUID = UUID(), pageIndex: Int, imageData: Data? = nil,
            pageSize: PageSize, hasEmbeddedText: Bool = false
        ) {
            self.id = id
            self.pageIndex = pageIndex
            self.imageData = imageData
            self.pageWidth = pageSize.width
            self.pageHeight = pageSize.height
            self.hasEmbeddedText = hasEmbeddedText
            self.digitizationState = .pending
        }

        public var pageSize: PageSize {
            get { PageSize(width: pageWidth, height: pageHeight) }
            set { pageWidth = newValue.width; pageHeight = newValue.height }
        }

        public var currentDigitization: Digitization? { digitizations.first(where: \.isCurrent) }

        public var sortedDigitizations: [Digitization] {
            digitizations.sorted { $0.versionNumber < $1.versionNumber }
        }

        /// Corrections (lines and highlights) that found no counterpart after the last
        /// re-recognition; the UI shows them so the user can re-apply or discard them.
        public var unmatchedCorrectionCount: Int {
            corrections.filter(\.isUnmatched).count + highlightCorrections.filter(\.isUnmatched).count
        }
    }

    // MARK: Digitization

    @Model
    public final class Digitization {
        @Attribute(.unique) public var id: UUID
        public var source: Source?
        public var versionNumber: Int
        public var isCurrent: Bool
        public var createdAt: Date
        public var originalMarkdown: String
        public var warnings: [String]
        @Attribute(.externalStorage) var metadataData: Data
        @Attribute(.externalStorage) var linesData: Data
        @Attribute(.externalStorage) var highlightsData: Data
        /// Automatic highlights as recognized, before user edits (nil: not stored, `highlights` is the base).
        @Attribute(.externalStorage) var rawHighlightsData: Data?
        /// Set when a stored blob could not be read; such a version is never modified or overwritten.
        public var isDamaged: Bool = false
        public var damageNote: String?

        public init(
            id: UUID = UUID(), versionNumber: Int, isCurrent: Bool = true,
            createdAt: Date = Date(), metadata: RecognitionMetadata,
            originalMarkdown: String, lines: [RecognizedLine],
            highlights: [RecognizedHighlight], warnings: [String] = [],
            rawHighlights: [RecognizedHighlight]? = nil
        ) {
            self.id = id
            self.versionNumber = versionNumber
            self.isCurrent = isCurrent
            self.createdAt = createdAt
            self.originalMarkdown = originalMarkdown
            self.warnings = warnings
            self.metadataData = JSONBlob.encode(metadata)
            self.linesData = JSONBlob.encode(lines)
            self.highlightsData = JSONBlob.encode(highlights)
            self.rawHighlightsData = JSONBlob.encode(rawHighlights ?? highlights)
        }

        // Throwing accessors: use these before any write that depends on the old value.
        func decodedMetadata() throws -> RecognitionMetadata {
            try JSONBlob.decode(RecognitionMetadata.self, from: metadataData)
        }
        func decodedLines() throws -> [RecognizedLine] {
            try JSONBlob.decode([RecognizedLine].self, from: linesData)
        }
        func decodedHighlights() throws -> [RecognizedHighlight] {
            try JSONBlob.decode([RecognizedHighlight].self, from: highlightsData)
        }
        /// Automatic highlights before user edits; falls back to `highlights` for versions without raw data.
        func decodedRawHighlights() throws -> [RecognizedHighlight] {
            if let rawHighlightsData { return try JSONBlob.decode([RecognizedHighlight].self, from: rawHighlightsData) }
            return try decodedHighlights()
        }

        /// Reads (logs failures). For display only; for writes use the repository, which throws.
        public var metadata: RecognitionMetadata {
            get {
                do { return try decodedMetadata() } catch {
                    JSONBlob.log(error, what: "recognition metadata")
                    return RecognitionMetadata(method: .manual, osVersion: "", deviceModel: "")
                }
            }
            set {
                guard JSONBlob.isReplaceable(metadataData, as: RecognitionMetadata.self) else {
                    JSONBlob.log(JSONBlob.BlobError.undecodable("write refused"), what: "recognition metadata"); return
                }
                metadataData = JSONBlob.encode(newValue)
            }
        }

        public var lines: [RecognizedLine] {
            get {
                do { return try decodedLines() } catch {
                    JSONBlob.log(error, what: "lines")
                    return []
                }
            }
            set {
                guard JSONBlob.isReplaceable(linesData, as: [RecognizedLine].self) else {
                    JSONBlob.log(JSONBlob.BlobError.undecodable("write refused"), what: "lines"); return
                }
                linesData = JSONBlob.encode(newValue)
            }
        }

        public var highlights: [RecognizedHighlight] {
            get {
                do { return try decodedHighlights() } catch {
                    JSONBlob.log(error, what: "highlights")
                    return []
                }
            }
            set {
                guard JSONBlob.isReplaceable(highlightsData, as: [RecognizedHighlight].self) else {
                    JSONBlob.log(JSONBlob.BlobError.undecodable("write refused"), what: "highlights"); return
                }
                highlightsData = JSONBlob.encode(newValue)
            }
        }

        /// Lines that still need the user's attention (0 for a damaged version).
        public var openReviewCount: Int { lines.filter(\.needsReview).count }

        /// True if any stored blob cannot be decoded right now (checks the bytes, not just `isDamaged`).
        public var hasUnreadableData: Bool {
            isDamaged || (try? decodedLines()) == nil || (try? decodedHighlights()) == nil
                || (try? decodedMetadata()) == nil
        }
    }

    // MARK: LineCorrection

    @Model
    public final class LineCorrection {
        @Attribute(.unique) public var id: UUID
        public var source: Source?
        public var createdAt: Date
        /// The line was not found again in the last (re-)recognition.
        public var isUnmatched: Bool = false
        var valueData: Data

        public init(id: UUID = UUID(), value: LineCorrectionValue, createdAt: Date = Date()) {
            self.id = id
            self.createdAt = createdAt
            self.valueData = JSONBlob.encode(value)
        }

        func decodedValue() throws -> LineCorrectionValue {
            try JSONBlob.decode(LineCorrectionValue.self, from: valueData)
        }

        /// Reads (logs failures; an unreadable value has a zero rect and never matches).
        public var value: LineCorrectionValue {
            get {
                do { return try decodedValue() } catch {
                    JSONBlob.log(error, what: "line correction")
                    return LineCorrectionValue(rect: .zero, recognizedText: "", correctedText: "")
                }
            }
            set {
                guard JSONBlob.isReplaceable(valueData, as: LineCorrectionValue.self) else {
                    JSONBlob.log(JSONBlob.BlobError.undecodable("write refused"), what: "line correction"); return
                }
                valueData = JSONBlob.encode(newValue)
            }
        }
    }

    // MARK: HighlightCorrection

    @Model
    public final class HighlightCorrection {
        @Attribute(.unique) public var id: UUID
        public var source: Source?
        public var createdAt: Date
        /// No counterpart was found in the last (re-)recognition.
        public var isUnmatched: Bool = false
        var valueData: Data

        public init(value: HighlightCorrectionValue, createdAt: Date = Date()) {
            self.id = value.id
            self.createdAt = createdAt
            self.valueData = JSONBlob.encode(value)
        }

        func decodedValue() throws -> HighlightCorrectionValue {
            try JSONBlob.decode(HighlightCorrectionValue.self, from: valueData)
        }

        public var value: HighlightCorrectionValue? {
            get {
                do { return try decodedValue() } catch {
                    JSONBlob.log(error, what: "highlight correction")
                    return nil
                }
            }
            set {
                guard let newValue,
                      JSONBlob.isReplaceable(valueData, as: HighlightCorrectionValue.self) else { return }
                valueData = JSONBlob.encode(newValue)
            }
        }
    }

    // MARK: Topic

    @Model
    public final class Topic {
        @Attribute(.unique) public var id: UUID
        public var subject: Subject?
        public var title: String
        public var summary: String
        public var origin: TopicOrigin
        public var isConfirmed: Bool
        public var confirmedAt: Date?
        /// Last edit after confirmation (nil while never edited since creation/confirmation).
        public var modifiedAt: Date?
        public var createdAt: Date
        public var sortIndex: Int
        public var sources: [Source] = []
        @Relationship(deleteRule: .cascade, inverse: \TopicEntry.topic)
        public var entries: [TopicEntry] = []

        public init(
            id: UUID = UUID(), title: String, summary: String = "",
            origin: TopicOrigin = .manual, sortIndex: Int = 0, createdAt: Date = Date()
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.origin = origin
            self.isConfirmed = false
            self.createdAt = createdAt
            self.sortIndex = sortIndex
        }

        public var sortedEntries: [TopicEntry] { entries.sorted { $0.sortIndex < $1.sortIndex } }

        /// Confirmed and not edited since: the only state in which a topic may be learned.
        /// Every edit of a confirmed topic sets `modifiedAt`, so "modifiedAt != nil" means
        /// "must be confirmed again before learning".
        public var isReadyForLearning: Bool { isConfirmed && modifiedAt == nil }
        /// Confirmed once, edited since: shows as changed until the user confirms again.
        public var needsReconfirmation: Bool { isConfirmed && modifiedAt != nil }

        public var sortedSources: [Source] {
            sources.sorted {
                ($0.batch?.createdAt ?? .distantPast, $0.pageIndex) < ($1.batch?.createdAt ?? .distantPast, $1.pageIndex)
            }
        }
        /// AI supplements still waiting for accept/reject.
        public var openSupplementCount: Int {
            entries.filter { $0.supplementStatus == .proposed }.count
        }
    }

    // MARK: TopicEntry

    @Model
    public final class TopicEntry {
        @Attribute(.unique) public var id: UUID
        public var topic: Topic?
        public var kind: EntryKind
        public var sortIndex: Int
        /// Text of key statements, rules, examples; unused for terms and tables.
        public var text: String
        public var term: String
        public var definition: String
        public var origin: EntryOrigin
        /// nil for non-AI entries.
        public var supplementStatus: SupplementStatus?
        public var supplementReason: String?
        var tableDataBlob: Data?
        var sourceReferencesBlob: Data
        var highlightBlob: Data?

        public init(
            id: UUID = UUID(), kind: EntryKind, sortIndex: Int = 0, text: String = "",
            term: String = "", definition: String = "", tableData: TableData? = nil,
            origin: EntryOrigin = .user, sourceReferences: [SourceReference] = [],
            highlight: EntryHighlight? = nil, supplementStatus: SupplementStatus? = nil,
            supplementReason: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.sortIndex = sortIndex
            self.text = text
            self.term = term
            self.definition = definition
            self.origin = origin
            self.supplementStatus = supplementStatus
            self.supplementReason = supplementReason
            self.tableDataBlob = tableData.map { JSONBlob.encode($0) }
            self.sourceReferencesBlob = JSONBlob.encode(sourceReferences)
            self.highlightBlob = highlight.map { JSONBlob.encode($0) }
        }

        func decodedTableData() throws -> TableData? {
            try tableDataBlob.map { try JSONBlob.decode(TableData.self, from: $0) }
        }
        func decodedSourceReferences() throws -> [SourceReference] {
            try JSONBlob.decode([SourceReference].self, from: sourceReferencesBlob)
        }
        func decodedHighlight() throws -> EntryHighlight? {
            try highlightBlob.map { try JSONBlob.decode(EntryHighlight.self, from: $0) }
        }
        /// True if all blobs of this entry can be read (edits must not run otherwise).
        var isReadable: Bool {
            do {
                _ = try decodedSourceReferences()
                _ = try decodedTableData()
                _ = try decodedHighlight()
                return true
            } catch {
                return false
            }
        }

        // Readers log failures and return the empty value; writers refuse to overwrite unreadable data.
        public var tableData: TableData? {
            get {
                do { return try decodedTableData() } catch { JSONBlob.log(error, what: "table data"); return nil }
            }
            set {
                guard tableDataBlob == nil || JSONBlob.isReplaceable(tableDataBlob, as: TableData.self) else { return }
                tableDataBlob = newValue.map { JSONBlob.encode($0) }
            }
        }

        public var sourceReferences: [SourceReference] {
            get {
                do { return try decodedSourceReferences() } catch {
                    JSONBlob.log(error, what: "source references"); return []
                }
            }
            set {
                guard JSONBlob.isReplaceable(sourceReferencesBlob, as: [SourceReference].self) else { return }
                sourceReferencesBlob = JSONBlob.encode(newValue)
            }
        }

        public var highlight: EntryHighlight? {
            get {
                do { return try decodedHighlight() } catch { JSONBlob.log(error, what: "entry highlight"); return nil }
            }
            set {
                guard highlightBlob == nil || JSONBlob.isReplaceable(highlightBlob, as: EntryHighlight.self) else { return }
                highlightBlob = newValue.map { JSONBlob.encode($0) }
            }
        }
    }
}

public typealias Subject = SchemaV1.Subject
public typealias ImportBatch = SchemaV1.ImportBatch
public typealias Source = SchemaV1.Source
public typealias Digitization = SchemaV1.Digitization
public typealias LineCorrection = SchemaV1.LineCorrection
public typealias HighlightCorrection = SchemaV1.HighlightCorrection
public typealias Topic = SchemaV1.Topic
public typealias TopicEntry = SchemaV1.TopicEntry

/// Migration plan; add `SchemaV2` and a stage here when the shape changes.
public enum StudyMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum ModelContainerFactory {
    /// Default store: `Application Support/StudyHelper/StudyHelper.store` of the app container.
    public static func defaultStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "StudyHelper", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "StudyHelper.store")
    }

    /// - Parameters:
    ///   - inMemory: throw-away store for tests and previews.
    ///   - url: explicit store location (tests); default is `defaultStoreURL()`.
    @MainActor
    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let storeURL = try url ?? defaultStoreURL()
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: StudyMigrationPlan.self, configurations: [configuration])
    }
}
