import Foundation
import StudyCore

// Persisted enums and small Codable value types. Raw values are stable storage
// keys: never rename a case without a migration.

public enum ImportKind: String, Codable, Hashable, Sendable, CaseIterable {
    case photo, scan, pdf, goodnotes
}

public enum DigitizationState: String, Codable, Hashable, Sendable {
    /// Waiting for (re-)recognition.
    case pending
    case done
    /// Recognition failed; the German message is in `Source.digitizationError`.
    case failed
}

public enum TopicOrigin: String, Codable, Hashable, Sendable {
    case manual, ai, mixed
}

public enum EntryKind: String, Codable, Hashable, Sendable, CaseIterable {
    case keyStatement
    case term
    /// Formula, rule or Merksatz.
    case rule
    case example
    case table
}

public enum EntryOrigin: String, Codable, Hashable, Sendable {
    /// Taken from the learning material.
    case original
    /// Typed by the user.
    case user
    case aiSupplement
}

public enum SupplementStatus: String, Codable, Hashable, Sendable {
    case proposed, accepted, rejected
}

/// Structured table content of a `.table` entry.
public struct TableData: Codable, Hashable, Sendable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String] = [], rows: [[String]] = []) {
        self.headers = headers
        self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headers = try c.decodeIfPresent([String].self, forKey: .headers) ?? []
        rows = try c.decodeIfPresent([[String]].self, forKey: .rows) ?? []
    }
}

/// Points from a topic entry back to the original source position.
public struct SourceReference: Codable, Hashable, Sendable {
    public var sourceID: UUID
    public var lineIDs: [UUID]
    public var rect: NormalizedRect?
    /// Digitization version the line ids were taken from (informational: line ids are
    /// carried over between versions, but this keeps a reference interpretable).
    public var digitizationID: UUID?
    public var digitizationVersion: Int?
    /// Joined text of the referenced lines as it was when the entry was taken over (or when the user last
    /// confirmed a change of the source). Compared with the current text to detect "Quelle geändert".
    /// nil for references created without a snapshot.
    public var snapshotText: String?
    /// The emphasis on the referenced lines at that time (see `snapshotText`).
    public var snapshotHighlights: [EntryHighlight]?

    public init(
        sourceID: UUID, lineIDs: [UUID] = [], rect: NormalizedRect? = nil,
        digitizationID: UUID? = nil, digitizationVersion: Int? = nil,
        snapshotText: String? = nil, snapshotHighlights: [EntryHighlight]? = nil
    ) {
        self.sourceID = sourceID
        self.lineIDs = lineIDs
        self.rect = rect
        self.digitizationID = digitizationID
        self.digitizationVersion = digitizationVersion
        self.snapshotText = snapshotText
        self.snapshotHighlights = snapshotHighlights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        lineIDs = try c.decodeIfPresent([UUID].self, forKey: .lineIDs) ?? []
        rect = try c.decodeIfPresent(NormalizedRect.self, forKey: .rect)
        digitizationID = try c.decodeIfPresent(UUID.self, forKey: .digitizationID)
        digitizationVersion = try c.decodeIfPresent(Int.self, forKey: .digitizationVersion)
        snapshotText = try c.decodeIfPresent(String.self, forKey: .snapshotText)
        snapshotHighlights = try c.decodeIfPresent([EntryHighlight].self, forKey: .snapshotHighlights)
    }
}

/// Whether (and how) the content was emphasized in the original.
public struct EntryHighlight: Codable, Hashable, Sendable {
    public var kind: HighlightKind
    public var color: RGBColor?

    public init(kind: HighlightKind, color: RGBColor? = nil) {
        self.kind = kind
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(HighlightKind.self, forKey: .kind)
        color = try c.decodeIfPresent(RGBColor.self, forKey: .color)
    }
}

/// User-facing (German) errors of the data layer.
public enum StudyDataError: Error, LocalizedError, Equatable {
    case emptyName
    case emptyTopicTitle
    case noCurrentDigitization
    case lineNotFound
    case highlightNotFound
    case entryNotInTopic
    case differentSubjects
    case sameTopic
    case noWordsSelected
    /// Only a source waiting for (re-)recognition can receive a new digitization.
    case digitizationNotPending
    /// Stored data could not be read; nothing was changed or overwritten.
    case damagedData
    /// Stored data was written by a newer app version; nothing was changed.
    case dataFromNewerVersion

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Der Name darf nicht leer sein."
        case .emptyTopicTitle: "Ein Thema braucht einen Titel."
        case .noCurrentDigitization: "Diese Seite wurde noch nicht digitalisiert."
        case .lineNotFound: "Die Zeile wurde nicht gefunden."
        case .highlightNotFound: "Die Hervorhebung wurde nicht gefunden."
        case .entryNotInTopic: "Der Eintrag gehört nicht zu diesem Thema."
        case .differentSubjects: "Themen aus verschiedenen Fächern können nicht zusammengelegt werden."
        case .sameTopic: "Ein Thema kann nicht mit sich selbst zusammengelegt werden."
        case .noWordsSelected: "Es sind keine Wörter ausgewählt."
        case .digitizationNotPending:
            "Diese Seite wurde bereits digitalisiert. Sie kann nur über „Neu erkennen“ erneut erkannt werden."
        case .damagedData:
            "Gespeicherte Daten sind beschädigt und können nicht gelesen werden. Es wurde nichts verändert."
        case .dataFromNewerVersion:
            "Die gespeicherten Daten stammen aus einer neueren Version der App. Es wurde nichts verändert."
        }
    }
}
