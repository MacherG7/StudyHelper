import CoreGraphics
import Foundation

/// How an item is drawn / represented in a PDF.
enum ItemDrawing {
    /// Ink: one annotation per stroke (editable) or stroked paths (reduced).
    case ink(strokes: [[Pt]], hex: String, width: Double, highlighter: Bool)
    case freeText(rect: [Double], contents: String, appearanceText: String, fontSize: Double, hex: String)
    case stamp(from: Pt, to: Pt, hex: String, width: Double, arrowHead: Bool)
    /// Already part of the page background content (worksheet text, image).
    case pageContent
}

struct ResolvedItem {
    var truth: GoodnotesTruthItem
    var drawing: ItemDrawing
    /// Handwritten words only: baseline and font size, used to place the recognized text layer.
    var baseline: Double?
    var fontSize: Double?
}

/// One page: background content (paper, worksheet) plus items (Ink, FreeText, Stamp ...).
final class PageBuilder {
    let number: Int
    let width: Double
    let height: Double
    private(set) var background = ContentStream()
    private(set) var items: [ResolvedItem] = []
    private(set) var image: RasterImage?
    private var counters: [String: Int] = [:]
    private var lineCounter = 0

    static let black = "#000000"
    static let red = "#D32F2F"
    static let blue = "#1565C0"
    static let green = "#2E7D32"
    static let highlighterYellow = "#FFE600"

    init(number: Int, width: Double, height: Double) {
        self.number = number
        self.width = width
        self.height = height
    }

    // MARK: Identity and lookup

    private func nextID(_ prefix: String) -> String {
        counters[prefix, default: 0] += 1
        return "p\(number)-\(prefix)\(pad2(counters[prefix]!))"
    }

    func item(_ id: String) -> ResolvedItem {
        guard let found = items.first(where: { $0.truth.id == id }) else {
            preconditionFailure("unknown item \(id)")
        }
        return found
    }

    func rect(of id: String) -> [Double] { item(id).truth.bbox }

    private func union(_ ids: [String]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for id in ids {
            let r = rect(of: id)
            minX = min(minX, r[0]); minY = min(minY, r[1])
            maxX = max(maxX, r[0] + r[2]); maxY = max(maxY, r[1] + r[3])
        }
        return (minX, minY, maxX, maxY)
    }

    // MARK: Paper

    /// Baseline of text on rule number `k` (k = 0 is the first rule below the top margin).
    func ruleY(_ k: Int) -> Double { round2(height - 56 - 34 * Double(k)) }
    func baseline(_ k: Int) -> Double { round2(ruleY(k) + 5) }

    /// Light gray rules plus a pink margin line, as page content.
    func linedPaper() {
        background.save()
        background.strokeColor(HexColor("#C9CDD2"))
        background.lineWidth(0.5)
        var k = 0
        while ruleY(k) > 48 {
            background.polyline([Pt(0, ruleY(k)), Pt(width, ruleY(k))])
            background.raw("S")
            k += 1
        }
        background.strokeColor(HexColor("#F0A8A8"))
        background.lineWidth(0.9)
        background.polyline([Pt(60, 0), Pt(60, height)])
        background.raw("S")
        background.restore()
    }

    // MARK: Worksheet (page content)

    func panel(x: Double, y: Double, w: Double, h: Double) {
        background.save()
        background.raw("1 g")
        background.strokeColor(HexColor("#9AA0A6"))
        background.lineWidth(0.75)
        background.rect(x: x, y: y, w: w, h: h)
        background.raw("B")
        background.restore()
    }

    /// Text run in page content. Returns the item ID and the x position after the run.
    @discardableResult
    func worksheetRun(_ text: String, x: Double, baseline: Double, size: Double, bold: Bool = false,
                      hex: String = PageBuilder.black, underline: Bool = false,
                      emphasis: String? = nil) -> (id: String, endX: Double) {
        let id = nextID("ws")
        let runWidth = HelveticaMetrics.width(text, bold: bold, size: size)
        background.save()
        background.text(text, font: bold ? "F2" : "F1", size: size, x: x, y: baseline, color: HexColor(hex))
        if underline {
            background.strokeColor(HexColor(hex))
            background.lineWidth(0.7)
            background.polyline([Pt(x, baseline - 2.5), Pt(x + runWidth, baseline - 2.5)])
            background.raw("S")
        }
        background.restore()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var tags: [String] = []
        if bold { tags.append("bold") }
        if hex != PageBuilder.black { tags.append("colored") }
        if underline { tags.append("underline") }
        let bbox = [round2(x), round2(baseline - 0.21 * size), runWidth, round2(0.93 * size)]
        let truth = GoodnotesTruthItem(
            id: id, kind: .worksheetText, text: trimmed, colorHex: HexColor(hex).hex, lineWidth: nil,
            bbox: bbox, strokeCount: 0, annotationCount: 0, annotationSubtype: nil, lineID: nil,
            emphasis: emphasis ?? (tags.isEmpty ? nil : tags.joined(separator: ",")),
            relatedItemID: nil, sourceItemID: nil, endpoints: nil, appearanceText: nil)
        items.append(ResolvedItem(truth: truth, drawing: .pageContent))
        return (id, round2(x + runWidth))
    }

    /// Printed answer line (thin gray rule) in page content.
    func worksheetRule(x1: Double, x2: Double, y: Double) {
        background.save()
        background.strokeColor(HexColor("#757575"))
        background.lineWidth(0.6)
        background.polyline([Pt(x1, y), Pt(x2, y)])
        background.raw("S")
        background.restore()
    }

    /// Inserted raster image (page content).
    func worksheetImage(_ raster: RasterImage, x: Double, y: Double, w: Double, h: Double) {
        image = raster
        background.save()
        background.raw("\(pdfNumber(w)) 0 0 \(pdfNumber(h)) \(pdfNumber(x)) \(pdfNumber(y)) cm")
        background.raw("/Im1 Do")
        background.restore()
        let truth = GoodnotesTruthItem(
            id: nextID("img"), kind: .image, text: nil, colorHex: nil, lineWidth: nil,
            bbox: [round2(x), round2(y), round2(w), round2(h)], strokeCount: 0, annotationCount: 0,
            annotationSubtype: nil, lineID: nil, emphasis: nil, relatedItemID: nil, sourceItemID: nil,
            endpoints: nil, appearanceText: nil)
        items.append(ResolvedItem(truth: truth, drawing: .pageContent))
    }

    // MARK: Handwriting

    /// Handwritten line; every space-separated word becomes one item. Returns the word IDs.
    @discardableResult
    func handwrittenLine(_ text: String, x: Double, baseline: Double, size: Double,
                         hex: String = PageBuilder.black, width: Double = 1.6) -> [String] {
        lineCounter += 1
        let lineID = "p\(number)-line\(pad2(lineCounter))"
        let font = HandwritingFont(size: size)
        var pen = x
        var ids: [String] = []
        for word in text.split(separator: " ") {
            let layout = font.layoutWord(String(word), x: pen, baseline: baseline)
            pen += layout.advance + font.spaceAdvance
            let id = nextID("w")
            let truth = GoodnotesTruthItem(
                id: id, kind: .inkWord, text: String(word), colorHex: HexColor(hex).hex, lineWidth: width,
                bbox: boundingBox(of: layout.strokes, pad: width / 2),
                strokeCount: layout.strokes.count, annotationCount: layout.strokes.count,
                annotationSubtype: "Ink", lineID: lineID, emphasis: nil, relatedItemID: nil,
                sourceItemID: nil, endpoints: nil, appearanceText: nil)
            items.append(ResolvedItem(
                truth: truth,
                drawing: .ink(strokes: layout.strokes, hex: HexColor(hex).hex, width: width, highlighter: false),
                baseline: baseline, fontSize: size))
            ids.append(id)
        }
        return ids
    }

    private func addInkShape(kind: GoodnotesItemKind, prefix: String, strokes: [[Pt]], hex: String, width: Double,
                             emphasis: String?, related: [String], incidental: [String] = [],
                             highlighter: Bool = false) -> String {
        let id = nextID(prefix)
        let truth = GoodnotesTruthItem(
            id: id, kind: kind, text: nil, colorHex: HexColor(hex).hex, lineWidth: width,
            bbox: boundingBox(of: strokes, pad: width / 2),
            strokeCount: strokes.count, annotationCount: strokes.count, annotationSubtype: "Ink",
            lineID: nil, emphasis: emphasis, relatedItemID: related.first, relatedItemIDs: related,
            incidentalItemIDs: incidental, sourceItemID: nil, endpoints: nil, appearanceText: nil)
        items.append(ResolvedItem(
            truth: truth,
            drawing: .ink(strokes: strokes, hex: HexColor(hex).hex, width: width, highlighter: highlighter)))
        return id
    }

    /// Yellow highlighter stroke (W = 18) over one or more adjacent words of the same line.
    ///
    /// By default the stroke reaches up to 3 points beyond the first and last word but stops short of any
    /// neighbouring word's box. Explicit `bleedLeft` / `bleedRight` values are used as given, so a stroke can
    /// deliberately run into a neighbour ("near miss"). The truth lists the given words as related items; every
    /// other handwritten word whose box the stroke overlaps is recorded as incidental, never as related.
    @discardableResult
    func highlight(_ wordIDs: [String], bleedLeft: Double? = nil, bleedRight: Double? = nil) -> String {
        precondition(!wordIDs.isEmpty, "highlight needs at least one word")
        let first = item(wordIDs[0])
        let u = union(wordIDs)
        let size = first.fontSize ?? 20
        let y = first.baseline.map { $0 + 0.36 * size } ?? ((u.minY + u.maxY) / 2)
        let band = (y - 9)...(y + 9)
        let others = items.filter {
            $0.truth.kind == .inkWord && !wordIDs.contains($0.truth.id)
                && $0.truth.bbox[1] <= band.upperBound && $0.truth.bbox[1] + $0.truth.bbox[3] >= band.lowerBound
        }
        let leftGap = others.map { u.minX - ($0.truth.bbox[0] + $0.truth.bbox[2]) }.filter { $0 >= 0 }.min()
        let rightGap = others.map { $0.truth.bbox[0] - u.maxX }.filter { $0 >= 0 }.min()
        func safeBleed(_ gap: Double?) -> Double { max(0, min(3, (gap ?? 3) - 0.3)) }
        let x0 = u.minX - (bleedLeft ?? safeBleed(leftGap)), x1 = u.maxX + (bleedRight ?? safeBleed(rightGap))
        let stroke = [Pt(x0, y), Pt((x0 + x1) / 2, y + 0.5), Pt(x1, y - 0.3)]
        let width = 18.0
        // Butt caps: the painted area ends exactly at the stroke's end points horizontally.
        let strokeRect = CGRect(x: x0, y: y - 0.5 - width / 2, width: x1 - x0, height: 1 + width)
        let incidental = items
            .filter { $0.truth.kind == .inkWord && !wordIDs.contains($0.truth.id) }
            .filter { strokeRect.intersects(CGRect(x: $0.truth.bbox[0], y: $0.truth.bbox[1],
                                                   width: $0.truth.bbox[2], height: $0.truth.bbox[3])) }
            .map(\.truth.id)
        return addInkShape(kind: .highlighter, prefix: "hl", strokes: [stroke], hex: PageBuilder.highlighterYellow,
                           width: width, emphasis: "highlight", related: wordIDs, incidental: incidental,
                           highlighter: true)
    }

    /// One long, nearly horizontal stroke a few points below the lowest of the given words.
    @discardableResult
    func underline(_ wordIDs: [String], hex: String = PageBuilder.black, width: Double = 2.4) -> String {
        let u = union(wordIDs)
        let y = u.minY - 3
        let x0 = u.minX - 2, x1 = u.maxX + 3
        let stroke = [Pt(x0, y), Pt((x0 + x1) / 2, y - 0.2), Pt(x1, y - 0.8)]
        return addInkShape(kind: .underline, prefix: "ul", strokes: [stroke], hex: hex, width: width,
                           emphasis: "underline", related: wordIDs)
    }

    /// Two parallel strokes under a word.
    @discardableResult
    func doubleUnderline(_ wordID: String, hex: String, width: Double = 1.8) -> String {
        let r = rect(of: wordID)
        let x0 = r[0] - 2, x1 = r[0] + r[2] + 3
        let y1 = r[1] - 3, y2 = r[1] - 7.5
        let s1 = [Pt(x0, y1), Pt((x0 + x1) / 2, y1 - 0.2), Pt(x1, y1 - 0.6)]
        let s2 = [Pt(x0 + 1, y2), Pt((x0 + x1) / 2, y2 - 0.1), Pt(x1 - 1, y2 - 0.5)]
        return addInkShape(kind: .doubleUnderline, prefix: "dul", strokes: [s1, s2], hex: hex, width: width,
                           emphasis: "doubleUnderline", related: [wordID])
    }

    /// One closed (slightly overshooting) ellipse around a word.
    @discardableResult
    func circle(_ wordID: String, hex: String, width: Double = 1.8) -> String {
        let r = rect(of: wordID)
        let cx = r[0] + r[2] / 2, cy = r[1] + r[3] / 2
        let rx = r[2] / 2 + 9, ry = r[3] / 2 + 8
        let steps = 48
        let total = 2 * Double.pi + 0.4
        let start = -Double.pi * 0.62
        var stroke: [Pt] = []
        for i in 0..<steps {
            let t = Double(i) / Double(steps - 1)
            let a = start + t * total
            let grow = 1 + 0.035 * t
            stroke.append(Pt(cx + rx * grow * cos(a), cy + ry * grow * sin(a)))
        }
        return addInkShape(kind: .circle, prefix: "circ", strokes: [stroke], hex: hex, width: width,
                           emphasis: "circle", related: [wordID])
    }

    /// Hand-drawn table grid (slightly wobbly strokes). Returns nothing; every grid line is one item.
    func tableGrid(x: Double, top: Double, columnWidths: [Double], rowHeight: Double, rows: Int,
                   hex: String = PageBuilder.black, width: Double = 1.6) {
        let totalW = columnWidths.reduce(0, +)
        let bottom = top - rowHeight * Double(rows)
        for r in 0...rows {
            let y = top - rowHeight * Double(r)
            let stroke = [Pt(x - 2, y + 0.4), Pt(x + totalW / 2, y - 0.3), Pt(x + totalW + 2, y + 0.2)]
            _ = addInkShape(kind: .tableLine, prefix: "tl", strokes: [stroke], hex: hex, width: width,
                            emphasis: "horizontal", related: [])
        }
        var cx = x
        for c in 0...columnWidths.count {
            let stroke = [Pt(cx + 0.3, top + 2), Pt(cx - 0.3, (top + bottom) / 2), Pt(cx + 0.2, bottom - 2)]
            _ = addInkShape(kind: .tableLine, prefix: "tl", strokes: [stroke], hex: hex, width: width,
                            emphasis: "vertical", related: [])
            if c < columnWidths.count { cx += columnWidths[c] }
        }
    }

    // MARK: Annotations without handwriting

    /// FreeText box with exact (Unicode) contents; the appearance stream draws `appearanceText`.
    @discardableResult
    func freeText(_ contents: String, appearanceText: String, x: Double, y: Double, w: Double, h: Double,
                  fontSize: Double, hex: String = PageBuilder.black) -> String {
        let id = nextID("ft")
        let bbox = [round2(x), round2(y), round2(w), round2(h)]
        let truth = GoodnotesTruthItem(
            id: id, kind: .freeText, text: contents, colorHex: HexColor(hex).hex, lineWidth: nil, bbox: bbox,
            strokeCount: 0, annotationCount: 1, annotationSubtype: "FreeText", lineID: nil, emphasis: nil,
            relatedItemID: nil, sourceItemID: nil, endpoints: nil, appearanceText: appearanceText)
        items.append(ResolvedItem(
            truth: truth,
            drawing: .freeText(rect: bbox, contents: contents, appearanceText: appearanceText,
                               fontSize: fontSize, hex: HexColor(hex).hex)))
        return id
    }

    /// The two barb end points of an arrow head at `to` (head length 12 pt, spread 0.45 rad).
    static func arrowHead(from: Pt, to: Pt) -> (left: Pt, right: Pt) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length = 12.0, spread = 0.45
        return (Pt(to.x - length * cos(angle - spread), to.y - length * sin(angle - spread)),
                Pt(to.x - length * cos(angle + spread), to.y - length * sin(angle + spread)))
    }

    /// Stamp annotation drawn with the shape tool: a straight line, optionally with an arrow head at `to`.
    @discardableResult
    func stamp(from: Pt, to: Pt, arrow: Bool, hex: String = PageBuilder.black, width: Double = 2,
               sourceItemID: String? = nil, targetItemID: String? = nil) -> String {
        let id = nextID("st")
        var points = [from, to]
        if arrow {
            let head = Self.arrowHead(from: from, to: to)
            points += [head.left, head.right]
        }
        let bbox = boundingBox(of: [points], pad: width / 2)
        let truth = GoodnotesTruthItem(
            id: id, kind: .stamp, text: nil, colorHex: HexColor(hex).hex, lineWidth: width, bbox: bbox,
            strokeCount: 1, annotationCount: 1, annotationSubtype: "Stamp", lineID: nil,
            emphasis: arrow ? "arrow" : "line", relatedItemID: targetItemID,
            relatedItemIDs: targetItemID.map { [$0] } ?? [], sourceItemID: sourceItemID,
            endpoints: [from.x, from.y, to.x, to.y], appearanceText: nil)
        items.append(ResolvedItem(
            truth: truth, drawing: .stamp(from: from, to: to, hex: HexColor(hex).hex, width: width, arrowHead: arrow)))
        return id
    }
}
