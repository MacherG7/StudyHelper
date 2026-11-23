import CoreGraphics
import Foundation
import StudyCore

// Public entry points of the Goodnotes slice. Signatures are the contract used by
// DigitizationPipeline; the implementations live in the neighbouring files.

public enum GoodnotesParser {
    /// Parses a PDF and detects whether it is an editable or reduced Goodnotes export.
    public static func parse(data: Data) throws -> GoodnotesDocument {
        try GoodnotesPDFReader.read(data: data)
    }

    /// Like `parse(data:)`; rejects `.goodnotes` files with `.goodnotesFileNotSupported`.
    public static func parse(url: URL) throws -> GoodnotesDocument {
        if url.pathExtension.lowercased() == "goodnotes" { throw GoodnotesError.goodnotesFileNotSupported }
        return try GoodnotesPDFReader.read(data: Data(contentsOf: url))
    }
}

public enum GoodnotesPairing {
    /// Two exports belong together if page count and every page size match (user confirms in the UI).
    public static func check(editable: GoodnotesDocument, reduced: GoodnotesDocument) -> GoodnotesPairingCheck {
        guard editable.variant == .editable, reduced.variant == .reduced else { return .wrongVariants }
        guard editable.pages.count == reduced.pages.count else {
            return .pageCountMismatch(editable: editable.pages.count, reduced: reduced.pages.count)
        }
        for (a, b) in zip(editable.pages, reduced.pages) where !a.size.matches(b.size, tolerance: 1) {
            return .pageSizeMismatch(pageIndex: a.index)
        }
        return .compatible
    }
}

public enum InkLayerRenderer {
    /// Distinct pen colors on the page (highlighters excluded), clustered so that
    /// near-identical colors count as one layer. Stable order (by first occurrence).
    public static func penColors(on page: GoodnotesPage) -> [RGBColor] {
        InkLayerRendering.clusters(of: page).map(\.representative)
    }

    /// Renders only the pen strokes of `color` (within the clustering tolerance) in
    /// black on white — no paper, images, shapes, FreeText or highlighter.
    /// `scale` = pixels per PDF point. The image covers the whole page.
    public static func renderLayer(of page: GoodnotesPage, color: RGBColor, scale: Double) -> CGImage? {
        InkLayerRendering.render(page: page, color: color, scale: scale)
    }
}

public enum GoodnotesEmphasisDetector {
    /// Detects emphasis from annotations and stroke shapes, given the recognized lines of the page:
    /// highlighter → words by covered area (incidental touches excluded), underline / double underline /
    /// circle from stroke shape, colored pen per run of non-black words. Exact annotation data is
    /// `.confident`; shape-based results are marked `.uncertain` only if ambiguous.
    public static func detect(page: GoodnotesPage, lines: [RecognizedLine]) -> [RecognizedHighlight] {
        GoodnotesEmphasisDetection.detect(page: page, lines: lines)
    }
}

public enum ReducedPDFComparator {
    /// Cross-checks recognized lines with the reduced PDF's text layer of the same page:
    /// matching words get `.confirmedByReducedPDF`, differing words `.mismatchWithReducedPDF`
    /// and status `.uncertain`. Line status follows its words.
    public static func crossCheck(lines: [RecognizedLine], against reducedPage: GoodnotesPage) -> [RecognizedLine] {
        ReducedPDFComparison.crossCheck(lines: lines, against: reducedPage)
    }
}
