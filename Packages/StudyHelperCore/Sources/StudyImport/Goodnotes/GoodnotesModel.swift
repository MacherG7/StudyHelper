import CoreGraphics
import Foundation
import StudyCore

// Contract for everything Goodnotes-specific. The signatures in this file are
// used by the digitization pipeline; keep them stable.

/// A point in PDF user space (points, origin bottom-left).
public struct PDFPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One pen stroke = one Ink annotation (one `/InkList` entry).
public struct InkStroke: Hashable, Sendable {
    public var points: [PDFPoint]
    public var color: RGBColor
    /// `/BS /W` in points.
    public var width: Double
    /// `/NM`, if present.
    public var name: String?
    /// Stroke opacity (`/CA` of the annotation or of its appearance's graphics state), 1 = opaque.
    public var opacity: Double
    /// The appearance stream draws with the Multiply blend mode (how highlighters are usually drawn).
    public var blendsMultiply: Bool

    public init(
        points: [PDFPoint], color: RGBColor, width: Double, name: String? = nil,
        opacity: Double = 1, blendsMultiply: Bool = false
    ) {
        self.points = points
        self.color = color
        self.width = width
        self.name = name
        self.opacity = opacity
        self.blendsMultiply = blendsMultiply
    }

    /// Transparency hint: partly transparent or multiplied.
    public var isTranslucent: Bool { opacity < 0.999 || blendsMultiply }

    /// Highlighter by the stroke alone, in any color: a wide band (>= 10 pt, Goodnotes uses ~18 pt) or a
    /// translucent stroke that is clearly wider than a pen. `GoodnotesPage.isHighlighter(at:)` additionally
    /// compares the width with the pen widths of the page.
    public var isHighlighter: Bool {
        width >= 10 || (isTranslucent && width >= 4)
    }

    /// Bounding box of the stroke including half the line width, normalized to the page.
    public func boundingBox(pageSize: PageSize) -> NormalizedRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let half = width / 2
        return .fromBottomLeft(
            x: minX - half, y: minY - half,
            width: maxX - minX + width, height: maxY - minY + width,
            spaceWidth: pageSize.width, spaceHeight: pageSize.height
        )
    }
}

/// Typed text box (FreeText annotation); `text` is the exact `/Contents`.
public struct FreeTextBox: Hashable, Sendable {
    public var text: String
    public var rect: NormalizedRect
    public var name: String?

    public init(text: String, rect: NormalizedRect, name: String? = nil) {
        self.text = text
        self.rect = rect
        self.name = name
    }
}

/// Shape-tool arrow or line (Stamp annotation). Not text; ignored by OCR.
public struct StampShape: Hashable, Sendable {
    public var rect: NormalizedRect
    public var name: String?

    public init(rect: NormalizedRect, name: String? = nil) {
        self.rect = rect
        self.name = name
    }
}

/// A word of a PDF text layer (e.g. the Goodnotes handwriting recognition in the reduced PDF).
public struct TextLayerWord: Hashable, Sendable {
    public var text: String
    public var rect: NormalizedRect

    public init(text: String, rect: NormalizedRect) {
        self.text = text
        self.rect = rect
    }
}

public struct GoodnotesPage: Hashable, Sendable {
    /// 0-based page index.
    public var index: Int
    /// Size of the page as displayed, in points: the MediaBox size with the page's `/Rotate` applied
    /// (90 and 270 swap width and height). Strokes, rects and text-layer words are in this rotated space.
    public var size: PageSize
    public var strokes: [InkStroke]
    public var freeTexts: [FreeTextBox]
    public var stamps: [StampShape]
    /// Words of the page's own text layer (worksheet text in the editable PDF,
    /// recognized handwriting + worksheet text in the reduced PDF).
    public var textLayer: [TextLayerWord]
    /// `/Rotate` of the page in degrees clockwise (0, 90, 180, 270). Informational: everything else in this
    /// struct is already in the rotated page space.
    public var rotation: Int

    public init(
        index: Int, size: PageSize, strokes: [InkStroke] = [], freeTexts: [FreeTextBox] = [],
        stamps: [StampShape] = [], textLayer: [TextLayerWord] = [], rotation: Int = 0
    ) {
        self.rotation = rotation
        self.index = index
        self.size = size
        self.strokes = strokes
        self.freeTexts = freeTexts
        self.stamps = stamps
        self.textLayer = textLayer
    }

    /// Per stroke: is it a highlighter? Absolute rule (`InkStroke.isHighlighter`) or, relative to this page, a
    /// stroke at least 3 times as wide as the median of the other strokes and at least 6 pt wide.
    public var highlighterFlags: [Bool] {
        var flags = strokes.map(\.isHighlighter)
        let penWidths = zip(strokes, flags).filter { !$0.1 }.map(\.0.width).sorted()
        if !penWidths.isEmpty {
            let median = penWidths[penWidths.count / 2]
            for (index, stroke) in strokes.enumerated() where !flags[index] {
                if stroke.width >= 6, stroke.width >= 3 * median { flags[index] = true }
            }
        }
        return flags
    }

    public func isHighlighter(at index: Int) -> Bool {
        highlighterFlags[index]
    }

    public var penStrokes: [InkStroke] {
        zip(strokes, highlighterFlags).filter { !$0.1 }.map(\.0)
    }
    public var highlighterStrokes: [InkStroke] {
        zip(strokes, highlighterFlags).filter { $0.1 }.map(\.0)
    }
}

public struct GoodnotesDocument: Hashable, Sendable {
    public var variant: GoodnotesVariant
    public var pages: [GoodnotesPage]
    public var producer: String?
    public var creator: String?

    public init(variant: GoodnotesVariant, pages: [GoodnotesPage], producer: String? = nil, creator: String? = nil) {
        self.variant = variant
        self.pages = pages
        self.producer = producer
        self.creator = creator
    }
}

public enum GoodnotesError: Error, Hashable, Sendable {
    case notAPDF
    case encrypted
    /// `.goodnotes` files are proprietary and not supported.
    case goodnotesFileNotSupported
    case notImplemented
}

/// Result of checking whether two exports belong to the same note.
public enum GoodnotesPairingCheck: Hashable, Sendable {
    case compatible
    case pageCountMismatch(editable: Int, reduced: Int)
    /// 0-based index of the first page whose size differs.
    case pageSizeMismatch(pageIndex: Int)
    case wrongVariants
}
