import Foundation

// Developer-mode recognition error reports (format "studyhelper-recognition-report", version 1).
// The user marks wrong text, missing text, wrong order etc. at an exact place on a page; reports are exported
// as JSON (file) or as compact German chat text, and read on the Mac by scripts/recognition-reports.py.
// Platform-neutral model + JSON coding; storage and UI live in the app.

/// What kind of recognition error was reported.
public enum RecognitionReportKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Text was recognized, but wrongly.
    case misread
    /// Text on the page was not recognized at all.
    case missing
    /// Reading order is wrong.
    case order
    /// Lines wrongly split or wrongly merged.
    case split
    /// Highlight/underline wrongly detected, missing or wrongly assigned.
    case highlight
    case other

    /// German display name.
    public var displayName: String {
        switch self {
        case .misread: "Falsch gelesen"
        case .missing: "Fehlt"
        case .order: "Reihenfolge falsch"
        case .split: "Falsch getrennt/zusammengefügt"
        case .highlight: "Hervorhebung falsch"
        case .other: "Sonstiges"
        }
    }

    /// Unknown future kinds map to `.other`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecognitionReportKind(rawValue: raw) ?? .other
    }
}

/// Where an entry came from.
public enum RecognitionReportSource: String, Codable, Hashable, Sendable {
    /// Reported explicitly by the user.
    case report
    /// Derived from a text correction the user made in the review view.
    case correction

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecognitionReportSource(rawValue: raw) ?? .report
    }
}

/// Errors when reading a report file; messages are German.
public enum RecognitionReportError: Error, Equatable, LocalizedError, Sendable {
    case wrongFormat(String?)
    case unsupportedVersion(Int?)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .wrongFormat(let found):
            "Das ist keine StudyHelper-Fehlerdatei (Format „\(found ?? "unbekannt")“)."
        case .unsupportedVersion(let version):
            "Die Fehlerdatei hat Version \(version.map(String.init) ?? "unbekannt"); diese Version der App oder des Skripts kennt nur Version \(RecognitionReport.currentVersion)."
        case .unreadable(let detail):
            "Die Fehlerdatei konnte nicht gelesen werden: \(detail)"
        }
    }
}

/// JSON helpers shared by the report types.
enum RecognitionReportCoding {
    /// userInfo flag: leave out nil values instead of writing `null` (compact chat form).
    static let omitNullsKey = CodingUserInfoKey(rawValue: "studyhelper.recognitionReport.omitNulls")!

    static func omitNulls(_ encoder: Encoder) -> Bool {
        (encoder.userInfo[omitNullsKey] as? Bool) ?? false
    }

    static func encode<T: Encodable, K: CodingKey>(
        _ value: T?, forKey key: K, in c: inout KeyedEncodingContainer<K>, omitNulls: Bool
    ) throws {
        if let value {
            try c.encode(value, forKey: key)
        } else if !omitNulls {
            try c.encodeNil(forKey: key)
        }
    }
}

/// One line of the page as the recognizer produced it.
public struct RecognitionReportLine: Codable, Hashable, Sendable {
    public var id: UUID
    /// Reading order on the page (0-based).
    public var order: Int
    public var text: String
    public var rect: NormalizedRect

    public init(id: UUID, order: Int, text: String, rect: NormalizedRect) {
        self.id = id
        self.order = order
        self.text = text
        self.rect = rect
    }

    public init(_ line: RecognizedLine, text: String? = nil) {
        self.init(id: line.id, order: line.order, text: text ?? line.text, rect: line.rect)
    }

    private enum CodingKeys: String, CodingKey {
        case id, order, text, rect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        rect = try c.decodeIfPresent(NormalizedRect.self, forKey: .rect) ?? .zero
    }
}

/// Texts of the lines before and after the reported place (reading order).
public struct RecognitionReportContext: Codable, Hashable, Sendable {
    public var before: String?
    public var after: String?

    public init(before: String? = nil, after: String? = nil) {
        self.before = before
        self.after = after
    }

    private enum CodingKeys: String, CodingKey {
        case before, after
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decodeIfPresent(String.self, forKey: .before)
        after = try c.decodeIfPresent(String.self, forKey: .after)
    }

    public func encode(to encoder: Encoder) throws {
        let omit = RecognitionReportCoding.omitNulls(encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try RecognitionReportCoding.encode(before, forKey: .before, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(after, forKey: .after, in: &c, omitNulls: omit)
    }
}

/// App/device the report was created on.
public struct RecognitionReportApp: Codable, Hashable, Sendable {
    public var version: String
    public var commit: String?
    /// "iOS 27.2"
    public var os: String?
    /// Hardware identifier, e.g. "iPhone17,1".
    public var device: String?

    public init(version: String, commit: String? = nil, os: String? = nil, device: String? = nil) {
        self.version = version
        self.commit = commit
        self.os = os
        self.device = device
    }

    private enum CodingKeys: String, CodingKey {
        case version, commit, os, device
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        os = try c.decodeIfPresent(String.self, forKey: .os)
        device = try c.decodeIfPresent(String.self, forKey: .device)
    }

    public func encode(to encoder: Encoder) throws {
        let omit = RecognitionReportCoding.omitNulls(encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try RecognitionReportCoding.encode(commit, forKey: .commit, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(os, forKey: .os, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(device, forKey: .device, in: &c, omitNulls: omit)
    }
}

/// A source (file) that entries refer to.
public struct RecognitionReportImport: Codable, Hashable, Sendable {
    public var id: UUID
    public var fileName: String
    /// "pdf" or "image" (free text, lenient).
    public var kind: String
    /// `GoodnotesVariant` raw value ("editable", "reduced", "other") or nil.
    public var goodnotesVariant: String?
    public var pageCount: Int?

    public init(id: UUID, fileName: String, kind: String, goodnotesVariant: String? = nil, pageCount: Int? = nil) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.goodnotesVariant = goodnotesVariant
        self.pageCount = pageCount
    }

    public init(id: UUID, fileName: String, kind: String, variant: GoodnotesVariant?, pageCount: Int?) {
        self.init(id: id, fileName: fileName, kind: kind, goodnotesVariant: variant?.rawValue, pageCount: pageCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, kind, goodnotesVariant, pageCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        goodnotesVariant = try c.decodeIfPresent(String.self, forKey: .goodnotesVariant)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
    }

    public func encode(to encoder: Encoder) throws {
        let omit = RecognitionReportCoding.omitNulls(encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(kind, forKey: .kind)
        try RecognitionReportCoding.encode(goodnotesVariant, forKey: .goodnotesVariant, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(pageCount, forKey: .pageCount, in: &c, omitNulls: omit)
    }

    /// German description of the source type, e.g. "Goodnotes bearbeitbar", "PDF", "Foto".
    public var kindDisplayName: String {
        switch goodnotesVariant {
        case GoodnotesVariant.editable.rawValue: return "Goodnotes bearbeitbar"
        case GoodnotesVariant.reduced.rawValue: return "Goodnotes reduziert"
        default: break
        }
        switch kind.lowercased() {
        case "pdf": return "PDF"
        case "image", "photo": return "Foto"
        case "": return "Quelle"
        default: return kind
        }
    }
}

/// One reported recognition error.
public struct RecognitionReportEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var importID: UUID
    /// 1-based page number.
    public var page: Int
    /// Page size in points (PDF) or pixels (image).
    public var pageSize: PageSize
    /// Union of the lines, or the drawn area for `missing`. Normalized, origin top-left.
    public var rect: NormalizedRect
    public var kind: RecognitionReportKind
    public var recognized: String?
    public var expected: String?
    public var note: String?
    public var lines: [RecognitionReportLine]
    /// For kind `order`: the line the reported line belongs after.
    public var after: RecognitionReportLine?
    public var context: RecognitionReportContext
    public var source: RecognitionReportSource
    /// `RecognitionMethod` raw value, e.g. "goodnotesInkLayers".
    public var method: String?
    public var engine: String?
    /// JPEG of the page area (optional).
    public var imageJPEG: Data?

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), importID: UUID, page: Int, pageSize: PageSize,
        rect: NormalizedRect, kind: RecognitionReportKind, recognized: String? = nil, expected: String? = nil,
        note: String? = nil, lines: [RecognitionReportLine] = [], after: RecognitionReportLine? = nil,
        context: RecognitionReportContext = RecognitionReportContext(),
        source: RecognitionReportSource = .report, method: String? = nil, engine: String? = nil,
        imageJPEG: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.importID = importID
        self.page = page
        self.pageSize = pageSize
        self.rect = rect
        self.kind = kind
        self.recognized = recognized
        self.expected = expected
        self.note = note
        self.lines = lines
        self.after = after
        self.context = context
        self.source = source
        self.method = method
        self.engine = engine
        self.imageJPEG = imageJPEG
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, importID, page, pageSize, rect, kind, recognized, expected, note
        case lines, after, context, source, method, engine, imageJPEGBase64
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        importID = try c.decodeIfPresent(UUID.self, forKey: .importID)
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 1
        pageSize = try c.decodeIfPresent(PageSize.self, forKey: .pageSize) ?? PageSize(width: 0, height: 0)
        rect = try c.decodeIfPresent(NormalizedRect.self, forKey: .rect) ?? .zero
        kind = try c.decodeIfPresent(RecognitionReportKind.self, forKey: .kind) ?? .other
        recognized = try c.decodeIfPresent(String.self, forKey: .recognized)
        expected = try c.decodeIfPresent(String.self, forKey: .expected)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        lines = try c.decodeIfPresent([RecognitionReportLine].self, forKey: .lines) ?? []
        after = try c.decodeIfPresent(RecognitionReportLine.self, forKey: .after)
        context = try c.decodeIfPresent(RecognitionReportContext.self, forKey: .context) ?? RecognitionReportContext()
        source = try c.decodeIfPresent(RecognitionReportSource.self, forKey: .source) ?? .report
        method = try c.decodeIfPresent(String.self, forKey: .method)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        if let base64 = try c.decodeIfPresent(String.self, forKey: .imageJPEGBase64) {
            imageJPEG = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        } else {
            imageJPEG = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        let omit = RecognitionReportCoding.omitNulls(encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(importID, forKey: .importID)
        try c.encode(page, forKey: .page)
        try c.encode(pageSize, forKey: .pageSize)
        try c.encode(rect, forKey: .rect)
        try c.encode(kind, forKey: .kind)
        try RecognitionReportCoding.encode(recognized, forKey: .recognized, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(expected, forKey: .expected, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(note, forKey: .note, in: &c, omitNulls: omit)
        try c.encode(lines, forKey: .lines)
        try RecognitionReportCoding.encode(after, forKey: .after, in: &c, omitNulls: omit)
        try c.encode(context, forKey: .context)
        try c.encode(source, forKey: .source)
        try RecognitionReportCoding.encode(method, forKey: .method, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(engine, forKey: .engine, in: &c, omitNulls: omit)
        try RecognitionReportCoding.encode(
            imageJPEG?.base64EncodedString(), forKey: .imageJPEGBase64, in: &c, omitNulls: omit)
    }

    /// A copy without the page image.
    public var withoutImage: RecognitionReportEntry {
        var copy = self
        copy.imageJPEG = nil
        return copy
    }

    // MARK: Building entries

    /// Builds an entry from the lines the user selected.
    ///
    /// - `rect` is the union of the selected lines; `drawnRect` is used when no line is selected (kind `missing`).
    /// - `recognized` is the selected lines' texts joined with "\n" in reading order.
    /// - `context` holds the texts of the line before/after the selection in reading order (from `allLines`).
    /// - `after` is only kept for kind `order`.
    public static func make(
        importID: UUID, page: Int, pageSize: PageSize, selectedLines: [RecognizedLine],
        allLines: [RecognizedLine], kind: RecognitionReportKind, expected: String? = nil, note: String? = nil,
        after afterLine: RecognizedLine? = nil, drawnRect: NormalizedRect? = nil,
        method: RecognitionMethod? = nil, engine: String? = nil, imageJPEG: Data? = nil,
        id: UUID = UUID(), createdAt: Date = Date()
    ) -> RecognitionReportEntry {
        let selected = selectedLines.sorted { $0.order < $1.order }
        let rect: NormalizedRect
        if let first = selected.first {
            rect = selected.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        } else {
            rect = drawnRect ?? .zero
        }
        return RecognitionReportEntry(
            id: id, createdAt: createdAt, importID: importID, page: page, pageSize: pageSize, rect: rect,
            kind: kind, recognized: selected.isEmpty ? nil : selected.map(\.text).joined(separator: "\n"),
            expected: expected, note: note, lines: selected.map { RecognitionReportLine($0) },
            after: kind == .order ? afterLine.map { RecognitionReportLine($0) } : nil,
            context: context(around: selected, in: allLines), source: .report,
            method: method?.rawValue, engine: engine, imageJPEG: imageJPEG)
    }

    /// One `misread` entry (source `correction`) per line the user corrected to a different text.
    public static func corrections(
        from lines: [RecognizedLine], importID: UUID, page: Int, pageSize: PageSize,
        method: RecognitionMethod? = nil, engine: String? = nil, createdAt: Date = Date()
    ) -> [RecognitionReportEntry] {
        lines.sorted { $0.order < $1.order }.compactMap { line in
            guard line.isUserCorrected, let recognized = line.recognizedText, recognized != line.text else { return nil }
            return RecognitionReportEntry(
                createdAt: createdAt, importID: importID, page: page, pageSize: pageSize, rect: line.rect,
                kind: .misread, recognized: recognized, expected: line.text, note: nil,
                lines: [RecognitionReportLine(line, text: recognized)], after: nil,
                context: context(around: [line], in: lines), source: .correction,
                method: method?.rawValue, engine: engine)
        }
    }

    /// Texts of the line directly before the first and after the last selected line (reading order).
    static func context(around selected: [RecognizedLine], in allLines: [RecognizedLine]) -> RecognitionReportContext {
        guard let minOrder = selected.map(\.order).min(), let maxOrder = selected.map(\.order).max() else {
            return RecognitionReportContext()
        }
        let selectedIDs = Set(selected.map(\.id))
        let others = allLines.filter { !selectedIDs.contains($0.id) }
        let before = others.filter { $0.order < minOrder }.max { $0.order < $1.order }
        let after = others.filter { $0.order > maxOrder }.min { $0.order < $1.order }
        return RecognitionReportContext(before: before?.text, after: after?.text)
    }
}

/// A complete report file.
public struct RecognitionReport: Codable, Hashable, Sendable {
    public static let formatIdentifier = "studyhelper-recognition-report"
    public static let currentVersion = 1

    public var createdAt: Date
    public var app: RecognitionReportApp
    public var imports: [RecognitionReportImport]
    public var entries: [RecognitionReportEntry]

    public init(
        createdAt: Date = Date(), app: RecognitionReportApp, imports: [RecognitionReportImport] = [],
        entries: [RecognitionReportEntry] = []
    ) {
        self.createdAt = createdAt
        self.app = app
        self.imports = imports
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, createdAt, app, imports, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decodeIfPresent(String.self, forKey: .format)
        guard format == Self.formatIdentifier else { throw RecognitionReportError.wrongFormat(format) }
        let version = try c.decodeIfPresent(Int.self, forKey: .version)
        guard let version, version >= 1, version <= Self.currentVersion else {
            throw RecognitionReportError.unsupportedVersion(version)
        }
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        app = try c.decodeIfPresent(RecognitionReportApp.self, forKey: .app) ?? RecognitionReportApp(version: "")
        imports = try c.decodeIfPresent([RecognitionReportImport].self, forKey: .imports) ?? []
        entries = try c.decodeIfPresent([RecognitionReportEntry].self, forKey: .entries) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatIdentifier, forKey: .format)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(app, forKey: .app)
        try c.encode(imports, forKey: .imports)
        try c.encode(entries, forKey: .entries)
    }

    // MARK: JSON

    static func makeEncoder(pretty: Bool, omitNulls: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle()))
        }
        encoder.userInfo[RecognitionReportCoding.omitNullsKey] = omitNulls
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let string = try c.decode(String.self)
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) { return date }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ungültiges Datum „\(string)“")
        }
        return decoder
    }

    /// Pretty-printed JSON with sorted keys, slashes unescaped, dates in UTC ("…Z").
    public func encodedJSON() throws -> Data {
        try Self.makeEncoder(pretty: true).encode(self)
    }

    /// Reads a report; rejects a wrong `format` or a `version` above 1 with a German error.
    public static func decode(from data: Data) throws -> RecognitionReport {
        do {
            return try makeDecoder().decode(RecognitionReport.self, from: data)
        } catch let error as RecognitionReportError {
            throw error
        } catch {
            throw RecognitionReportError.unreadable(error.localizedDescription)
        }
    }
}
