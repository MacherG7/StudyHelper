import Foundation
import StudyCore

/// How the digital page shows the stored text (docs/DECISIONS.md D-037).
public enum DigitalPageMode: String, Codable, Hashable, Sendable {
    /// "Handschrift": the original page; the text layer is invisible.
    case handwriting
    /// "Text": the handwriting is hidden and the stored text is drawn visibly at the same place. Sketches, images,
    /// shapes, arrows and highlighter stay.
    case textLayer
}

/// Everything needed to build the digital page of one stored page: the original and its digitization.
public struct DigitalPageInput: Sendable {
    public enum Background: Sendable {
        /// A page of an imported PDF (Goodnotes export, worksheet, scan). `variant` is the stored Goodnotes variant of
        /// the file; nil means unknown (the file is then parsed to find out).
        case pdf(data: Data, pageIndex: Int, variant: GoodnotesVariant?)
        /// A photo or scan: the stored upright image (JPEG, PNG, HEIC …). Its size in pixels is the page size.
        case image(data: Data)
    }

    public var background: Background
    /// The stored lines of the page (with user corrections). Rects are normalized to the displayed page.
    public var lines: [RecognizedLine]
    /// The stored highlights (bold words are drawn bold in text mode; ink shapes keep their strokes).
    public var highlights: [RecognizedHighlight]

    public init(background: Background, lines: [RecognizedLine], highlights: [RecognizedHighlight] = []) {
        self.background = background
        self.lines = lines
        self.highlights = highlights
    }
}

public enum DigitalPageError: Error, Hashable, Sendable, LocalizedError {
    case unreadablePDF
    case pageOutOfRange(pageIndex: Int)
    case unreadableImage
    case renderingFailed

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF: "Das Original-PDF konnte nicht gelesen werden."
        case .pageOutOfRange(let index): "Seite \(index + 1) gibt es im Original-PDF nicht."
        case .unreadableImage: "Das Originalbild konnte nicht gelesen werden."
        case .renderingFailed: "Die digitale Seite konnte nicht erzeugt werden."
        }
    }
}

/// Test knobs of the builder (not part of the app's API).
struct DigitalPageOptions: Sendable {
    /// Text mode only: false leaves out the visible text, so that tests can check what is hidden or painted over.
    var drawsText = true
    /// Pixels per point of the raster that replaces a page with a foreign invisible text layer in the PDF.
    var rasterScale = 3.0
}
