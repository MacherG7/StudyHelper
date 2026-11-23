import Foundation

/// Renders pages into PDF bytes (editable: annotations; reduced: flattened + invisible text layer)
/// and derives the matching ground truth.
enum PDFRendering {
    /// Renders the given pages. `includeTextLayer: false` omits the invisible recognized text of reduced PDFs (the truth keeps listing it);
    /// tests use it to prove that the layer does not change the rendering.
    static func render(spec: GoodnotesFixtureSpec, pages: [PageBuilder],
                       includeTextLayer: Bool = true) -> (pdf: Data, truth: GoodnotesGroundTruth) {
        var b = PDFBuilder()
        let catalog = b.reserve()
        let pagesRef = b.reserve()
        let info = b.reserve()
        let helv = b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let helvBold = b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")

        var kids: [PDFRef] = []
        var truthPages: [GoodnotesTruthPage] = []
        var ocrErrors: [GoodnotesOCRError] = []
        let mediaBox = "[0 0 \(pdfNumber(spec.pageWidth)) \(pdfNumber(spec.pageHeight))]"

        for page in pages {
            let pageRef = b.reserve()
            kids.append(pageRef)

            var content = page.background
            var annotRefs: [PDFRef] = []
            var truthItems: [GoodnotesTruthItem] = []

            switch spec.variant {
            case .editable:
                for item in page.items {
                    truthItems.append(item.truth)
                    annotRefs += addAnnotations(for: item, page: pageRef, helv: helv, builder: &b)
                }
            case .reduced:
                for item in page.items {
                    flatten(item, into: &content)
                    var t = item.truth
                    t.annotationCount = 0
                    t.annotationSubtype = nil
                    truthItems.append(t)
                }
                let layer = textLayer(page: page, substitutions: spec.ocrSubstitutions)
                if includeTextLayer { content.raw(layer.content) }
                truthItems += layer.items
                ocrErrors += layer.errors
            }

            let contentRef = b.addStream("", data: Data(content.text.utf8))
            var xobjects = ""
            if let image = page.image {
                var d = Data()
                d.append(image.rgb)
                let imageRef = b.addStream(
                    "/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) "
                        + "/ColorSpace /DeviceRGB /BitsPerComponent 8", data: d)
                xobjects = " /XObject << /Im1 \(imageRef.ref) >>"
            }
            let resources = "<< /Font << /F1 \(helv.ref) /F2 \(helvBold.ref) >>\(xobjects) "
                + "/ExtGState << /GSMul << /Type /ExtGState /BM /Multiply >> >> /ProcSet [/PDF /Text /ImageC] >>"
            var pageDict = "<< /Type /Page /Parent \(pagesRef.ref) /MediaBox \(mediaBox) /Resources \(resources) "
                + "/Contents \(contentRef.ref)"
            if !annotRefs.isEmpty {
                pageDict += " /Annots [" + annotRefs.map(\.ref).joined(separator: " ") + "]"
            }
            pageDict += " >>"
            b.set(pageRef, pageDict)
            truthPages.append(GoodnotesTruthPage(pageNumber: page.number, items: truthItems))
        }

        b.set(pagesRef, "<< /Type /Pages /Kids [" + kids.map(\.ref).joined(separator: " ") + "] /Count \(kids.count) >>")
        b.set(catalog, "<< /Type /Catalog /Pages \(pagesRef.ref) /Lang (de-DE) >>")
        b.set(info, "<< /Producer \(pdfTextString(GoodnotesFixtureSpec.producer)) /Title \(pdfTextString(spec.title)) >>")

        let truth = GoodnotesGroundTruth(
            fileName: spec.name + ".pdf", variant: spec.variant.rawValue, generator: GoodnotesFixtureSpec.generatorTag,
            handwritingFont: HandwritingFont.resolvedName,
            handwritingFontVersion: HandwritingFont.resolvedVersion, pageCount: pages.count,
            pageWidth: spec.pageWidth, pageHeight: spec.pageHeight, pages: truthPages, ocrErrors: ocrErrors)
        return (b.serialize(root: catalog, info: info), truth)
    }

    // MARK: Editable: annotations

    private static func inkContent(strokes: [[Pt]], hex: String, width: Double, highlighter: Bool) -> [String] {
        // One content string per stroke.
        strokes.map { stroke in
            var c = ContentStream()
            c.save()
            if highlighter { c.raw("/GSMul gs") }
            c.strokeColor(HexColor(hex))
            c.lineWidth(width)
            c.raw(highlighter ? "0 J 0 j" : "1 J 1 j")
            c.polyline(stroke)
            c.raw("S")
            c.restore()
            return c.text
        }
    }

    private static func formXObject(_ b: inout PDFBuilder, rect: [Double], content: String, resources: String) -> PDFRef {
        let bbox = "[" + rect.map { pdfNumber($0) }.joined(separator: " ") + "]"
        return b.addStream("/Type /XObject /Subtype /Form /BBox \(bbox) /Resources \(resources)",
                           data: Data(content.utf8))
    }

    private static func rectArray(_ r: [Double]) -> [Double] { [r[0], r[1], r[0] + r[2], r[1] + r[3]] }

    private static func addAnnotations(for item: ResolvedItem, page: PDFRef, helv: PDFRef,
                                       builder b: inout PDFBuilder) -> [PDFRef] {
        let id = item.truth.id
        switch item.drawing {
        case .pageContent:
            return []

        case let .ink(strokes, hex, width, highlighter):
            let color = HexColor(hex)
            let contents = inkContent(strokes: strokes, hex: hex, width: width, highlighter: highlighter)
            var refs: [PDFRef] = []
            for (index, stroke) in strokes.enumerated() {
                let bbox = boundingBox(of: [stroke], pad: width / 2 + 0.5)
                let rect = rectArray(bbox)
                let resources = highlighter
                    ? "<< /ExtGState << /GSMul << /Type /ExtGState /BM /Multiply >> >> >>" : "<< >>"
                let ap = formXObject(&b, rect: rect, content: contents[index], resources: resources)
                let points = stroke.map { "\(pdfNumber($0.x)) \(pdfNumber($0.y))" }.joined(separator: " ")
                let dict = "<< /Type /Annot /Subtype /Ink /Rect [\(rect.map { pdfNumber($0) }.joined(separator: " "))] "
                    + "/F 4 /NM \(WinAnsi.literal("\(id)#\(index)")) /P \(page.ref) /C [\(color.components)] "
                    + "/BS << /Type /Border /W \(pdfNumber(width)) /S /S >> /InkList [[\(points)]] /AP << /N \(ap.ref) >> >>"
                refs.append(b.add(dict))
            }
            return refs

        case let .freeText(rectXYWH, contents, appearanceText, fontSize, hex):
            let rect = rectArray(rectXYWH)
            var c = ContentStream()
            c.save()
            c.raw("0.97 g")
            c.strokeColor(HexColor("#8A8F98"))
            c.lineWidth(0.5)
            c.rect(x: rect[0] + 0.25, y: rect[1] + 0.25, w: rectXYWH[2] - 0.5, h: rectXYWH[3] - 0.5)
            c.raw("B")
            c.restore()
            c.text(appearanceText, font: "Helv", size: fontSize, x: rect[0] + 8,
                   y: rect[1] + rectXYWH[3] / 2 - fontSize * 0.35, color: HexColor(hex))
            let ap = formXObject(&b, rect: rect, content: c.text,
                                 resources: "<< /Font << /Helv \(helv.ref) >> >>")
            let dict = "<< /Type /Annot /Subtype /FreeText /Rect [\(rect.map { pdfNumber($0) }.joined(separator: " "))] "
                + "/F 4 /NM \(WinAnsi.literal(id)) /P \(page.ref) /Contents \(pdfUTF16Hex(contents)) "
                + "/DA (/Helv \(pdfNumber(fontSize)) Tf \(HexColor(hex).components) rg) /Q 0 "
                + "/BS << /Type /Border /W 0.5 /S /S >> /AP << /N \(ap.ref) >> >>"
            return [b.add(dict)]

        case let .stamp(from, to, hex, width, arrowHead):
            let lineBox = boundingBox(of: [[from, to]], pad: width / 2 + (arrowHead ? 14 : 1))
            let rect = rectArray(lineBox)
            var c = ContentStream()
            drawStampShape(&c, from: from, to: to, hex: hex, width: width, arrowHead: arrowHead)
            let ap = formXObject(&b, rect: rect, content: c.text, resources: "<< >>")
            let color = HexColor(hex)
            let dict = "<< /Type /Annot /Subtype /Stamp /Rect [\(rect.map { pdfNumber($0) }.joined(separator: " "))] "
                + "/F 4 /NM \(WinAnsi.literal(id)) /P \(page.ref) /Name /\(arrowHead ? "Arrow" : "Line") "
                + "/Subj (\(arrowHead ? "Arrow" : "Line")) /C [\(color.components)] /AP << /N \(ap.ref) >> >>"
            return [b.add(dict)]
        }
    }

    private static func drawStampShape(_ c: inout ContentStream, from: Pt, to: Pt, hex: String, width: Double,
                                       arrowHead: Bool) {
        c.save()
        c.strokeColor(HexColor(hex))
        c.lineWidth(width)
        c.raw("1 J 1 j")
        c.polyline([from, to])
        c.raw("S")
        if arrowHead {
            let head = PageBuilder.arrowHead(from: from, to: to)
            c.polyline([head.left, to, head.right])
            c.raw("S")
        }
        c.restore()
    }

    // MARK: Reduced: flattened content and text layer

    private static func flatten(_ item: ResolvedItem, into c: inout ContentStream) {
        switch item.drawing {
        case .pageContent:
            break
        case let .ink(strokes, hex, width, highlighter):
            for s in inkContent(strokes: strokes, hex: hex, width: width, highlighter: highlighter) { c.raw(s) }
        case let .freeText(rect, _, appearanceText, fontSize, hex):
            c.save()
            c.raw("0.97 g")
            c.strokeColor(HexColor("#8A8F98"))
            c.lineWidth(0.5)
            c.rect(x: rect[0] + 0.25, y: rect[1] + 0.25, w: rect[2] - 0.5, h: rect[3] - 0.5)
            c.raw("B")
            c.restore()
            c.text(appearanceText, font: "F1", size: fontSize, x: rect[0] + 8, y: rect[1] + rect[3] / 2 - fontSize * 0.35,
                   color: HexColor(hex))
        case let .stamp(from, to, hex, width, arrowHead):
            drawStampShape(&c, from: from, to: to, hex: hex, width: width, arrowHead: arrowHead)
        }
    }

    /// Invisible (render mode 3) recognized text, one run per handwritten word, scaled to the word's box.
    private static func textLayer(page: PageBuilder, substitutions: [String: String])
        -> (content: String, items: [GoodnotesTruthItem], errors: [GoodnotesOCRError]) {
        var c = ContentStream()
        var items: [GoodnotesTruthItem] = []
        var errors: [GoodnotesOCRError] = []
        for item in page.items where item.truth.kind == .inkWord {
            guard let truthText = item.truth.text, let baseline = item.baseline, let size = item.fontSize else { continue }
            let recognized = substitutions[truthText] ?? truthText
            let bbox = item.truth.bbox
            let natural = HelveticaMetrics.width(recognized, bold: false, size: size)
            let scale = natural > 0 ? round2(100 * (bbox[2] - item.truth.lineWidthOrZero) / natural) : 100
            c.text(recognized, font: "F1", size: size, x: bbox[0] + item.truth.lineWidthOrZero / 2, y: baseline,
                   renderMode: 3, horizontalScale: scale)
            let ocrID = item.truth.id + "-ocr"
            items.append(GoodnotesTruthItem(
                id: ocrID, kind: .ocrWord, text: recognized, colorHex: nil, lineWidth: nil, bbox: bbox,
                strokeCount: 0, annotationCount: 0, annotationSubtype: nil, lineID: item.truth.lineID,
                emphasis: recognized == truthText ? nil : "recognitionError", relatedItemID: item.truth.id,
                relatedItemIDs: [item.truth.id], sourceItemID: nil, endpoints: nil, appearanceText: nil))
            if recognized != truthText {
                errors.append(GoodnotesOCRError(page: page.number, itemID: ocrID, inkWordID: item.truth.id,
                                                truth: truthText, recognized: recognized))
            }
        }
        return (c.text, items, errors)
    }
}

private extension GoodnotesTruthItem {
    var lineWidthOrZero: Double { lineWidth ?? 0 }
}
