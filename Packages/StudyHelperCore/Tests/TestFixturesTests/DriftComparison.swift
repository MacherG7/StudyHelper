import CoreGraphics
import Foundation
@testable import TestFixtures

/// Structural comparison of a freshly generated fixture against the committed one. It is the fallback of the
/// drift test and is only meant for the case that the handwriting font changed (different glyph outlines).
/// It must still catch every generator change that does not come from the outlines: operators, colors, widths,
/// flags, appearance streams, contents, text layer, page content, relations and the truth fields.
enum DriftComparison {
    /// Tolerance for coordinates that derive from the glyph outlines (word boxes, arrows between words).
    static let outlineTolerance = 3.0

    static func problems(committedPDF: Data, committedTruth: GoodnotesGroundTruth,
                         freshPDF: Data, freshTruth: GoodnotesGroundTruth) throws -> [String] {
        var out: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { out.append(message()) } }

        let c = committedTruth, f = freshTruth
        check(c.fileName == f.fileName && c.variant == f.variant && c.generator == f.generator, "truth header")
        check(c.pageCount == f.pageCount && c.pageWidth == f.pageWidth && c.pageHeight == f.pageHeight, "page geometry")
        check(c.ocrErrors == f.ocrErrors, "ocrErrors")

        for (cp, fp) in zip(c.pages, f.pages) {
            check(cp.pageNumber == fp.pageNumber && cp.items.map(\.id) == fp.items.map(\.id), "item ids page \(cp.pageNumber)")
            for (ci, fi) in zip(cp.items, fp.items) {
                let id = ci.id
                check(ci.kind == fi.kind, "\(id) kind")
                check(ci.text == fi.text, "\(id) text")
                check(ci.colorHex == fi.colorHex, "\(id) color")
                check(ci.lineWidth == fi.lineWidth, "\(id) lineWidth")
                check(ci.emphasis == fi.emphasis, "\(id) emphasis")
                check(ci.relatedItemID == fi.relatedItemID && ci.relatedItemIDs == fi.relatedItemIDs, "\(id) related")
                check(ci.sourceItemID == fi.sourceItemID, "\(id) source")
                check(ci.lineID == fi.lineID, "\(id) lineID")
                check(ci.appearanceText == fi.appearanceText, "\(id) appearanceText")
                check(ci.annotationSubtype == fi.annotationSubtype, "\(id) annotationSubtype")
                check(ci.bbox.count == 4 && fi.bbox.count == 4
                        && zip(ci.bbox, fi.bbox).allSatisfy { abs($0 - $1) <= outlineTolerance }, "\(id) bbox")
                check((ci.endpoints == nil) == (fi.endpoints == nil)
                        && zip(ci.endpoints ?? [], fi.endpoints ?? []).allSatisfy { abs($0 - $1) <= outlineTolerance },
                      "\(id) endpoints")
                // Stroke and annotation counts of words follow the outlines; everything else is fixed.
                if ci.kind != .inkWord {
                    check(ci.strokeCount == fi.strokeCount && ci.annotationCount == fi.annotationCount, "\(id) counts")
                }
            }
        }

        let a = try RawPDF(data: committedPDF), b = try RawPDF(data: freshPDF)
        guard a.pageCount == b.pageCount else { return out + ["pdf page count"] }
        for n in 1...a.pageCount {
            let pa = try a.page(n), pb = try b.page(n)
            check(pa.mediaBox == pb.mediaBox, "page \(n) mediaBox")
            check(pa.hasAnnotsKey == pb.hasAnnotsKey, "page \(n) /Annots presence")

            // Annotation statistics: the set of (subtype, color, width, flags, AP, multiply, contents) ...
            let sa = pa.annotations, sb = pb.annotations
            check(Set(sa.map(\.signature)) == Set(sb.map(\.signature)), "page \(n) annotation signatures")
            // ... exact counts for everything but handwritten words, and exact geometry for non-ink shapes.
            for subtype in ["FreeText", "Stamp"] {
                check(sa.filter { $0.subtype == subtype }.count == sb.filter { $0.subtype == subtype }.count,
                      "page \(n) \(subtype) count")
            }
            let rectsA = sa.filter { $0.subtype == "FreeText" }.map { $0.rect ?? [] }
            let rectsB = sb.filter { $0.subtype == "FreeText" }.map { $0.rect ?? [] }
            check(rectsA == rectsB, "page \(n) FreeText rect")
            check(pa.imageXObjects.map { "\($0.width)x\($0.height) \($0.colorSpace ?? "-") \($0.bitsPerComponent)" }
                    == pb.imageXObjects.map { "\($0.width)x\($0.height) \($0.colorSpace ?? "-") \($0.bitsPerComponent)" },
                  "page \(n) images")

            // Appearance streams of all annotations, in /Annots order: same operator blocks (colors, widths,
            // caps, blend mode, text) in the same order; only the polyline coordinates may follow the outlines.
            check(blockSequence(sa.map(\.appearanceText).joined(separator: "\n"))
                    == blockSequence(sb.map(\.appearanceText).joined(separator: "\n")),
                  "page \(n) appearance streams")

            // Page content. Editable: only paper and worksheet, so it must be byte-identical. Reduced: the
            // flattened ink, text layer and paper must form the same operator blocks in the same order.
            if committedTruth.variant == "editable" {
                check(pa.contentText == pb.contentText, "page \(n) content stream")
            } else {
                check(blockSequence(pa.contentText) == blockSequence(pb.contentText), "page \(n) content operators")
                check(count(of: " Tj", in: pa.contentText) == count(of: " Tj", in: pb.contentText), "page \(n) Tj count")
                check(count(of: "3 Tr", in: pa.contentText) == count(of: "3 Tr", in: pb.contentText), "page \(n) invisible runs")
            }
        }
        return out
    }

    /// Replaces text in binary data without touching any other byte (Latin-1 round trip is lossless).
    static func replacing(_ find: String, with replacement: String, in data: Data, all: Bool = false) -> Data? {
        guard var text = String(data: data, encoding: .isoLatin1), let range = text.range(of: find) else { return nil }
        if all {
            text = text.replacingOccurrences(of: find, with: replacement)
        } else {
            text.replaceSubrange(range, with: replacement)
        }
        return text.data(using: .isoLatin1)
    }

    private static func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Operator blocks (`q ... Q`, `BT ... ET`) of a content stream in order, consecutive duplicates collapsed.
    /// Polyline points (`m` / `l`) and horizontal scaling (`Tz`) are dropped and the numbers of `Td` are masked, because both
    /// follow the glyph outlines; everything else (colors, widths, caps, blend mode, strings, render mode) is exact.
    static func blockSequence(_ content: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            let block = current.joined(separator: "\n")
            if blocks.last != block { blocks.append(block) }
            current = []
        }
        for line in content.split(separator: "\n") {
            let text = String(line)
            if text.hasSuffix(" m") || text.hasSuffix(" l") || text.hasSuffix(" Tz") { continue }
            if text.hasSuffix(" Td") {
                current.append(text.replacingOccurrences(of: "[-0-9.]+", with: "#", options: .regularExpression))
            } else {
                current.append(text)
            }
            if text == "Q" || text == "ET" { flush() }
        }
        flush()
        return blocks
    }

}
