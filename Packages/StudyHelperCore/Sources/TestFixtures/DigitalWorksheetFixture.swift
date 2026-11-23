import Foundation

/// A synthetic *digital worksheet*: a PDF with real, visible embedded text (Helvetica and Helvetica-Bold, colored
/// runs, underlines, a bullet list and a table) and no annotations. It stands for worksheets and web exports whose
/// text is taken directly from the PDF instead of being recognized (SPEC §1/§2: "eingebetteter PDF-Text").
///
/// There is deliberately no invisible text layer (render mode 3) in this file: an invisible layer makes a PDF look like a
/// reduced Goodnotes export to the Goodnotes parser. Invisible text is tested with the reduced Goodnotes fixture.
///
/// The ground truth reuses the Goodnotes truth format: every text run is a `worksheetText` item (`emphasis` lists
/// `bold`, `colored`, `underline`, `doubleUnderline`). Regenerate with
/// `swift run --package-path Packages/StudyHelperCore make-fixtures`.
public enum DigitalWorksheetFixture {
    public static let name = "Arbeitsblatt_digital"
    public static var fileName: String { name + ".pdf" }
    public static var truthFileName: String { name + ".truth.json" }
    public static var url: URL { resourceURL(fileName) }
    public static var truthURL: URL { resourceURL(truthFileName) }

    public static func loadTruth() throws -> GoodnotesGroundTruth {
        try GoodnotesGroundTruth.decode(from: Data(contentsOf: truthURL))
    }

    /// Generates PDF and ground truth in memory. Deterministic.
    public static func generate() throws -> GeneratedFixture {
        let pages = [page1(), page2()]
        let rendered = render(pages: pages)
        return GeneratedFixture(pdfData: rendered.pdf, truthData: try rendered.truth.jsonData(), truth: rendered.truth)
    }

    private static func resourceURL(_ file: String) -> URL {
        if let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Resources/DigitalWorksheet") {
            return url
        }
        if let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "DigitalWorksheet") {
            return url
        }
        return Bundle.module.bundleURL.appendingPathComponent("Resources/DigitalWorksheet/\(file)")
    }

    // MARK: Content

    private static let width = GoodnotesFixtureSpec.a4Width
    private static let height = GoodnotesFixtureSpec.a4Height

    private static func page1() -> DigitalPage {
        let p = DigitalPage(number: 1)
        // Title with a rule below that is wider than the title (a design element, not an underline).
        p.line(x: 60, baseline: 770, size: 22, [.init("Arbeitsblatt: Fotosynthese", bold: true)])
        p.rule(x1: 60, x2: 535, y: 764, width: 1)

        p.line(x: 60, baseline: 730, size: 12, [.init("Pflanzen wandeln Lichtenergie in chemische Energie um.")])
        p.line(x: 60, baseline: 712, size: 12, [
            .init("Der "), .init("Chloroplast", bold: true), .init(" ist der Ort der "),
            .init("Fotosynthese", hex: PageBuilder.red), .init("."),
        ])
        p.line(x: 60, baseline: 694, size: 12, [
            .init("Das "), .init("Chlorophyll", underline: .stroked), .init(" absorbiert vor allem "),
            .init("rotes und blaues", hex: PageBuilder.blue), .init(" Licht."),
        ])
        p.line(x: 60, baseline: 676, size: 12, [
            .init("Merke: ", bold: true, hex: PageBuilder.green), .init("Ohne Licht keine Fotosynthese."),
        ])
        p.line(x: 60, baseline: 658, size: 12, [
            .init("Dabei entsteht "), .init("Sauerstoff", underline: .double), .init(" und "),
            .init("Traubenzucker", underline: .filled), .init("."),
        ])

        // Bullet list and numbered tasks.
        p.line(x: 60, baseline: 620, size: 14, [.init("Das braucht die Pflanze:", bold: true)])
        p.line(x: 72, baseline: 600, size: 12, [.init("\u{2022} Kohlenstoffdioxid aus der Luft")])
        p.line(x: 72, baseline: 584, size: 12, [.init("\u{2022} Wasser aus dem Boden")])
        p.line(x: 72, baseline: 568, size: 12, [.init("\u{2022} Licht von der Sonne")])
        p.line(x: 60, baseline: 536, size: 12, [.init("1. Lies den Text aufmerksam.")])
        p.line(x: 60, baseline: 518, size: 12, [.init("2. Markiere die wichtigsten Begriffe.")])

        // Table with grid lines (the borders are not underlines).
        let columns: [Double] = [60, 230, 400, 535]
        let rowHeight = 26.0
        let top = 480.0
        let cells = [["Stoff", "Rolle", "Beispiel"], ["Wasser", "Ausgangsstoff", "H2O"], ["Glucose", "Produkt", "C6H12O6"]]
        p.grid(columns: columns, top: top, rowHeight: rowHeight, rows: cells.count)
        for (r, row) in cells.enumerated() {
            for (c, text) in row.enumerated() {
                p.line(x: columns[c] + 8, baseline: top - rowHeight * Double(r + 1) + 9, size: 12,
                       [.init(text, bold: r == 0)])
            }
        }
        return p
    }

    private static func page2() -> DigitalPage {
        let p = DigitalPage(number: 2)
        p.line(x: 60, baseline: 770, size: 18, [.init("Seite 2: Zusammenfassung", bold: true)])
        p.line(x: 60, baseline: 740, size: 12, [
            .init("Die "), .init("Zellwand", bold: true, hex: PageBuilder.red), .init(" gibt der Pflanzenzelle Halt."),
        ])
        p.line(x: 60, baseline: 722, size: 12, [.init("Der Zellkern enth\u{00E4}lt die Erbinformation.")])
        return p
    }

    // MARK: Rendering

    private static func render(pages: [DigitalPage]) -> (pdf: Data, truth: GoodnotesGroundTruth) {
        var b = PDFBuilder()
        let catalog = b.reserve()
        let pagesRef = b.reserve()
        let info = b.reserve()
        let helv = b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let helvBold = b.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
        var kids: [PDFRef] = []
        var truthPages: [GoodnotesTruthPage] = []
        let mediaBox = "[0 0 \(pdfNumber(width)) \(pdfNumber(height))]"
        for page in pages {
            let pageRef = b.reserve()
            kids.append(pageRef)
            let contentRef = b.addStream("", data: Data(page.content.text.utf8))
            let resources = "<< /Font << /F1 \(helv.ref) /F2 \(helvBold.ref) >> /ProcSet [/PDF /Text] >>"
            b.set(pageRef, "<< /Type /Page /Parent \(pagesRef.ref) /MediaBox \(mediaBox) /Resources \(resources) "
                + "/Contents \(contentRef.ref) >>")
            truthPages.append(GoodnotesTruthPage(pageNumber: page.number, items: page.items))
        }
        b.set(pagesRef, "<< /Type /Pages /Kids [" + kids.map(\.ref).joined(separator: " ") + "] /Count \(kids.count) >>")
        b.set(catalog, "<< /Type /Catalog /Pages \(pagesRef.ref) /Lang (de-DE) >>")
        b.set(info, "<< /Producer \(pdfTextString("StudyHelper TestFixtures \u{2013} synthetisch, digitales Arbeitsblatt")) "
            + "/Title \(pdfTextString("Arbeitsblatt digital (synthetisch)")) >>")
        let truth = GoodnotesGroundTruth(
            fileName: fileName, variant: "digital", generator: GoodnotesFixtureSpec.generatorTag,
            handwritingFont: "none", handwritingFontVersion: "none", pageCount: pages.count,
            pageWidth: width, pageHeight: height, pages: truthPages, ocrErrors: [])
        return (b.serialize(root: catalog, info: info), truth)
    }
}

/// Underline style of a run.
enum DigitalUnderline {
    case none
    /// Thin stroked line (`m l S`).
    case stroked
    /// Thin filled rectangle (`re f`).
    case filled
    /// Two stroked lines.
    case double
}

/// One text run of a line.
struct DigitalRun {
    var text: String
    var bold: Bool
    var hex: String
    var underline: DigitalUnderline

    init(_ text: String, bold: Bool = false, hex: String = PageBuilder.black, underline: DigitalUnderline = .none) {
        self.text = text
        self.bold = bold
        self.hex = hex
        self.underline = underline
    }
}

/// Builds one digital worksheet page: text runs (page content), rules and a grid.
final class DigitalPage {
    let number: Int
    private(set) var content = ContentStream()
    private(set) var items: [GoodnotesTruthItem] = []
    private var counter = 0

    init(number: Int) { self.number = number }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "p\(number)-\(prefix)\(pad2(counter))"
    }

    /// A line of runs starting at `x`. Every run becomes one truth item; leading/trailing spaces stay in the PDF text.
    func line(x: Double, baseline: Double, size: Double, _ runs: [DigitalRun]) {
        var cursor = x
        for run in runs {
            let runWidth = HelveticaMetrics.width(run.text, bold: run.bold, size: size)
            content.save()
            content.text(run.text, font: run.bold ? "F2" : "F1", size: size, x: cursor, y: baseline,
                         color: HexColor(run.hex))
            // Underlines span the visible characters only (not the surrounding spaces).
            let leading = run.text.prefix { $0 == " " }
            let trailing = run.text.reversed().prefix { $0 == " " }
            let startX = cursor + HelveticaMetrics.width(String(leading), bold: run.bold, size: size)
            let endX = cursor + runWidth - HelveticaMetrics.width(String(trailing), bold: run.bold, size: size)
            switch run.underline {
            case .none: break
            case .stroked:
                content.strokeColor(HexColor(run.hex))
                content.lineWidth(0.7)
                content.polyline([Pt(startX, baseline - 2.5), Pt(endX, baseline - 2.5)])
                content.raw("S")
            case .filled:
                content.fillColor(HexColor(run.hex))
                content.rect(x: startX, y: baseline - 3.0, w: endX - startX, h: 0.8)
                content.raw("f")
            case .double:
                content.strokeColor(HexColor(run.hex))
                content.lineWidth(0.5)
                content.polyline([Pt(startX, baseline - 2.0), Pt(endX, baseline - 2.0)])
                content.raw("S")
                content.polyline([Pt(startX, baseline - 4.0), Pt(endX, baseline - 4.0)])
                content.raw("S")
            }
            content.restore()

            var tags: [String] = []
            if run.bold { tags.append("bold") }
            if run.hex != PageBuilder.black { tags.append("colored") }
            switch run.underline {
            case .none: break
            case .stroked, .filled: tags.append("underline")
            case .double: tags.append("doubleUnderline")
            }
            let trimmed = run.text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                items.append(GoodnotesTruthItem(
                    id: nextID("ws"), kind: .worksheetText, text: trimmed, colorHex: HexColor(run.hex).hex,
                    lineWidth: nil, bbox: [round2(startX), round2(baseline - 0.21 * size), round2(endX - startX),
                                           round2(0.93 * size)],
                    strokeCount: 0, annotationCount: 0, annotationSubtype: nil, lineID: nil,
                    emphasis: tags.isEmpty ? nil : tags.joined(separator: ","),
                    relatedItemID: nil, sourceItemID: nil, endpoints: nil, appearanceText: nil))
            }
            cursor += runWidth
        }
    }

    /// A horizontal rule (design element).
    func rule(x1: Double, x2: Double, y: Double, width: Double) {
        content.save()
        content.strokeColor(HexColor("#333333"))
        content.lineWidth(width)
        content.polyline([Pt(x1, y), Pt(x2, y)])
        content.raw("S")
        content.restore()
    }

    /// Table grid: horizontal lines at every row boundary, vertical lines at every column boundary.
    func grid(columns: [Double], top: Double, rowHeight: Double, rows: Int) {
        content.save()
        content.strokeColor(HexColor("#555555"))
        content.lineWidth(0.8)
        let bottom = top - rowHeight * Double(rows)
        for r in 0...rows {
            let y = top - rowHeight * Double(r)
            content.polyline([Pt(columns.first!, y), Pt(columns.last!, y)])
            content.raw("S")
        }
        for x in columns {
            content.polyline([Pt(x, top), Pt(x, bottom)])
            content.raw("S")
        }
        content.restore()
    }
}
