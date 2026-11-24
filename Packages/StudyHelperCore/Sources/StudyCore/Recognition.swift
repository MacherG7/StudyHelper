import Foundation

// Shared result types of the digitization step. Every recognizer (Vision,
// embedded PDF text, Goodnotes FreeText, later AI transcription) produces these;
// StudyData persists them and the UI shows them. Rects use `NormalizedRect`
// (page fractions, origin top-left).

/// How sure the app is about a piece of recognized text.
public enum ConfidenceStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// sicher
    case confident
    /// unsicher – needs a look by the user
    case uncertain
    /// unleserlich – must be corrected by the user, never guessed
    case illegible
}

/// Why a word or line was flagged for review.
public enum ReviewReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// Recognizer confidence below the threshold.
    case lowConfidence
    /// Different results between recognition passes (multi-pass mode).
    case variesBetweenPasses
    /// Differs from the text layer of the reduced Goodnotes PDF.
    case mismatchWithReducedPDF
    /// Agrees with the reduced Goodnotes PDF (not a problem; recorded for transparency).
    case confirmedByReducedPDF
    /// Recognizer could not read it at all.
    case unreadable
    /// Read only in a second pass on a cut-out part of the page ("Nachlesen"); the first pass had skipped or
    /// merged it, so the user should check it.
    case reReadSeparately
}

/// Semantic block a line belongs to, when the recognizer knows it (iOS 26 document API, embedded text).
public enum LineBlockKind: String, Codable, Hashable, Sendable {
    case paragraph
    case listItem
    case tableCell
    case title
}

public struct RecognizedWord: Codable, Hashable, Sendable {
    public var text: String
    public var rect: NormalizedRect
    /// 0…1
    public var confidence: Double
    /// Pen/text color if known (Goodnotes color layers, embedded PDF text).
    public var color: RGBColor?
    public var status: ConfidenceStatus
    public var reviewReasons: [ReviewReason]

    public init(
        text: String, rect: NormalizedRect, confidence: Double = 1,
        color: RGBColor? = nil, status: ConfidenceStatus = .confident,
        reviewReasons: [ReviewReason] = []
    ) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.color = color
        self.status = status
        self.reviewReasons = reviewReasons
    }

    /// True if the user should look at this word.
    public var needsReview: Bool {
        status != .confident
    }

    // Persisted as JSON: every field except the identity (text, rect) is read leniently,
    // so that blobs written by older versions keep decoding when fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        color = try c.decodeIfPresent(RGBColor.self, forKey: .color)
        status = try c.decodeIfPresent(ConfidenceStatus.self, forKey: .status) ?? .confident
        reviewReasons = try c.decodeIfPresent([ReviewReason].self, forKey: .reviewReasons) ?? []
    }
}

public struct RecognizedLine: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var rect: NormalizedRect
    /// 0…1
    public var confidence: Double
    /// Alternative readings from the recognizer, best first, excluding `text`.
    public var candidates: [String]
    public var words: [RecognizedWord]
    public var status: ConfidenceStatus
    public var reviewReasons: [ReviewReason]
    /// Dominant color of the line, if known.
    public var color: RGBColor?
    public var blockKind: LineBlockKind?
    /// Reading order on the page as in the original (0-based).
    public var order: Int
    /// Text was set by the user; takes precedence over any automatic recognition.
    public var isUserCorrected: Bool
    /// Raw automatic text, kept when a correction replaced `text` (nil = never corrected).
    /// Needed for per-method comparisons and error rates (SPEC §10).
    public var recognizedText: String?
    /// Lines with the same id form one paragraph (consecutive rows of one text, see `ParagraphGrouping`).
    /// nil: not grouped (digitized before paragraphs existed); such a line is a paragraph of its own.
    public var paragraphID: UUID?

    public init(
        id: UUID = UUID(), text: String, rect: NormalizedRect, confidence: Double = 1,
        candidates: [String] = [], words: [RecognizedWord] = [],
        status: ConfidenceStatus = .confident, reviewReasons: [ReviewReason] = [],
        color: RGBColor? = nil, blockKind: LineBlockKind? = nil, order: Int = 0,
        isUserCorrected: Bool = false, recognizedText: String? = nil, paragraphID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.paragraphID = paragraphID
        self.candidates = candidates
        self.words = words
        self.status = status
        self.reviewReasons = reviewReasons
        self.color = color
        self.blockKind = blockKind
        self.order = order
        self.isUserCorrected = isUserCorrected
        self.recognizedText = recognizedText
    }

    /// The text as the automatic recognition produced it (before any correction).
    public var automaticText: String { recognizedText ?? text }

    /// True if the line or any of its words should be reviewed by the user.
    public var needsReview: Bool {
        !isUserCorrected && (status != .confident || words.contains(where: \.needsReview))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        candidates = try c.decodeIfPresent([String].self, forKey: .candidates) ?? []
        words = try c.decodeIfPresent([RecognizedWord].self, forKey: .words) ?? []
        status = try c.decodeIfPresent(ConfidenceStatus.self, forKey: .status) ?? .confident
        reviewReasons = try c.decodeIfPresent([ReviewReason].self, forKey: .reviewReasons) ?? []
        color = try c.decodeIfPresent(RGBColor.self, forKey: .color)
        blockKind = try c.decodeIfPresent(LineBlockKind.self, forKey: .blockKind)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isUserCorrected = try c.decodeIfPresent(Bool.self, forKey: .isUserCorrected) ?? false
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText)
        paragraphID = try c.decodeIfPresent(UUID.self, forKey: .paragraphID)
    }
}

/// Kind of emphasis (SPEC §2 "Hervorhebungen").
public enum HighlightKind: String, Codable, Hashable, Sendable, CaseIterable {
    case underline
    case doubleUnderline
    case bold
    case coloredPen
    case highlighter
    case boxed
    case circled
    case uppercase
}

/// Suggested meaning of a highlight; the user can change it.
public enum HighlightMeaning: String, Codable, Hashable, Sendable, CaseIterable {
    case heading
    case term
    case definition
    /// Merksatz
    case rule
    case formula
    case important
}

/// Where a highlight (or line) came from.
public enum DetectionSource: String, Codable, Hashable, Sendable {
    /// Exact data from Goodnotes annotations (colors, highlighter) or shape analysis of ink strokes.
    case goodnotesAnnotation
    case goodnotesShape
    /// Formatting of embedded PDF text.
    case embeddedPDF
    /// Pixel analysis of photos/scans (Phase 3).
    case imageAnalysis
    /// AI transcription (Phase 3).
    case aiTranscription
    case user
}

/// Points at one word: line id + index into `RecognizedLine.words`.
public struct WordReference: Codable, Hashable, Sendable {
    public var lineID: UUID
    public var wordIndex: Int

    public init(lineID: UUID, wordIndex: Int) {
        self.lineID = lineID
        self.wordIndex = wordIndex
    }
}

public struct RecognizedHighlight: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The highlighted text (words joined by spaces).
    public var text: String
    public var kind: HighlightKind
    public var color: RGBColor?
    /// Area of the highlight mark itself (stroke, highlighter area, circle) on the page.
    public var rect: NormalizedRect
    /// 0…1
    public var confidence: Double
    /// Shape/pixel analysis results are `.uncertain`; exact annotation data is `.confident`.
    public var status: ConfidenceStatus
    public var suggestedMeaning: HighlightMeaning?
    public var source: DetectionSource
    /// The words this highlight belongs to.
    public var words: [WordReference]
    /// Id of the user correction (`HighlightCorrectionValue.id`) that created or changed
    /// this highlight; nil for untouched automatic highlights.
    public var correctionID: UUID?

    public init(
        id: UUID = UUID(), text: String, kind: HighlightKind, color: RGBColor? = nil,
        rect: NormalizedRect, confidence: Double = 1, status: ConfidenceStatus = .confident,
        suggestedMeaning: HighlightMeaning? = nil, source: DetectionSource,
        words: [WordReference] = [], correctionID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.color = color
        self.rect = rect
        self.confidence = confidence
        self.status = status
        self.suggestedMeaning = suggestedMeaning
        self.source = source
        self.words = words
        self.correctionID = correctionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try c.decode(HighlightKind.self, forKey: .kind)
        color = try c.decodeIfPresent(RGBColor.self, forKey: .color)
        rect = try c.decode(NormalizedRect.self, forKey: .rect)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        status = try c.decodeIfPresent(ConfidenceStatus.self, forKey: .status) ?? .confident
        suggestedMeaning = try c.decodeIfPresent(HighlightMeaning.self, forKey: .suggestedMeaning)
        source = try c.decodeIfPresent(DetectionSource.self, forKey: .source) ?? .user
        words = try c.decodeIfPresent([WordReference].self, forKey: .words) ?? []
        correctionID = try c.decodeIfPresent(UUID.self, forKey: .correctionID)
    }
}

/// How a source was digitized.
public enum RecognitionMethod: String, Codable, Hashable, Sendable {
    /// VNRecognizeTextRequest (accurate).
    case vision
    /// RecognizeDocumentsRequest (iOS 26+), structure-aware.
    case visionDocument
    /// Text taken directly from the PDF's text layer.
    case embeddedPDFText
    /// Goodnotes: Vision per ink color layer + FreeText + annotations.
    case goodnotesInkLayers
    /// AI transcription (Phase 3).
    case aiModel
    case manual
}

/// Provenance of a digitization, stored per recognition (SPEC §2).
public struct RecognitionMetadata: Codable, Hashable, Sendable {
    public var method: RecognitionMethod
    /// E.g. Vision request revision ("3"), or model name for AI.
    public var engineVersion: String?
    public var modelName: String?
    /// "iOS 27.2" / "macOS 27.0"
    public var osVersion: String
    /// Hardware model identifier, e.g. "iPhone17,1".
    public var deviceModel: String
    public var date: Date
    /// Number of recognition passes (multi-pass mode = 2).
    public var passes: Int
    public var customWordsCount: Int
    /// Reduced Goodnotes PDF was used for cross-checking.
    public var usedReducedPDF: Bool

    public init(
        method: RecognitionMethod, engineVersion: String? = nil, modelName: String? = nil,
        osVersion: String, deviceModel: String, date: Date = Date(), passes: Int = 1,
        customWordsCount: Int = 0, usedReducedPDF: Bool = false
    ) {
        self.method = method
        self.engineVersion = engineVersion
        self.modelName = modelName
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.date = date
        self.passes = passes
        self.customWordsCount = customWordsCount
        self.usedReducedPDF = usedReducedPDF
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(RecognitionMethod.self, forKey: .method)
        engineVersion = try c.decodeIfPresent(String.self, forKey: .engineVersion)
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? ""
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSinceReferenceDate: 0)
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        customWordsCount = try c.decodeIfPresent(Int.self, forKey: .customWordsCount) ?? 0
        usedReducedPDF = try c.decodeIfPresent(Bool.self, forKey: .usedReducedPDF) ?? false
    }
}

/// Complete digitization of one source (page or image).
public struct DigitizationResult: Codable, Hashable, Sendable {
    public var lines: [RecognizedLine]
    public var highlights: [RecognizedHighlight]
    public var metadata: RecognitionMetadata
    /// Original text as Markdown, verbatim and in the order of the original (see `OriginalTextMarkdown`).
    public var originalMarkdown: String
    /// Size of the source in points (PDF) or pixels (image).
    public var pageSize: PageSize
    /// Non-fatal problems, in German, shown to the user (e.g. "Seite enthält keine Handschrift").
    public var warnings: [String]

    public init(
        lines: [RecognizedLine], highlights: [RecognizedHighlight], metadata: RecognitionMetadata,
        originalMarkdown: String, pageSize: PageSize, warnings: [String] = []
    ) {
        self.lines = lines
        self.highlights = highlights
        self.metadata = metadata
        self.originalMarkdown = originalMarkdown
        self.pageSize = pageSize
        self.warnings = warnings
    }

    /// The text as paragraphs: lines that belong together joined, with their position (see `ParagraphGrouping`).
    public var paragraphs: [TextParagraph] { ParagraphGrouping.paragraphs(of: lines) }

    /// Number of lines that still need the user's attention.
    public var openReviewCount: Int {
        lines.filter(\.needsReview).count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decodeIfPresent([RecognizedLine].self, forKey: .lines) ?? []
        highlights = try c.decodeIfPresent([RecognizedHighlight].self, forKey: .highlights) ?? []
        metadata = try c.decode(RecognitionMetadata.self, forKey: .metadata)
        originalMarkdown = try c.decodeIfPresent(String.self, forKey: .originalMarkdown) ?? ""
        pageSize = try c.decode(PageSize.self, forKey: .pageSize)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}
