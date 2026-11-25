import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Hiding the handwriting of an editable Goodnotes page: the Ink annotations whose strokes belong to recognized lines
/// are not drawn; sketches, underlines, table lines, highlighter and illegible ink stay.
enum DigitalPageInk {
    /// One Ink annotation as `GoodnotesPDFReader` reads it: its strokes are `strokes` of `GoodnotesPage.strokes`.
    struct InkAnnotation {
        var rect: CGRect
        var name: String?
        var strokes: Range<Int>
    }

    /// The visible Ink annotations of `page` in `/Annots` order, with the stroke indices the reader gives them.
    static func inkAnnotations(of page: CGPDFPage) -> [InkAnnotation] {
        guard let dictionary = page.dictionary else { return [] }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { return [] }
        var result: [InkAnnotation] = []
        var next = 0
        for index in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &annot), let annot,
                  DigitalPagePDF.subtype(of: annot) == "Ink", !DigitalPagePDF.isHidden(annot) else { continue }
            // Same rule as the reader: every InkList entry with at least one point is a stroke.
            var count = 0
            var inkList: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(annot, "InkList", &inkList), let inkList {
                for entry in 0..<CGPDFArrayGetCount(inkList) {
                    var list: CGPDFArrayRef?
                    if CGPDFArrayGetArray(inkList, entry, &list), let list, CGPDFArrayGetCount(list) >= 2 { count += 1 }
                }
            }
            result.append(InkAnnotation(
                rect: DigitalPagePDF.rect(of: annot) ?? .null, name: DigitalPagePDF.textString(annot, "NM"),
                strokes: next..<(next + count)))
            next += count
        }
        return result
    }

    /// Strokes of the handwriting that `lines` explain: text-like strokes (no highlighter, no long straight lines,
    /// not the stroke of an ink shape such as a circle) minus those no recognized word or line explains (illegible
    /// ink, sketches). Unlike the recognition, the words *inside* a circle are handwriting and are hidden.
    static func handwritingStrokes(
        page: GoodnotesPage, lines: [RecognizedLine], highlights: [RecognizedHighlight]
    ) -> Set<Int> {
        guard !lines.isEmpty else { return [] }
        let shapes = DigitizationPipeline.shapeRects(of: highlights)
        let lineHeight = IllegibleInk.lineHeight(page: page, recognized: lines)
        let shapeBoxes = shapes.map {
            CGRect(x: $0.x * page.size.width, y: $0.y * page.size.height,
                   width: $0.width * page.size.width, height: $0.height * page.size.height)
        }
        let candidates = IllegibleInk.textStrokes(page: page, shapeRects: [], lineHeight: lineHeight)
            .filter { stroke in !shapeBoxes.contains { isShapeStroke(stroke.box, shape: $0) } }
        let unexplained = Set(IllegibleInk.unexplainedStrokes(
            page: page, recognized: lines, shapeRects: shapes, lineHeight: lineHeight).map(\.index))
        return Set(candidates.map(\.index)).subtracting(unexplained)
    }

    /// The stroke draws the shape itself (circle, short underline): it lies in the shape's area and spans most of it.
    static func isShapeStroke(_ box: CGRect, shape: CGRect) -> Bool {
        let overlap = box.intersection(shape)
        guard !overlap.isNull, overlap.width * overlap.height >= 0.8 * max(1, box.width * box.height) else {
            return false
        }
        return box.width >= 0.6 * shape.width && box.height >= 0.6 * shape.height
    }

    /// Hides the annotations of `strokes` on `pdfPage` (`shouldDisplay = false`). An annotation with both hidden and
    /// kept strokes is hidden as well; its kept strokes are returned so that they can be drawn by hand. This changes
    /// the page's document: use a document of its own, not a shared one.
    /// - Returns: the hidden annotations, the strokes of `strokes` that are hidden now (strokes of annotations that
    ///   were not displayed anyway are not), and the strokes to redraw; nil if the annotations cannot be matched to
    ///   the parsed strokes (then nothing is hidden).
    static func hide(
        strokes: Set<Int>, on pdfPage: PDFPage, goodnotes: GoodnotesPage
    ) -> (hidden: [PDFAnnotation], hiddenStrokes: Set<Int>, redraw: [Int])? {
        guard let cgPage = pdfPage.pageRef else { return nil }
        let inks = inkAnnotations(of: cgPage)
        guard inks.last?.strokes.upperBound ?? 0 == goodnotes.strokes.count else { return nil }
        if strokes.isEmpty { return ([], [], []) }
        let candidates = pdfPage.annotations.filter { $0.type == "Ink" }
        var matched: [PDFAnnotation] = []
        var position = 0
        for ink in inks {
            var found: Int?
            var k = position
            while k < candidates.count {
                let annotation = candidates[k]
                let bounds = annotation.bounds
                let name = annotation.value(forAnnotationKey: .name) as? String
                let sameRect = ink.rect.isNull || (abs(bounds.minX - ink.rect.minX) < 1 && abs(bounds.minY - ink.rect.minY) < 1
                    && abs(bounds.width - ink.rect.width) < 1 && abs(bounds.height - ink.rect.height) < 1)
                let sameName = ink.name == nil || name == nil || ink.name == name
                if sameRect, sameName { found = k; break }
                k += 1
            }
            guard let found else { return nil }
            matched.append(candidates[found])
            position = found + 1
        }
        var hidden: [PDFAnnotation] = []
        var hiddenStrokes: Set<Int> = []
        var redraw: [Int] = []
        for (ink, annotation) in zip(inks, matched) where !ink.strokes.isEmpty && annotation.shouldDisplay {
            let own = ink.strokes.filter(strokes.contains)
            guard !own.isEmpty else { continue }
            annotation.shouldDisplay = false
            hidden.append(annotation)
            hiddenStrokes.formUnion(own)
            redraw += ink.strokes.filter { !strokes.contains($0) }
        }
        return (hidden, hiddenStrokes, redraw)
    }

    /// Lines whose handwriting is hidden: a hidden stroke has its center in the line (grown by 0.3 line heights
    /// vertically, a stroke may reach a little beyond Vision's box).
    static func coveredLines(
        _ lines: [RecognizedLine], hiddenStrokes: Set<Int>, of page: GoodnotesPage
    ) -> Set<UUID> {
        let centers: [(Double, Double)] = hiddenStrokes.compactMap { index in
            guard index < page.strokes.count else { return nil }
            let box = page.strokes[index].boundingBox(pageSize: page.size)
            return (box.midX, box.midY)
        }
        var result: Set<UUID> = []
        for line in lines {
            let r = line.rect, grow = 0.3 * r.height
            if centers.contains(where: { $0.0 >= r.minX && $0.0 <= r.maxX && $0.1 >= r.minY - grow && $0.1 <= r.maxY + grow }) {
                result.insert(line.id)
            }
        }
        return result
    }

    /// Draws strokes of `page` as plain paths (context in displayed page points, origin bottom-left).
    static func draw(_ indices: [Int], of page: GoodnotesPage, in context: CGContext) {
        for index in indices where index < page.strokes.count {
            let stroke = page.strokes[index]
            guard let first = stroke.points.first else { continue }
            context.saveGState()
            context.setStrokeColor(CGColor(
                srgbRed: stroke.color.red, green: stroke.color.green, blue: stroke.color.blue, alpha: 1))
            context.setAlpha(stroke.opacity)
            if stroke.blendsMultiply { context.setBlendMode(.multiply) }
            context.setLineWidth(stroke.width)
            context.setLineCap(stroke.isHighlighter ? .butt : .round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: first.x, y: first.y))
            if stroke.points.count == 1 {
                context.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            } else {
                for point in stroke.points.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
            }
            context.strokePath()
            context.restoreGState()
        }
    }
}
