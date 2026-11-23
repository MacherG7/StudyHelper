import CoreGraphics
import CoreText
import Foundation
import StudyCore
import StudyImport
import TestFixtures
import Testing

@Suite("Goodnotes: Parser, Varianten, Zuordnung")
struct GoodnotesParserTests {
    // MARK: Editable export

    @Test("Bearbeitbares PDF: 3 Seiten, Strichanzahl je Seite wie in der Wahrheit")
    func editableStrokeCounts() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        #expect(loaded.document.variant == .editable)
        #expect(loaded.document.pages.count == 3)
        for page in loaded.document.pages {
            let expected = loaded.truth.pages[page.index].items
                .filter { $0.annotationSubtype == "Ink" }
                .reduce(0) { $0 + $1.strokeCount }
            #expect(page.strokes.count == expected, "Seite \(page.index + 1): \(page.strokes.count) statt \(expected)")
            #expect(abs(page.size.width - loaded.truth.pageWidth) < 0.01)
            #expect(abs(page.size.height - loaded.truth.pageHeight) < 0.01)
        }
    }

    @Test("Bearbeitbares PDF: Stiftfarben, Strichbreiten und Textmarker")
    func editableColorsAndHighlighters() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let pages = loaded.document.pages
        let allPen = pages.flatMap(\.penStrokes)
        let distinctPenColors = GoodnotesTestSupport.distinct(allPen.map(\.color))
        #expect(distinctPenColors.count >= 4, "Stiftfarben: \(distinctPenColors.map(\.hex))")
        #expect(pages.flatMap(\.highlighterStrokes).count == 3)
        #expect(pages[0].highlighterStrokes.count == 3)
        for stroke in pages.flatMap(\.highlighterStrokes) {
            #expect(stroke.width == 18)
            #expect(stroke.color.isYellowish)
        }
        // Every truth ink word: the stroke widths agree with the truth.
        let truthWidths = Set(loaded.truth.items(ofKind: .inkWord).compactMap(\.lineWidth))
        let widths = Set(allPen.map(\.width))
        for w in truthWidths { #expect(widths.contains { abs($0 - w) < 0.001 }, "Breite \(w) fehlt") }
        // Stroke names are kept (/NM).
        #expect(allPen.allSatisfy { $0.name != nil })
    }

    @Test("Bearbeitbares PDF: FreeText exakt (₂, →) und Stempel auf Seite 1 und 3")
    func editableFreeTextAndStamps() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let pages = loaded.document.pages
        let truthFreeText = try #require(loaded.truth.items(ofKind: .freeText).first)
        let freeTexts = pages.flatMap(\.freeTexts)
        #expect(freeTexts.count == 1)
        let box = try #require(freeTexts.first)
        #expect(box.text == truthFreeText.text)
        #expect(box.text.contains("\u{2082}"))
        #expect(box.text.contains("\u{2192}"))
        let expectedRect = GoodnotesTestSupport.normalized(truthFreeText.bbox, truth: loaded.truth)
        #expect(abs(box.rect.x - expectedRect.x) < 0.001 && abs(box.rect.y - expectedRect.y) < 0.001)
        #expect(abs(box.rect.width - expectedRect.width) < 0.001 && abs(box.rect.height - expectedRect.height) < 0.001)

        #expect(pages[0].stamps.count == loaded.truth.items(ofKind: .stamp, onPage: 1).count)
        #expect(pages[1].stamps.isEmpty)
        #expect(pages[2].stamps.count == loaded.truth.items(ofKind: .stamp, onPage: 3).count)
        #expect(pages[0].stamps.count >= 1 && pages[2].stamps.count >= 1)
    }

    @Test("Bearbeitbares PDF: Arbeitsblatt-Text steht in der Textebene von Seite 2")
    func editableWorksheetTextLayer() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let layer = loaded.document.pages[1].textLayer
        let normalized = Set(layer.map { WordTokenizer.normalize($0.text) })
        for item in loaded.truth.items(ofKind: .worksheetText, onPage: 2) {
            for token in WordTokenizer.tokens(in: item.text ?? "") {
                #expect(normalized.contains(token.normalized), "Wort fehlt in der Textebene: \(token.original)")
            }
        }
        // Position check: the heading is near the top left of the page.
        let heading = try #require(layer.first { $0.text == "Arbeitsblatt:" })
        let truthHeading = try #require(loaded.truth.items(ofKind: .worksheetText, onPage: 2).first)
        let expected = GoodnotesTestSupport.normalized(truthHeading.bbox, truth: loaded.truth)
        #expect(abs(heading.rect.minX - expected.minX) < 0.01)
        #expect(abs(heading.rect.midY - expected.midY) < 0.03)
        // Handwriting is not part of the editable text layer.
        #expect(loaded.document.pages[0].textLayer.isEmpty)
    }

    // MARK: Reduced export

    @Test("Reduziertes PDF: keine Annotationen, Textebene mit Positionen der Handschrift")
    func reducedTextLayer() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseReduced)
        #expect(loaded.document.variant == .reduced)
        for page in loaded.document.pages {
            #expect(page.strokes.isEmpty && page.freeTexts.isEmpty && page.stamps.isEmpty)
            #expect(!page.textLayer.isEmpty)
        }
        // Every recognized word of the truth is in the text layer at roughly its position.
        for item in loaded.truth.items(ofKind: .ocrWord) {
            let pageIndex = Int(item.id.dropFirst().prefix(while: { $0 != "-" })) ?? 1
            let page = loaded.document.pages[pageIndex - 1]
            let expected = GoodnotesTestSupport.normalized(item.bbox, truth: loaded.truth)
            let hit = page.textLayer.first {
                $0.text == item.text && abs($0.rect.midX - expected.midX) < 0.02 && abs($0.rect.midY - expected.midY) < 0.02
            }
            #expect(hit != nil, "Textebene ohne \(item.text ?? "?") (\(item.id))")
        }
    }

    // MARK: Variant detection

    @Test("Variante: bearbeitbar, drei reduzierte, normales PDF wird .other")
    func variantDetection() throws {
        #expect(try GoodnotesTestSupport.load(.fotosyntheseEditable).document.variant == .editable)
        for fixture in [GoodnotesFixture.fotosyntheseReduced, .andereNotizReduced, .andereGroesseReduced] {
            #expect(try GoodnotesTestSupport.load(fixture).document.variant == .reduced, "\(fixture.fileName)")
        }
        let plain = try GoodnotesParser.parse(data: GoodnotesTestSupport.plainWorksheetPDF())
        #expect(plain.variant == .other)
        #expect(plain.pages.count == 1)
        #expect(plain.pages[0].strokes.isEmpty)
        #expect(plain.pages[0].textLayer.contains { $0.text == "Arbeitsblatt" })
        #expect(plain.producer?.localizedCaseInsensitiveContains("goodnotes") != true)
    }

    @Test("Variante: Textebene mit unsichtbarem Text ohne Goodnotes-Producer gilt als reduziert")
    func invisibleTextWithoutProducer() throws {
        let invisible = GoodnotesTestSupport.worksheetPDF(invisibleText: true)
        #expect(try GoodnotesParser.parse(data: invisible).variant == .reduced)
        let visible = GoodnotesTestSupport.worksheetPDF(invisibleText: false)
        #expect(try GoodnotesParser.parse(data: visible).variant == .other)
    }

    @Test("Eingaben: .goodnotes abgelehnt, Müll ist kein PDF, gesperrtes PDF ist verschlüsselt")
    func rejections() throws {
        let url = URL(fileURLWithPath: "/tmp/does-not-matter/Notiz.goodnotes")
        #expect(throws: GoodnotesError.goodnotesFileNotSupported) { try GoodnotesParser.parse(url: url) }
        let upper = URL(fileURLWithPath: "/tmp/does-not-matter/NOTIZ.GOODNOTES")
        #expect(throws: GoodnotesError.goodnotesFileNotSupported) { try GoodnotesParser.parse(url: upper) }

        #expect(throws: GoodnotesError.notAPDF) { try GoodnotesParser.parse(data: Data("Das ist kein PDF.".utf8)) }
        #expect(throws: GoodnotesError.notAPDF) { try GoodnotesParser.parse(data: Data()) }
        #expect(throws: GoodnotesError.notAPDF) { try GoodnotesParser.parse(data: Data("%PDF-1.7 kaputt".utf8)) }

        let locked = GoodnotesTestSupport.worksheetPDF(invisibleText: false, userPassword: "geheim")
        #expect(throws: GoodnotesError.encrypted) { try GoodnotesParser.parse(data: locked) }
    }

    // MARK: Pairing

    @Test("Zuordnung: Fotosynthese-Paar passt")
    func pairingCompatible() throws {
        let editable = try GoodnotesTestSupport.load(.fotosyntheseEditable).document
        let reduced = try GoodnotesTestSupport.load(.fotosyntheseReduced).document
        #expect(GoodnotesPairing.check(editable: editable, reduced: reduced) == .compatible)
    }

    @Test("Zuordnung: andere Seitenzahl, andere Seitengröße, falsche Varianten")
    func pairingMismatches() throws {
        let editable = try GoodnotesTestSupport.load(.fotosyntheseEditable).document
        let otherNote = try GoodnotesTestSupport.load(.andereNotizReduced).document
        #expect(GoodnotesPairing.check(editable: editable, reduced: otherNote) == .pageCountMismatch(editable: 3, reduced: 1))

        let otherSize = try GoodnotesTestSupport.load(.andereGroesseReduced).document
        #expect(GoodnotesPairing.check(editable: editable, reduced: otherSize) == .pageSizeMismatch(pageIndex: 0))

        #expect(GoodnotesPairing.check(editable: editable, reduced: editable) == .wrongVariants)
        let reduced = try GoodnotesTestSupport.load(.fotosyntheseReduced).document
        #expect(GoodnotesPairing.check(editable: reduced, reduced: editable) == .wrongVariants)
        #expect(GoodnotesPairing.check(editable: reduced, reduced: reduced) == .wrongVariants)

        // Tolerance of 1 pt: a page that is 0.5 pt larger still pairs, 3 pt does not.
        var nearly = reduced
        nearly.pages[1].size = PageSize(width: reduced.pages[1].size.width + 0.5, height: reduced.pages[1].size.height)
        #expect(GoodnotesPairing.check(editable: editable, reduced: nearly) == .compatible)
        nearly.pages[1].size = PageSize(width: reduced.pages[1].size.width + 3, height: reduced.pages[1].size.height)
        #expect(GoodnotesPairing.check(editable: editable, reduced: nearly) == .pageSizeMismatch(pageIndex: 1))
    }
}
