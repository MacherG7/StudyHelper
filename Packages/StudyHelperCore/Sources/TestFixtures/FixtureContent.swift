import Foundation

/// Describes one fixture file: which content it shows and in which PDF flavor it is written.
/// The same spec drives the PDF and the ground-truth JSON.
public struct GoodnotesFixtureSpec: Sendable {
    public enum Variant: String, Codable, Sendable {
        /// Goodnotes "editable" export: strokes, text boxes and shapes are annotations.
        case editable
        /// Goodnotes "reduced" export: everything flattened, plus an invisible recognized-text layer.
        case reduced
    }

    public enum Content: String, Sendable {
        /// Photosynthesis notes: handwriting in four colors, highlighter, FreeText, Stamp, worksheet, mind map, table.
        case fotosynthese
        /// Different note with a different page count (negative pairing test).
        case andereNotiz
        /// Different note with the same page count but US Letter size (negative pairing test).
        case andereGroesse
    }

    /// File name without extension.
    public let name: String
    public let title: String
    public let variant: Variant
    public let content: Content
    public let pageWidth: Double
    public let pageHeight: Double
    /// Deliberate recognition errors of the text layer: written word -> recognized word (reduced only).
    public let ocrSubstitutions: [String: String]

    public static let a4Width = 595.28
    public static let a4Height = 841.89
    public static let letterWidth = 612.0
    public static let letterHeight = 792.0

    public static let producer = "StudyHelper TestFixtures \u{2013} synthetisch, Goodnotes-Struktur"
    public static let generatorTag = "StudyHelper TestFixtures (synthetic, Goodnotes structure)"
}

enum FixtureContent {
    static let defaultOCRErrors: [String: String] = [
        "grüne": "grune",
        "Chlorophyll": "Chlorophyl",
        "Blätter": "Blatter",
        "Mitochondrien": "Mitochondnen",
        "Ökosystem": "Okosystem",
    ]

    static func pages(for spec: GoodnotesFixtureSpec) -> [PageBuilder] {
        switch spec.content {
        case .fotosynthese: return fotosynthese(spec)
        case .andereNotiz: return andereNotiz(spec)
        case .andereGroesse: return andereGroesse(spec)
        }
    }

    // MARK: Fotosynthese (3 pages)

    private static func fotosynthese(_ spec: GoodnotesFixtureSpec) -> [PageBuilder] {
        [fotosynthesePage1(spec), fotosynthesePage2(spec), fotosynthesePage3(spec)]
    }

    private static func fotosynthesePage1(_ spec: GoodnotesFixtureSpec) -> PageBuilder {
        let p = PageBuilder(number: 1, width: spec.pageWidth, height: spec.pageHeight)
        p.linedPaper()
        let x = 80.0

        let heading = p.handwrittenLine("Fotosynthese", x: x, baseline: p.baseline(1), size: 36,
                                        hex: PageBuilder.black, width: 2.2)
        p.underline(heading, hex: PageBuilder.black, width: 2.4)

        let l1 = p.handwrittenLine("Pflanzen wandeln Lichtenergie", x: x, baseline: p.baseline(3), size: 22)
        let l2 = p.handwrittenLine("in chemische Energie um", x: x, baseline: p.baseline(5), size: 22)

        let ort = p.handwrittenLine("Ort: Chloroplasten", x: x, baseline: p.baseline(7), size: 22)
        p.highlight([ort[1]])

        p.handwrittenLine("Chlorophyll ist der grüne Blattfarbstoff", x: x, baseline: p.baseline(9), size: 22,
                          hex: PageBuilder.red)
        p.handwrittenLine("Beispiel: große Blätter im Sommer", x: x, baseline: p.baseline(11), size: 22,
                          hex: PageBuilder.blue)
        p.handwrittenLine("Merke: Ohne Licht keine Fotosynthese", x: x, baseline: p.baseline(13), size: 22,
                          hex: PageBuilder.green)

        // Multi-word highlighter: one stroke over two adjacent words.
        let speicher = p.handwrittenLine("Energie wird in Traubenzucker gespeichert", x: x, baseline: p.baseline(15),
                                         size: 22)
        p.highlight([speicher[3], speicher[4]])

        // Near-miss highlighter: meant for "Sauerstoff" only, but it reaches a little into the word before it.
        let neben = p.handwrittenLine("Nebenprodukt: Sauerstoff entweicht", x: x, baseline: p.baseline(16), size: 22)
        let before = p.rect(of: neben[0]), target = p.rect(of: neben[1])
        p.highlight([neben[1]], bleedLeft: target[0] - (before[0] + before[2]) + 3.5, bleedRight: 0)

        // Arrow (shape tool) from "Lichtenergie" down to "chemische Energie".
        let from = p.rect(of: l1[2])
        let to = p.rect(of: l2[1])
        p.stamp(from: Pt(from[0] + from[2] * 0.55, from[1] - 6),
                to: Pt(to[0] + to[2] * 0.5, to[1] + to[3] + 7),
                arrow: true, hex: PageBuilder.black, width: 2,
                sourceItemID: l1[2], targetItemID: l2[1])

        p.freeText("Formel: 6 CO\u{2082} + 6 H\u{2082}O \u{2192} C\u{2086}H\u{2081}\u{2082}O\u{2086} + 6 O\u{2082}",
                   appearanceText: "Formel: 6 CO2 + 6 H2O -> C6H12O6 + 6 O2",
                   x: x, y: 100, w: 440, h: 40, fontSize: 15)
        return p
    }

    private static func fotosynthesePage2(_ spec: GoodnotesFixtureSpec) -> PageBuilder {
        let p = PageBuilder(number: 2, width: spec.pageWidth, height: spec.pageHeight)
        p.linedPaper()
        p.panel(x: 36, y: 70, w: 523, h: 730)

        p.worksheetRun("Arbeitsblatt: Die Zelle", x: 60, baseline: 758, size: 20, bold: true)
        p.worksheetImage(RasterImage.cellDiagram(), x: 60, y: 540, w: 240, h: 180)
        p.worksheetRun("Pflanzenzelle", x: 330, baseline: 700, size: 13, bold: true)
        p.worksheetRun("(schematisch, vereinfacht)", x: 330, baseline: 682, size: 11)

        p.worksheetRun("1. Benenne die Zellbestandteile.", x: 60, baseline: 508, size: 13)
        let answers = ["Zellmembran", "Mitochondrien", "Zellwand"]
        var answerIDs: [String] = []
        for (i, answer) in answers.enumerated() {
            let base = 470 - 42 * Double(i)
            p.worksheetRun(["a)", "b)", "c)"][i], x: 60, baseline: base, size: 13)
            p.worksheetRule(x1: 84, x2: 330, y: base - 3)
            answerIDs += p.handwrittenLine(answer, x: 92, baseline: base, size: 20, hex: PageBuilder.blue,
                                           width: 1.6)
        }
        p.circle(answerIDs[1], hex: PageBuilder.black)
        p.doubleUnderline(answerIDs[2], hex: PageBuilder.red)

        var cursor = 60.0
        cursor = p.worksheetRun("Der ", x: cursor, baseline: 330, size: 13).endX
        cursor = p.worksheetRun("Zellkern", x: cursor, baseline: 330, size: 13, hex: PageBuilder.red).endX
        cursor = p.worksheetRun(" enthält die ", x: cursor, baseline: 330, size: 13).endX
        cursor = p.worksheetRun("Erbinformation", x: cursor, baseline: 330, size: 13, underline: true).endX
        p.worksheetRun(".", x: cursor, baseline: 330, size: 13)

        cursor = p.worksheetRun("Merke: ", x: 60, baseline: 296, size: 13, bold: true).endX
        p.worksheetRun("Die Zellwand gibt der Pflanzenzelle Halt.", x: cursor, baseline: 296, size: 13)
        return p
    }

    private static func fotosynthesePage3(_ spec: GoodnotesFixtureSpec) -> PageBuilder {
        let p = PageBuilder(number: 3, width: spec.pageWidth, height: spec.pageHeight)
        p.linedPaper()

        let center = p.handwrittenLine("Ökosystem", x: 215, baseline: 640, size: 30, hex: PageBuilder.black,
                                       width: 2.0)[0]
        let n1 = p.handwrittenLine("Produzenten", x: 70, baseline: 520, size: 22, hex: PageBuilder.green)[0]
        let n2 = p.handwrittenLine("Konsumenten", x: 360, baseline: 520, size: 22, hex: PageBuilder.red)[0]
        let n3 = p.handwrittenLine("Destruenten", x: 225, baseline: 420, size: 22, hex: PageBuilder.blue)[0]

        let c = p.rect(of: center)
        let cx = c[0] + c[2] / 2, bottom = c[1] - 8
        for (node, ax) in [(n1, cx - c[2] * 0.3), (n2, cx + c[2] * 0.3), (n3, cx)] {
            let r = p.rect(of: node)
            p.stamp(from: Pt(ax, bottom), to: Pt(r[0] + r[2] / 2, r[1] + r[3] + 9), arrow: false,
                    hex: PageBuilder.black, width: 2, sourceItemID: center, targetItemID: node)
        }

        // Hand-drawn table: 3 rows x 2 columns.
        let tx = 90.0, top = 310.0, rowH = 42.0, colW = 200.0
        p.tableGrid(x: tx, top: top, columnWidths: [colW, colW], rowHeight: rowH, rows: 3)
        let cells = [["Organismus", "Rolle"], ["Gras", "Produzent"], ["Fuchs", "Konsument"]]
        for (r, row) in cells.enumerated() {
            for (c, text) in row.enumerated() {
                p.handwrittenLine(text, x: tx + Double(c) * colW + 14, baseline: top - rowH * Double(r + 1) + 13,
                                  size: 20)
            }
        }
        return p
    }

    // MARK: Other notes (negative pairing tests)

    private static func andereNotiz(_ spec: GoodnotesFixtureSpec) -> [PageBuilder] {
        let p = PageBuilder(number: 1, width: spec.pageWidth, height: spec.pageHeight)
        p.linedPaper()
        let h = p.handwrittenLine("Englisch Vokabeln", x: 80, baseline: p.baseline(1), size: 34, width: 2.2)
        p.underline(h)
        p.handwrittenLine("the apple = der Apfel", x: 80, baseline: p.baseline(3), size: 22, hex: PageBuilder.blue)
        p.handwrittenLine("the house = das Haus", x: 80, baseline: p.baseline(5), size: 22, hex: PageBuilder.red)
        p.handwrittenLine("the tree = der Baum", x: 80, baseline: p.baseline(7), size: 22, hex: PageBuilder.green)
        return [p]
    }

    private static func andereGroesse(_ spec: GoodnotesFixtureSpec) -> [PageBuilder] {
        let titles = ["Bruchrechnung", "Geometrie", "Wiederholung"]
        let lines = ["Zähler durch Nenner teilen", "Winkelsumme im Dreieck 180 Grad", "Alle Übungen noch einmal rechnen"]
        let colors = [PageBuilder.blue, PageBuilder.red, PageBuilder.green]
        return (0..<3).map { i in
            let p = PageBuilder(number: i + 1, width: spec.pageWidth, height: spec.pageHeight)
            p.linedPaper()
            let h = p.handwrittenLine(titles[i], x: 80, baseline: p.baseline(1), size: 34, width: 2.2)
            p.underline(h)
            p.handwrittenLine(lines[i], x: 80, baseline: p.baseline(3), size: 21, hex: colors[i])
            return p
        }
    }
}
