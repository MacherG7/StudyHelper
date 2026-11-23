import CoreGraphics
import Foundation
import Testing
@testable import TestFixtures
#if canImport(PDFKit)
import PDFKit
#endif

private let exactFormula = "Formel: 6 CO\u{2082} + 6 H\u{2082}O \u{2192} C\u{2086}H\u{2081}\u{2082}O\u{2086} + 6 O\u{2082}"

private func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }

@Suite("Goodnotes-Fixtures: bearbeitbares PDF (Annotationen)")
struct EditableFixtureTests {
    let pdf: RawPDF
    init() throws { pdf = try RawPDF(url: GoodnotesFixture.fotosyntheseEditable.url) }

    @Test("3 Seiten im Format A4")
    func pagesAndSize() throws {
        #expect(pdf.pageCount == 3)
        for n in 1...3 {
            let box = try pdf.page(n).mediaBox
            #expect(abs(box.width - 595.28) < 0.01)
            #expect(abs(box.height - 841.89) < 0.01)
        }
    }

    @Test("Jede Ink-Annotation hat genau einen InkList-Eintrag, Farbe und Strichbreite")
    func inkStructure() throws {
        var inkCount = 0
        for n in 1...3 {
            for a in try pdf.page(n).annotations where a.subtype == "Ink" {
                inkCount += 1
                let list = try #require(a.inkList)
                #expect(list.count == 1)
                #expect(list[0].count >= 4 && list[0].count.isMultiple(of: 2), "mindestens 2 Punkte als x/y-Paare")
                #expect(a.color?.count == 3)
                #expect((a.borderWidth ?? 0) > 0)
                #expect(a.flags == 4)
            }
        }
        #expect(inkCount > 100)
    }

    @Test("Mindestens 4 verschiedene nicht-gelbe Stiftfarben")
    func penColors() throws {
        var colors = Set<String>()
        for n in 1...3 {
            for a in try pdf.page(n).annotations where a.subtype == "Ink" && !a.isYellow {
                colors.insert(try #require(a.colorHex))
            }
        }
        #expect(colors.count >= 4)
        #expect(colors.isSuperset(of: ["#000000", "#D32F2F", "#1565C0", "#2E7D32"]))
    }

    @Test("Gelbe Textmarker mit Breite 18 und Multiply im Erscheinungsbild")
    func highlighter() throws {
        let highlighters = try (1...3).flatMap { try pdf.page($0).annotations }
            .filter { $0.subtype == "Ink" && $0.isYellow }
        #expect(highlighters.count == 3, "einzeln, über zwei Wörter, Beinahe-Treffer")
        for h in highlighters {
            #expect(abs((h.borderWidth ?? 0) - 18) < 0.01)
            #expect(h.appearanceUsesMultiply)
        }
    }

    @Test("FreeText-Contents ist exakt der Unicode-Text (UTF-16BE)")
    func freeText() throws {
        let free = try (1...3).flatMap { try pdf.page($0).annotations }.filter { $0.subtype == "FreeText" }
        #expect(free.count == 1)
        #expect(free.first?.contents == exactFormula)
        #expect(free.first?.contentsBytes?.prefix(2) == [0xFE, 0xFF])
    }

    @Test("Stamp-Annotationen auf Seite 1 und 3")
    func stamps() throws {
        for n in [1, 3] {
            #expect(try pdf.page(n).annotations.contains { $0.subtype == "Stamp" })
        }
        #expect(try !pdf.page(2).annotations.contains { $0.subtype == "Stamp" })
    }

    @Test("Jede Annotation hat ein normales Erscheinungsbild (AP/N)")
    func appearance() throws {
        for n in 1...3 {
            let annotations = try pdf.page(n).annotations
            #expect(!annotations.isEmpty)
            for a in annotations {
                #expect(a.hasNormalAppearance, "\(a.subtype ?? "?") \(a.name ?? "") ohne /AP /N")
                #expect(a.rect?.count == 4)
            }
        }
    }

    @Test("Seite 2: Rasterbild als Seiteninhalt, Text über PDFKit lesbar")
    func worksheetPage() throws {
        let images = try pdf.page(2).imageXObjects
        #expect(images.count == 1)
        #expect(images.first?.colorSpace == "DeviceRGB")
        #expect(images.first?.bitsPerComponent == 8)
        #expect(try pdf.page(1).imageXObjects.isEmpty)
        #if canImport(PDFKit)
        let doc = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseEditable.url))
        let text = try #require(doc.page(at: 1)?.string)
        #expect(text.contains("Arbeitsblatt"))
        #expect(text.contains("Zellkern"))
        #expect(text.contains("Erbinformation"))
        #expect(text.contains("enthält"), "Umlaut im Seitentext")
        #endif
    }

    @Test("Xref-Tabelle stimmt, keine Zeitstempel und keine zufällige ID")
    func fileHygiene() throws {
        let data = try Data(contentsOf: GoodnotesFixture.fotosyntheseEditable.url)
        #expect(validateXref(data).isEmpty, "\(validateXref(data))")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("%PDF-1.7"))
        #expect(!text.contains("/CreationDate"))
        #expect(!text.contains("/ModDate"))
        #expect(!text.contains("/ID ["))
        #expect(text.contains("/Producer"))
    }
}

#if canImport(PDFKit)
@Suite("Goodnotes-Fixtures: reduziertes PDF (Textebene)")
struct ReducedFixtureTests {
    let editable: RawPDF
    let reduced: RawPDF
    init() throws {
        editable = try RawPDF(url: GoodnotesFixture.fotosyntheseEditable.url)
        reduced = try RawPDF(url: GoodnotesFixture.fotosyntheseReduced.url)
    }

    @Test("Gleiche Seitenzahl und MediaBox wie das bearbeitbare PDF")
    func samePagesAndSize() throws {
        #expect(reduced.pageCount == editable.pageCount)
        for n in 1...reduced.pageCount {
            #expect(try reduced.page(n).mediaBox == editable.page(n).mediaBox)
        }
    }

    @Test("Keine Annotationen auf keiner Seite")
    func noAnnotations() throws {
        for n in 1...reduced.pageCount {
            let page = try reduced.page(n)
            #expect(!page.hasAnnotsKey)
            #expect(page.annotations.isEmpty)
        }
        let doc = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        for i in 0..<doc.pageCount { #expect(doc.page(at: i)?.annotations.isEmpty == true) }
    }

    @Test("Arbeitsblatt-Bild und Text bleiben Seiteninhalt")
    func worksheetFlattened() throws {
        #expect(try reduced.page(2).imageXObjects.count == 1)
        let doc = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        let text = try #require(doc.page(at: 1)?.string)
        #expect(text.contains("Arbeitsblatt"))
        #expect(text.contains("Zellkern"))
    }

    @Test("PDFKit liest die erkannten Wörter inklusive der bewussten Fehler")
    func textLayer() throws {
        let doc = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        let page1 = try #require(doc.page(at: 0)?.string)
        for word in ["Fotosynthese", "Lichtenergie", "Chloroplasten", "Chlorophyl", "grune", "Blatter", "Sommer"] {
            #expect(page1.contains(word), "Seite 1 ohne \(word)")
        }
        #expect(!page1.contains("Chlorophyll"), "der Fehler ersetzt das richtige Wort")
        let page2 = try #require(doc.page(at: 1)?.string)
        #expect(page2.contains("Mitochondnen"))
        #expect(page2.contains("Zellmembran"))
        let page3 = try #require(doc.page(at: 2)?.string)
        #expect(page3.contains("Okosystem"))
        #expect(page3.contains("Produzenten"))
        #expect(page3.contains("Konsument"))
    }

    @Test("PDFKit trennt die Wörter der Textebene durch Leerzeichen")
    func textLayerWordsAreSpaceSeparated() throws {
        let doc = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        let page1 = try #require(doc.page(at: 0)?.string)
        #expect(page1.contains("Pflanzen wandeln"), "\(page1.prefix(200))")
        #expect(page1.contains("wandeln Lichtenergie"))
        #expect(page1.contains("in chemische Energie um"))
        #expect(page1.contains("Ort: Chloroplasten"))
    }

    @Test("PDFKit-Auswahlrechtecke der Textebene liegen an den Wortpositionen der Truth-Datei")
    func textPositions() throws {
        let doc = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseReduced.url))
        let truth = try GoodnotesFixture.fotosyntheseReduced.loadTruth()
        let probes: [(page: Int, text: String)] = [
            (1, "Chlorophyl"), (1, "Chloroplasten"), (1, "Blatter"), (1, "Sommer"), (2, "Mitochondnen"), (3, "Okosystem"),
        ]
        for probe in probes {
            let page = try #require(doc.page(at: probe.page - 1))
            let selection = try #require(
                doc.findString(probe.text, withOptions: [.literal]).first { $0.pages.contains(page) },
                "\(probe.text) nicht gefunden")
            let bounds = selection.bounds(for: page)
            let expected = try #require(
                truth.items(ofKind: .ocrWord, onPage: probe.page).first { $0.text == probe.text })
            let box = rect(expected.bbox)
            let overlap = bounds.intersection(box)
            #expect(!overlap.isNull)
            #expect(overlap.width * overlap.height > 0.4 * min(bounds.width * bounds.height, box.width * box.height),
                    "\(probe.text): PDFKit \(bounds) vs. Truth \(box)")
            #expect(abs(bounds.midX - box.midX) < 8, "\(probe.text) horizontal verschoben")
        }
    }
}
#endif

@Suite("Goodnotes-Fixtures: negative Zuordnungstests")
struct NegativePairingFixtureTests {
    @Test("Andere_Notiz: andere Seitenzahl")
    func differentPageCount() throws {
        let editable = try RawPDF(url: GoodnotesFixture.fotosyntheseEditable.url)
        let other = try RawPDF(url: GoodnotesFixture.andereNotizReduced.url)
        #expect(other.pageCount == 1)
        #expect(other.pageCount != editable.pageCount)
        #expect(try !other.page(1).hasAnnotsKey)
        #expect(try other.page(1).mediaBox == editable.page(1).mediaBox)
    }

    @Test("Andere_Groesse: gleiche Seitenzahl, andere Seitengröße (US Letter)")
    func differentPageSize() throws {
        let editable = try RawPDF(url: GoodnotesFixture.fotosyntheseEditable.url)
        let other = try RawPDF(url: GoodnotesFixture.andereGroesseReduced.url)
        #expect(other.pageCount == editable.pageCount)
        for n in 1...3 {
            let box = try other.page(n).mediaBox
            let editableBox = try editable.page(n).mediaBox
            #expect(box.size == CGSize(width: 612, height: 792))
            #expect(box.size != editableBox.size)
            #expect(try !other.page(n).hasAnnotsKey)
        }
    }

    @Test("Beide Negativ-PDFs haben eine Textebene")
    func textLayers() throws {
        #if canImport(PDFKit)
        let notiz = try #require(PDFDocument(url: GoodnotesFixture.andereNotizReduced.url)?.page(at: 0)?.string)
        #expect(notiz.contains("Vokabeln"))
        let groesse = try #require(PDFDocument(url: GoodnotesFixture.andereGroesseReduced.url)?.page(at: 1)?.string)
        #expect(groesse.contains("Geometrie"))
        #endif
    }
}

@Suite("Goodnotes-Fixtures: Ground Truth")
struct GroundTruthTests {
    @Test("Alle Truth-Dateien lassen sich dekodieren und passen zu ihrem PDF", arguments: GoodnotesFixture.allCases)
    func decodesAndMatchesFile(fixture: GoodnotesFixture) throws {
        let truth = try fixture.loadTruth()
        let pdf = try RawPDF(url: fixture.url)
        #expect(truth.fileName == fixture.fileName)
        #expect(truth.pageCount == pdf.pageCount)
        #expect(truth.pages.map(\.pageNumber) == Array(1...truth.pageCount))
        for n in 1...pdf.pageCount {
            let box = try pdf.page(n).mediaBox
            #expect(abs(box.width - truth.pageWidth) < 0.01 && abs(box.height - truth.pageHeight) < 0.01)
        }
        // Stored JSON is exactly the stable encoding of the decoded value.
        #expect(try truth.jsonData() == Data(contentsOf: fixture.truthURL))
    }

    @Test("Ink-, FreeText- und Stamp-Anzahl pro Seite stimmen mit der Truth-Datei überein")
    func annotationCountsMatch() throws {
        let fixture = GoodnotesFixture.fotosyntheseEditable
        let truth = try fixture.loadTruth()
        let pdf = try RawPDF(url: fixture.url)
        for n in 1...3 {
            let annotations = try pdf.page(n).annotations
            let items = truth.pages[n - 1].items
            for subtype in ["Ink", "FreeText", "Stamp"] {
                let expected = items.filter { $0.annotationSubtype == subtype }.reduce(0) { $0 + $1.annotationCount }
                #expect(annotations.filter { $0.subtype == subtype }.count == expected, "Seite \(n) \(subtype)")
            }
            #expect(annotations.count == truth.annotationCount(onPage: n))
        }
    }

    @Test("Annotationen lassen sich über /NM den Truth-Items zuordnen; Farbe, Breite und Lage stimmen")
    func annotationsMatchItems() throws {
        let fixture = GoodnotesFixture.fotosyntheseEditable
        let truth = try fixture.loadTruth()
        let pdf = try RawPDF(url: fixture.url)
        for n in 1...3 {
            let byItem = Dictionary(grouping: try pdf.page(n).annotations) {
                ($0.name ?? "").split(separator: "#").first.map(String.init) ?? ""
            }
            for item in truth.pages[n - 1].items where item.annotationCount > 0 {
                let group = try #require(byItem[item.id], "\(item.id) ohne Annotation")
                #expect(group.count == item.annotationCount, "\(item.id)")
                let box = rect(item.bbox).insetBy(dx: -2, dy: -2)
                for a in group {
                    if item.kind != .freeText { #expect(a.colorHex == item.colorHex, "\(item.id) Farbe") }
                    if item.kind == .inkWord || item.kind == .highlighter || item.kind == .underline {
                        #expect(abs((a.borderWidth ?? -1) - (item.lineWidth ?? -2)) < 0.001, "\(item.id) Breite")
                    }
                    if let points = a.inkList?.first {
                        for i in stride(from: 0, to: points.count, by: 2) {
                            #expect(box.contains(CGPoint(x: points[i], y: points[i + 1])), "\(item.id) Punkt außerhalb bbox")
                        }
                    }
                }
            }
        }
    }

    @Test("Erwartete Elemente und Beziehungen sind in der Truth-Datei enthalten")
    func contentOfTruth() throws {
        let truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        func word(_ text: String, page: Int) throws -> GoodnotesTruthItem {
            try #require(truth.items(ofKind: .inkWord, onPage: page).first { $0.text == text }, "\(text)")
        }
        // Highlighter -> covered word
        let hl = try #require(truth.items(ofKind: .highlighter).first)
        let covered = try word("Chloroplasten", page: 1)
        #expect(hl.relatedItemID == covered.id && hl.relatedItemIDs == [covered.id] && hl.incidentalItemIDs.isEmpty)
        #expect(hl.lineWidth == 18)
        // Covers the word horizontally and overlaps its x-height band vertically.
        #expect(hl.bbox[0] <= covered.bbox[0] && hl.bbox[0] + hl.bbox[2] >= covered.bbox[0] + covered.bbox[2])
        #expect(rect(hl.bbox).intersects(rect(covered.bbox)))
        // Underline: long, nearly horizontal, directly below the heading
        let ul = try #require(truth.items(ofKind: .underline).first)
        let heading = try word("Fotosynthese", page: 1)
        #expect(ul.relatedItemID == heading.id && ul.relatedItemIDs == [heading.id])
        #expect(ul.annotationCount == 1 && ul.bbox[3] < 4 + (ul.lineWidth ?? 0))
        #expect(ul.bbox[2] >= heading.bbox[2])
        #expect(ul.bbox[1] + ul.bbox[3] <= heading.bbox[1] + 0.5)
        // Double underline: two parallel strokes; circle: single stroke
        let dul = try #require(truth.items(ofKind: .doubleUnderline).first)
        let zellwand = try word("Zellwand", page: 2)
        let mito = try word("Mitochondrien", page: 2)
        #expect(dul.annotationCount == 2 && dul.relatedItemID == zellwand.id)
        let circle = try #require(truth.items(ofKind: .circle).first)
        #expect(circle.annotationCount == 1 && circle.relatedItemID == mito.id)
        // FreeText
        let free = try #require(truth.items(ofKind: .freeText).first)
        #expect(free.text == exactFormula)
        #expect(free.appearanceText == "Formel: 6 CO2 + 6 H2O -> C6H12O6 + 6 O2")
        // Stamps: arrow on page 1, three mind-map lines on page 3
        let arrow = try #require(truth.items(ofKind: .stamp, onPage: 1).first)
        #expect(arrow.emphasis == "arrow" && arrow.endpoints?.count == 4)
        #expect(truth.items(ofKind: .stamp, onPage: 3).count == 3)
        // Table: 4 horizontal + 3 vertical lines, 6 cell words
        #expect(truth.items(ofKind: .tableLine).count == 7)
        for cell in ["Organismus", "Rolle", "Gras", "Produzent", "Fuchs", "Konsument", "Ökosystem"] {
            _ = try word(cell, page: 3)
        }
        // Worksheet runs with formatting
        let ws = truth.items(ofKind: .worksheetText, onPage: 2)
        #expect(ws.first { $0.text == "Arbeitsblatt: Die Zelle" }?.emphasis == "bold")
        #expect(ws.first { $0.text == "Zellkern" }?.emphasis == "colored")
        #expect(ws.first { $0.text == "Erbinformation" }?.emphasis == "underline")
        #expect(truth.items(ofKind: .image, onPage: 2).count == 1)
        // Every relation resolves
        for item in truth.pages.flatMap(\.items) {
            if let id = item.relatedItemID { #expect(truth.item(withID: id) != nil, "\(item.id) -> \(id)") }
            if let id = item.sourceItemID { #expect(truth.item(withID: id) != nil, "\(item.id) <- \(id)") }
        }
    }

    @Test("Lesbarkeit: Wörter liegen auf der Seite und überlappen sich nicht", arguments: GoodnotesFixture.allCases)
    func legibility(fixture: GoodnotesFixture) throws {
        let truth = try fixture.loadTruth()
        let page = CGRect(x: 0, y: 0, width: truth.pageWidth, height: truth.pageHeight)
        for p in truth.pages {
            let words = p.items.filter { $0.kind == .inkWord }
            #expect(!words.isEmpty)
            for item in p.items { #expect(page.contains(rect(item.bbox)), "\(item.id) außerhalb der Seite") }
            for (i, a) in words.enumerated() {
                for b in words[(i + 1)...] {
                    #expect(!rect(a.bbox).intersects(rect(b.bbox)), "\(a.id) \(a.text ?? "") überlappt \(b.id) \(b.text ?? "")")
                }
            }
        }
    }

    @Test("relatedItemIDs: Textmarker über mehrere Wörter, Beinahe-Treffer und mehrwortige Unterstreichung")
    func relatedItemIDs() throws {
        let truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        func word(_ text: String) throws -> GoodnotesTruthItem {
            try #require(truth.items(ofKind: .inkWord, onPage: 1).first { $0.text == text }, "\(text)")
        }
        let highlighters = truth.items(ofKind: .highlighter, onPage: 1)
        #expect(highlighters.count == 3)
        // Consistency for every item: relatedItemID is the first of relatedItemIDs.
        for item in truth.pages.flatMap(\.items) {
            #expect(item.relatedItemID == item.relatedItemIDs.first, "\(item.id)")
            #expect(Set(item.relatedItemIDs).isDisjoint(with: item.incidentalItemIDs), "\(item.id)")
            if item.kind != .highlighter { #expect(item.incidentalItemIDs.isEmpty, "\(item.id)") }
        }

        // Multi-word highlighter over two adjacent words: both are related, one stroke covers both boxes.
        let speicher = try word("Traubenzucker"), gespeichert = try word("gespeichert")
        let multi = try #require(highlighters.first { $0.relatedItemIDs.count == 2 })
        #expect(multi.relatedItemIDs == [speicher.id, gespeichert.id])
        #expect(multi.relatedItemID == speicher.id && multi.annotationCount == 1 && multi.lineWidth == 18)
        #expect(speicher.lineID == gespeichert.lineID)
        #expect(multi.bbox[0] <= speicher.bbox[0] && multi.bbox[0] + multi.bbox[2] >= gespeichert.bbox[0] + gespeichert.bbox[2])
        #expect(multi.incidentalItemIDs.isEmpty)

        // Near miss: belongs to "Sauerstoff" only but reaches a little into "Nebenprodukt:".
        let sauerstoff = try word("Sauerstoff"), neben = try word("Nebenprodukt:"), entweicht = try word("entweicht")
        let miss = try #require(highlighters.first { $0.relatedItemIDs == [sauerstoff.id] && !$0.incidentalItemIDs.isEmpty })
        #expect(miss.incidentalItemIDs == [neben.id])
        #expect(!miss.incidentalItemIDs.contains(entweicht.id))
        // The painted area (butt caps: bbox without the 9 pt side padding) overlaps the neighbour by a few points only.
        let painted = CGRect(x: miss.bbox[0] + 9, y: miss.bbox[1], width: miss.bbox[2] - 18, height: miss.bbox[3])
        let overlap = painted.intersection(rect(neben.bbox))
        #expect(!overlap.isNull && overlap.width > 0 && overlap.width < 6, "Überlappung \(overlap)")
        #expect(overlap.width < 0.1 * neben.bbox[2])
        #expect(painted.minX < rect(sauerstoff.bbox).minX && painted.maxX >= rect(sauerstoff.bbox).maxX - 0.5)
        // The ordinary highlighters do not touch any neighbour.
        for h in highlighters where h.id != miss.id { #expect(h.incidentalItemIDs.isEmpty) }

        // Underline over several words keeps every word (Andere_Notiz heading "Englisch Vokabeln").
        let other = try GoodnotesFixture.andereNotizReduced.loadTruth()
        let ul = try #require(other.items(ofKind: .underline).first)
        #expect(ul.relatedItemIDs.compactMap { other.item(withID: $0)?.text } == ["Englisch", "Vokabeln"])
        #expect(ul.relatedItemID == ul.relatedItemIDs.first)
    }

    @Test("Stamp-bbox enthält Pfeilspitze, Linie und halbe Strichbreite")
    func stampBBoxIncludesArrowHead() throws {
        let truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        let arrow = try #require(truth.items(ofKind: .stamp, onPage: 1).first)
        let e = try #require(arrow.endpoints)
        let from = Pt(e[0], e[1]), to = Pt(e[2], e[3])
        let head = PageBuilder.arrowHead(from: from, to: to)
        let w = try #require(arrow.lineWidth)
        let box = rect(arrow.bbox)
        for p in [from, to, head.left, head.right] {
            #expect(box.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: p.x, y: p.y)), "\(p) außerhalb \(box)")
        }
        // Tight: exactly the hull of the four points grown by half the line width.
        let xs = [from.x, to.x, head.left.x, head.right.x], ys = [from.y, to.y, head.left.y, head.right.y]
        #expect(abs(box.minX - (xs.min()! - w / 2)) < 0.02 && abs(box.maxX - (xs.max()! + w / 2)) < 0.02)
        #expect(abs(box.minY - (ys.min()! - w / 2)) < 0.02 && abs(box.maxY - (ys.max()! + w / 2)) < 0.02)
        // Plain lines (mind map) have no head: bbox is just the segment.
        for line in truth.items(ofKind: .stamp, onPage: 3) {
            let p = try #require(line.endpoints)
            #expect(abs(line.bbox[0] - (min(p[0], p[2]) - 1)) < 0.02)
        }
    }

    @Test("Reduzierte Truth: gleiche Elemente, keine Annotationen, bewusste Fehler aufgelistet")
    func reducedTruth() throws {
        let editable = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        let reduced = try GoodnotesFixture.fotosyntheseReduced.loadTruth()
        #expect(editable.ocrErrors.isEmpty)
        #expect(reduced.variant == "reduced" && editable.variant == "editable")
        for (e, r) in zip(editable.pages, reduced.pages) {
            let nonOCR = r.items.filter { $0.kind != .ocrWord }
            #expect(nonOCR.map(\.id) == e.items.map(\.id))
            #expect(nonOCR.map(\.bbox) == e.items.map(\.bbox))
            #expect(r.items.allSatisfy { $0.annotationCount == 0 && $0.annotationSubtype == nil })
        }
        let errors = Dictionary(uniqueKeysWithValues: reduced.ocrErrors.map { ($0.truth, $0.recognized) })
        #expect(errors == ["grüne": "grune", "Chlorophyll": "Chlorophyl", "Blätter": "Blatter",
                           "Mitochondrien": "Mitochondnen", "Ökosystem": "Okosystem"])
        for error in reduced.ocrErrors {
            let ocr = try #require(reduced.item(withID: error.itemID))
            #expect(ocr.text == error.recognized && ocr.relatedItemID == error.inkWordID)
            #expect(reduced.item(withID: error.inkWordID)?.text == error.truth)
            #expect(ocr.bbox == reduced.item(withID: error.inkWordID)?.bbox)
        }
        // One text-layer word per handwritten word.
        #expect(reduced.items(ofKind: .ocrWord).count == reduced.items(ofKind: .inkWord).count)
    }
}

@Suite("Goodnotes-Fixtures: Determinismus und Drift")
struct DeterminismTests {
    @Test("Zweimaliges Erzeugen liefert identische Bytes", arguments: GoodnotesFixture.allCases)
    func deterministic(fixture: GoodnotesFixture) throws {
        let a = try fixture.generate()
        let b = try fixture.generate()
        #expect(a.pdfData == b.pdfData)
        #expect(a.truthData == b.truthData)
        #expect(validateXref(a.pdfData).isEmpty)
    }

    /// The committed files must match what the generator produces now. Byte equality is the rule. The glyph
    /// outlines come from a system font via CoreText, so a different font version (recorded in the truth as
    /// `handwritingFont` + `handwritingFontVersion`) may legitimately change them. Only if that font identity
    /// differs from the committed one, the structural comparison of `DriftComparison` replaces byte equality;
    /// otherwise any difference is a generator change and the fixtures must be regenerated.
    @Test("Mitgelieferte Dateien entsprechen der Generator-Ausgabe (Drift)", arguments: GoodnotesFixture.allCases)
    func noDrift(fixture: GoodnotesFixture) throws {
        let generated = try fixture.generate()
        let committedPDF = try Data(contentsOf: fixture.url)
        let committedTruthData = try Data(contentsOf: fixture.truthURL)
        if generated.pdfData == committedPDF && generated.truthData == committedTruthData { return }

        let committed = try GoodnotesGroundTruth.decode(from: committedTruthData)
        let fresh = generated.truth
        let fontChanged = committed.handwritingFont != fresh.handwritingFont
            || committed.handwritingFontVersion != fresh.handwritingFontVersion
        guard fontChanged else {
            Issue.record("""
                \(fixture.fileName): Bytes weichen ab, obwohl die Handschrift-Schrift gleich ist \
                (\(fresh.handwritingFont) \(fresh.handwritingFontVersion)). Der Generator wurde verändert: \
                `swift run make-fixtures` ausführen und die Dateien einchecken.
                """)
            return
        }
        let problems = try DriftComparison.problems(
            committedPDF: committedPDF, committedTruth: committed, freshPDF: generated.pdfData, freshTruth: fresh)
        #expect(problems.isEmpty, "Schrift \(committed.handwritingFont) \(committed.handwritingFontVersion) -> \(fresh.handwritingFont) \(fresh.handwritingFontVersion); \(problems.prefix(10))")
    }

    @Test("Drift-Vergleich: ohne Änderung keine Abweichung, auch bei anderer Schrift-Version")
    func driftComparisonAcceptsIdentical() throws {
        for fixture in GoodnotesFixture.allCases {
            let g = try fixture.generate()
            #expect(try DriftComparison.problems(committedPDF: g.pdfData, committedTruth: g.truth,
                                                 freshPDF: g.pdfData, freshTruth: g.truth).isEmpty)
        }
    }

    @Test("Drift-Vergleich erkennt Änderungen, die nicht von den Glyphen kommen")
    func driftComparisonDetectsGeneratorChanges() throws {
        // Same-length byte replacements keep the xref table valid.
        let mutations: [(fixture: GoodnotesFixture, find: String, replace: String, what: String)] = [
            (.fotosyntheseReduced, "3 Tr", "0 Tr", "Textebene sichtbar (3 Tr entfernt)"),
            (.fotosyntheseEditable, "/AP <<", "/AQ <<", "Appearance-Stream entfernt"),
            (.fotosyntheseEditable, "/F 4", "/F 0", "Annotation-Flags"),
            (.fotosyntheseEditable, "/W 1.6", "/W 1.7", "Strichbreite"),
            (.fotosyntheseEditable, "/C [0 0 0]", "/C [0 0 1]", "Annotationsfarbe"),
            (.fotosyntheseEditable, "0.5 w\n", "0.6 w\n", "Seiteninhalt (Papier)"),
            (.fotosyntheseReduced, "0.5 w\n", "0.6 w\n", "Seiteninhalt (Papier, reduziert)"),
            (.fotosyntheseReduced, "(Fotosynthese) Tj", "(Fotosynthesa) Tj", "Text der Textebene"),
            (.fotosyntheseReduced, "1 J 1 j", "0 J 0 j", "Linienenden der Tinte"),
        ]
        for m in mutations {
            let g = try m.fixture.generate()
            let mutated = try #require(DriftComparison.replacing(m.find, with: m.replace, in: g.pdfData),
                                       "\(m.what): Muster fehlt")
            #expect(mutated.count == g.pdfData.count, "\(m.what): Länge")
            let problems = try DriftComparison.problems(committedPDF: g.pdfData, committedTruth: g.truth,
                                                        freshPDF: mutated, freshTruth: g.truth)
            #expect(!problems.isEmpty, "nicht erkannt: \(m.what)")
        }
    }

    @Test("Resource-URLs zeigen auf vorhandene Dateien", arguments: GoodnotesFixture.allCases)
    func resourcesExist(fixture: GoodnotesFixture) {
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(FileManager.default.fileExists(atPath: fixture.truthURL.path))
    }

    @Test("Handschrift-Schrift wird aufgelöst und in der Truth-Datei vermerkt")
    func handwritingFont() throws {
        let name = HandwritingFont.resolvedName
        #expect([HandwritingFont.preferredName, HandwritingFont.fallbackName].contains(name))
        let version = HandwritingFont.resolvedVersion
        #expect(!version.isEmpty && version != "unknown")
        for fixture in GoodnotesFixture.allCases {
            let truth = try fixture.loadTruth()
            #expect(!truth.handwritingFont.isEmpty && !truth.handwritingFontVersion.isEmpty)
        }
        let generated = try GoodnotesFixture.fotosyntheseEditable.generate().truth
        #expect(generated.handwritingFont == name && generated.handwritingFontVersion == version)
    }
}
