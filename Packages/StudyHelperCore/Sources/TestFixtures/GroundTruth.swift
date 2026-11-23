import CoreGraphics
import Foundation

/// Kind of an element that is listed in the ground truth.
public enum GoodnotesItemKind: String, Codable, Sendable, CaseIterable {
    /// One handwritten word (several Ink annotations, one per outline contour).
    case inkWord
    /// Single long, nearly horizontal Ink stroke under a word or heading.
    case underline
    /// Two parallel Ink strokes under a word.
    case doubleUnderline
    /// One closed Ink stroke around a word.
    case circle
    /// Yellow Ink stroke with large width (about 18 pt) over a word.
    case highlighter
    /// FreeText annotation with exact text in /Contents.
    case freeText
    /// Stamp annotation (shape tool): arrow or line, see `emphasis`.
    case stamp
    /// Ink stroke that is part of a hand-drawn table grid.
    case tableLine
    /// Text run in the page content of an inserted worksheet.
    case worksheetText
    /// Raster image in the page content of an inserted worksheet.
    case image
    /// Recognized word of the invisible text layer of a reduced PDF (may contain deliberate errors).
    case ocrWord
}

/// One element of a page. Coordinates are PDF points, origin bottom-left of the page.
public struct GoodnotesTruthItem: Codable, Equatable, Sendable {
    /// Stable identifier, e.g. `p1-w03`. OCR words use `<inkWordID>-ocr`.
    public var id: String
    public var kind: GoodnotesItemKind
    /// Exact text (words, FreeText contents, worksheet runs; for `ocrWord` the *recognized* text).
    public var text: String?
    /// `#RRGGBB` of the pen / text / stamp color.
    public var colorHex: String?
    /// Stroke width in points (Ink and Stamp), `nil` for text.
    public var lineWidth: Double?
    /// `[x, y, w, h]`. Ink: bounds of all stroke points grown by half the line width.
    public var bbox: [Double]
    /// Number of strokes (Ink contours / lines) the item consists of.
    public var strokeCount: Int
    /// Number of PDF annotations that represent the item. 0 in the reduced (flattened) PDF.
    public var annotationCount: Int
    /// `Ink`, `FreeText` or `Stamp` in the editable PDF; `nil` for page content and in the reduced PDF.
    public var annotationSubtype: String?
    /// Handwritten line this word belongs to, e.g. `p1-line03`.
    public var lineID: String?
    /// Semantic role, e.g. `underline`, `highlight`, `circle`, `arrow`, `line`, `bold`, `colored`.
    public var emphasis: String?
    /// The item this one refers to (highlighter -> covered word, underline -> heading, ocrWord -> ink word).
    /// For several related items this is the first of `relatedItemIDs`.
    public var relatedItemID: String?
    /// Every item this one really belongs to, in reading order: all covered words of a highlighter, all
    /// underlined words of an underline, the single word of a circle / double underline / ocrWord, the arrow or
    /// line target of a stamp. Empty if there is none. Words that a stroke merely touches are *not* listed here
    /// (see `incidentalItemIDs`).
    public var relatedItemIDs: [String] = []
    /// Highlighter only: handwritten words whose bounding box the stroke overlaps slightly without belonging
    /// to them (a "near miss" over a neighbouring word). Never part of `relatedItemIDs`.
    public var incidentalItemIDs: [String] = []
    /// Stamp only: the item the arrow or line starts at.
    public var sourceItemID: String?
    /// Stamp only: `[x1, y1, x2, y2]` start and end of the line (arrow tip at the end).
    public var endpoints: [Double]?
    /// FreeText only: ASCII approximation that the appearance stream draws (the real text is `text`).
    public var appearanceText: String?

    public var rect: CGRect {
        CGRect(x: bbox[0], y: bbox[1], width: bbox[2], height: bbox[3])
    }
}

public struct GoodnotesTruthPage: Codable, Equatable, Sendable {
    /// 1-based page number.
    public var pageNumber: Int
    public var items: [GoodnotesTruthItem]
}

/// A deliberate recognition error in the text layer of a reduced PDF.
public struct GoodnotesOCRError: Codable, Equatable, Sendable {
    public var page: Int
    /// ID of the `ocrWord` item.
    public var itemID: String
    /// ID of the handwritten word.
    public var inkWordID: String
    /// What was really written.
    public var truth: String
    /// What the text layer contains.
    public var recognized: String
}

/// Ground truth of one synthetic fixture PDF (`<name>.truth.json`).
public struct GoodnotesGroundTruth: Codable, Equatable, Sendable {
    /// File name of the PDF this truth belongs to.
    public var fileName: String
    /// `editable` or `reduced`.
    public var variant: String
    public var generator: String
    /// PostScript name of the font whose outlines form the synthetic handwriting.
    public var handwritingFont: String
    /// Version string (CoreText `kCTFontVersionNameKey`) of that font. Together with `handwritingFont` this is
    /// the identity of the outlines: if it changes, the generated bytes may legitimately change.
    public var handwritingFontVersion: String
    public var pageCount: Int
    public var pageWidth: Double
    public var pageHeight: Double
    public var pages: [GoodnotesTruthPage]
    /// Deliberate recognition errors (reduced PDFs only, otherwise empty).
    public var ocrErrors: [GoodnotesOCRError]

    public func items(ofKind kind: GoodnotesItemKind, onPage page: Int? = nil) -> [GoodnotesTruthItem] {
        pages.filter { page == nil || $0.pageNumber == page }
            .flatMap(\.items)
            .filter { $0.kind == kind }
    }

    public func item(withID id: String) -> GoodnotesTruthItem? {
        pages.flatMap(\.items).first { $0.id == id }
    }

    /// Sum of `annotationCount` per page (1-based index = page number).
    public func annotationCount(onPage page: Int) -> Int {
        pages.first { $0.pageNumber == page }?.items.reduce(0) { $0 + $1.annotationCount } ?? 0
    }

    /// Stable encoding: sorted keys, pretty printed, trailing newline.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(from data: Data) throws -> GoodnotesGroundTruth {
        try JSONDecoder().decode(GoodnotesGroundTruth.self, from: data)
    }
}
