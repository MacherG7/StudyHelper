import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import TestFixtures
import Testing
@testable import StudyImport

/// The digital page: original look with an invisible text layer, and the text mode (docs/DECISIONS.md D-037).
@Suite("Digitale Seite")
struct DigitalPageTests {
    typealias S = DigitalPageTestSupport

    static func pdf(_ inputs: [DigitalPageInput]) throws -> PDFDocument {
        let data = try DigitalPageBuilder.makePDF(inputs, title: "Biologie – Fotosynthese")
        return try #require(PDFDocument(data: data))
    }

    static func image(_ input: DigitalPageInput, _ mode: DigitalPageMode, scale: Double = 1.5, drawsText: Bool = true) throws -> S.Pixels {
        var options = DigitalPageOptions()
        options.drawsText = drawsText
        return S.Pixels(try DigitalPageBuilder.makeImage(input, mode: mode, scale: scale, sources: nil, options: options))
    }

    static func inkLines(_ input: DigitalPageInput, truthPage: Int) throws -> [RecognizedLine] {
        let truth = try GoodnotesTestSupport.load(.fotosyntheseEditable).truth
        let ink = GoodnotesTestSupport.perfectPage(truth: truth, pageNumber: truthPage).lines.map(\.rect)
        return input.lines.filter { line in ink.contains(line.rect) }
    }

    /// A rotated page (600 × 400, /Rotate 90 → displayed 400 × 600) with one scribbled word.
    static let rotatedPage = MiniPDF.page(
        width: 600, height: 400, rotate: 90, annotations: [S.scribble(x: 100, y: 200, w: 30, h: 120)])
    /// The scribble in displayed space: user (x 100…130, y 200…320) rotated by 90° clockwise.
    static let rotatedWord = NormalizedRect(x: 200.0 / 400, y: 100.0 / 600, width: 120.0 / 400, height: 30.0 / 600)

    static func rotatedInput() -> DigitalPageInput {
        let line = RecognizedLine(
            text: "Gedreht", rect: rotatedWord, words: [RecognizedWord(text: "Gedreht", rect: rotatedWord)])
        return DigitalPageInput(background: .pdf(data: rotatedPage, pageIndex: 0, variant: nil), lines: [line])
    }

    // MARK: 1. Pages

    @Test("PDF: Seitenzahl und Seitengröße wie die Vorlage (bearbeitbar, reduziert, Arbeitsblatt, Foto, gedrehte Seite)")
    func pageCountAndSize() throws {
        let a4 = CGSize(width: GoodnotesFixtureSpec.a4Width, height: GoodnotesFixtureSpec.a4Height)
        func check(_ document: PDFDocument, count: Int, size: CGSize) {
            #expect(document.pageCount == count)
            for index in 0..<document.pageCount {
                let page = document.page(at: index)!
                let box = page.bounds(for: .mediaBox)
                #expect(abs(box.width - size.width) < 0.01 && abs(box.height - size.height) < 0.01, "Seite \(index + 1): \(box)")
                #expect(page.rotation == 0)
            }
        }
        check(try Self.pdf((0..<3).map { try S.editableInput($0) }), count: 3, size: a4)
        check(try Self.pdf((0..<3).map { try S.reducedInput($0) }), count: 3, size: a4)
        check(try Self.pdf((0..<2).map { try S.worksheetInput($0) }), count: 2, size: CGSize(width: GoodnotesFixtureSpec.a4Width, height: GoodnotesFixtureSpec.a4Height))
        let photo = try S.photoInput()
        check(try Self.pdf([photo.input]), count: 1, size: CGSize(width: photo.image.width, height: photo.image.height))
        let rotated = try Self.pdf([Self.rotatedInput()])
        check(rotated, count: 1, size: CGSize(width: 400, height: 600))
        #expect(S.findsText("Gedreht", on: rotated.page(at: 0)!, in: Self.rotatedWord))
        let info = rotated.documentAttributes ?? [:]
        #expect(info[PDFDocumentAttribute.creatorAttribute] as? String == "StudyHelper")
        #expect(info[PDFDocumentAttribute.titleAttribute] as? String == "Biologie – Fotosynthese")
    }

    @Test("Ohne Seiten oder mit unlesbarer Vorlage gibt es einen Fehler statt eines Absturzes")
    func errors() {
        #expect(throws: DigitalPageError.renderingFailed) { try DigitalPageBuilder.makePDF([]) }
        let broken = DigitalPageInput(background: .pdf(data: Data("kein PDF".utf8), pageIndex: 0, variant: nil), lines: [])
        #expect(throws: DigitalPageError.unreadablePDF) { try DigitalPageBuilder.makePDF([broken]) }
        let outside = DigitalPageInput(background: .pdf(data: Self.rotatedPage, pageIndex: 3, variant: nil), lines: [])
        #expect(throws: DigitalPageError.pageOutOfRange(pageIndex: 3)) {
            try DigitalPageBuilder.makeImage(outside, mode: .handwriting, scale: 1)
        }
        let image = DigitalPageInput(background: .image(data: Data([1, 2, 3])), lines: [])
        #expect(throws: DigitalPageError.unreadableImage) { try DigitalPageBuilder.makeImage(image, mode: .textLayer, scale: 1) }
    }

    // MARK: 2. Text layer

    @Test("Textebene: jedes gespeicherte Wort steht an seiner Stelle, Text wie gespeichert (Umlaute, ß)")
    func wordsAtTheirPlace() throws {
        let inputs = try (0..<3).map { try S.editableInput($0) }
        let document = try Self.pdf(inputs)
        var words = 0
        for (index, input) in inputs.enumerated() {
            let page = try #require(document.page(at: index))
            for line in try Self.inkLines(input, truthPage: index + 1) {
                #expect(S.matchedTokens(line.text, on: page, in: line.rect) == WordTokenizer.tokens(in: line.text).count,
                        "S.\(index + 1): \(line.text) – gefunden: \(page.selection(for: .zero)?.string ?? "")")
                for word in line.words {
                    #expect(S.findsText(word.text, on: page, in: word.rect), "S.\(index + 1): „\(word.text)“ nicht an seiner Stelle")
                    words += 1
                }
            }
        }
        #expect(words == 46)
        let text = (0..<3).compactMap { document.page(at: $0)?.string }.joined(separator: " ")
        for umlaut in ["grüne", "Blätter", "große", "Ökosystem"] { #expect(text.contains(umlaut), "\(umlaut)") }
    }

    @Test("Textebene: Pfeile → ← ↔ ↑ ↓ ↕ lassen sich finden und kopieren")
    func arrowsInTextLayer() throws {
        var input = try S.worksheetInput(1)
        let rect = NormalizedRect(x: 0.1, y: 0.6, width: 0.6, height: 0.025)
        let text = "Licht → Zucker ← Wasser ↔ CO₂ ↑ O₂ ↓ Stärke ↕"
        input.lines.append(RecognizedLine(text: text, rect: rect, order: 99))
        let document = try Self.pdf([input])
        let page = try #require(document.page(at: 0))
        let extracted = page.string ?? ""
        #expect(extracted.contains(text), "\(extracted)")
        for arrow in ["→", "←", "↔", "↑", "↓", "↕"] { #expect(S.findsText(arrow, on: page, in: rect), "\(arrow)") }
    }

    // MARK: 3. No foreign or duplicate text

    @Test("Reduziertes PDF allein: Goodnotes' fehlerhafte Texterkennung kommt nicht in die Textebene")
    func reducedWithoutForeignText() throws {
        let truth = try GoodnotesTestSupport.load(.fotosyntheseReduced).truth
        let faulty = truth.ocrErrors.map { WordTokenizer.normalize($0.recognized) }
        #expect(faulty.count == 5)
        for variant in [GoodnotesVariant.reduced, nil] {
            let inputs = try (0..<3).map { try S.reducedInput($0, variant: variant) }
            let document = try Self.pdf(inputs)
            for (index, input) in inputs.enumerated() {
                let output = S.counts(S.tokens(document.page(at: index)?.string ?? ""))
                let stored = S.counts(input.lines.flatMap { S.tokens($0.text) })
                for word in faulty { #expect(output[word] == nil || stored[word] != nil, "S.\(index + 1): „\(word)“") }
                #expect(output == stored, "S.\(index + 1): \(output) ≠ \(stored)")
            }
        }
    }

    @Test("Kein Wort doppelt: Arbeitsblatt-Text und FreeText stehen nur einmal in der Textebene")
    func noDuplicates() throws {
        // Digital worksheet: every word exactly as often as in the original.
        let worksheet = try Data(contentsOf: DigitalWorksheetFixture.url)
        let original = try #require(PDFDocument(data: worksheet))
        let output = try Self.pdf((0..<2).map { try S.worksheetInput($0) })
        for index in 0..<2 {
            #expect(S.counts(S.tokens(output.page(at: index)?.string ?? "")) == S.counts(S.tokens(original.page(at: index)?.string ?? "")))
        }
        // Editable note: worksheet text (page content), FreeText (its appearance) and handwriting (layer) once each.
        let truth = try GoodnotesTestSupport.load(.fotosyntheseEditable).truth
        let editable = try #require(PDFDocument(data: try S.data(.fotosyntheseEditable)))
        let inputs = try (0..<3).map { try S.editableInput($0) }
        let document = try Self.pdf(inputs)
        for index in 0..<3 {
            var expected = S.tokens(editable.page(at: index)?.string ?? "")
            expected += truth.items(ofKind: .freeText, onPage: index + 1).flatMap { S.tokens($0.appearanceText ?? "") }
            expected += try Self.inkLines(inputs[index], truthPage: index + 1).flatMap { S.tokens($0.text) }
            #expect(S.counts(S.tokens(document.page(at: index)?.string ?? "")) == S.counts(expected), "S.\(index + 1)")
        }
        #expect(S.tokens(document.page(at: 0)?.string ?? "").filter { $0 == "formel:" || $0 == "formel" }.count == 1)
    }

    // MARK: 4. Original look

    @Test("Modus Handschrift sieht aus wie das Original (bearbeitbar, reduziert, Arbeitsblatt, gedreht, Foto)")
    func handwritingLooksLikeOriginal() throws {
        var cases: [(String, DigitalPageInput, Data, Int)] = []
        for index in 0..<3 { cases.append(("bearbeitbar S.\(index + 1)", try S.editableInput(index), try S.data(.fotosyntheseEditable), index)) }
        cases.append(("reduziert S.1", try S.reducedInput(0), try S.data(.fotosyntheseReduced), 0))
        cases.append(("Arbeitsblatt S.1", try S.worksheetInput(0), try Data(contentsOf: DigitalWorksheetFixture.url), 0))
        cases.append(("gedreht", Self.rotatedInput(), Self.rotatedPage, 0))
        for (name, input, data, index) in cases {
            let original = S.Pixels(try #require(PageRenderer.render(page: try S.pdfPage(data, index), scale: 1.5)))
            let digital = try Self.image(input, .handwriting)
            #expect(digital.meanDifference(to: original) < 0.3, "\(name): \(digital.meanDifference(to: original))")
        }
        let photo = try S.photoInput()
        let digital = try Self.image(photo.input, .handwriting, scale: 1)
        // The input is a JPEG of `photo.image`: only compression differences.
        #expect(digital.meanDifference(to: S.Pixels(photo.image)) < 2)
    }

    // MARK: 5. Text mode on an editable note

    @Test("Modus Text (bearbeitbar): Handschrift weg; Tabellenlinien, Pfeile, Mindmap-Linien, Textmarker, Bild, Unterstreichungen und Kreis bleiben")
    func textModeEditable() throws {
        for index in 0..<3 {
            let input = try S.editableInput(index)
            let original = try Self.image(input, .handwriting)
            let hidden = try Self.image(input, .textLayer, drawsText: false)
            let words = try S.truthRects(.inkWord, page: index + 1)
            let shrunk = words.map { $0.insetBy(dx: $0.width * 0.1, dy: $0.height * 0.1) }
            let before = shrunk.reduce(0) { $0 + original.ink(in: $1) }
            let after = shrunk.reduce(0) { $0 + hidden.ink(in: $1) }
            #expect(before > 1000)
            #expect(Double(after) <= 0.02 * Double(before), "S.\(index + 1): \(after) von \(before) Tintenpixeln übrig")

            let grownWords = words.map { $0.insetBy(dx: -0.004, dy: -0.003) }
            for kind in [GoodnotesItemKind.tableLine, .stamp, .highlighter, .underline, .doubleUnderline, .circle] {
                for rect in try S.truthRects(kind, page: index + 1) {
                    // Highlighter: the whole band; shapes: outside the words they mark.
                    let keep = kind == .highlighter ? original.marked(in: rect) : original.marked(in: rect, excluding: grownWords)
                    let kept = kind == .highlighter ? hidden.marked(in: rect) : hidden.marked(in: rect, excluding: grownWords)
                    #expect(keep > 20, "S.\(index + 1) \(kind): \(keep)")
                    #expect(Double(kept) >= 0.9 * Double(keep), "S.\(index + 1) \(kind): \(kept) von \(keep)")
                }
            }
            for rect in try S.truthRects(.image, page: index + 1) {
                #expect(hidden.meanDifference(to: original, in: rect) < 0.5, "S.\(index + 1) Bild verändert")
            }
            for rect in try S.truthRects(.freeText, page: index + 1) {
                #expect(hidden.meanDifference(to: original, in: rect) < 0.5, "S.\(index + 1) FreeText verändert")
            }
        }
    }

    @Test("Modus Text: der Text steht sichtbar in Stiftfarbe an der Stelle der Handschrift")
    func textModeDrawsText() throws {
        let input = try S.editableInput(0)
        let hidden = try Self.image(input, .textLayer, drawsText: false)
        let shown = try Self.image(input, .textLayer)
        let lines = try Self.inkLines(input, truthPage: 1)
        for line in lines {
            #expect(shown.ink(in: line.rect) > hidden.ink(in: line.rect) + 100, "\(line.text)")
        }
        // The red line is drawn in red.
        let red = try #require(lines.first { $0.text.hasPrefix("Chlorophyll") })
        let reddish = shown.count(in: red.rect) { r, g, b in r > 150 && g < 110 && b < 110 }
        #expect(reddish > 200)
    }

    @Test("Modus Text: unsichere Wörter bekommen eine orange gepunktete Linie, fette Wörter werden fett")
    func textModeMarksUncertainAndBold() throws {
        var input = try S.editableInput(0)
        let index = try #require(input.lines.firstIndex { $0.text == "Pflanzen wandeln Lichtenergie" })
        input.lines[index].words[1].status = .uncertain
        let word = input.lines[index].words[1].rect
        let below = NormalizedRect(x: word.x, y: input.lines[index].rect.y, width: word.width, height: input.lines[index].rect.height * 1.1)
        func orange(_ p: S.Pixels) -> Int { p.count(in: below) { r, g, b in r > 200 && g > 100 && g < 190 && b < 90 } }
        #expect(orange(try Self.image(input, .textLayer)) > 10)
        #expect(orange(try Self.image(input, .handwriting)) == 0)

        let regular = try Self.image(input, .textLayer).ink(in: input.lines[index].words[0].rect)
        input.highlights.append(RecognizedHighlight(
            text: "Pflanzen", kind: .bold, rect: input.lines[index].words[0].rect, source: .user,
            words: [WordReference(lineID: input.lines[index].id, wordIndex: 0)]))
        let bold = try Self.image(input, .textLayer).ink(in: input.lines[index].words[0].rect)
        #expect(Double(bold) > 1.15 * Double(regular), "fett \(bold), normal \(regular)")
    }

    // MARK: 6. Text in pictures

    /// 612 × 792: embedded text "Hallo Welt" and a picture (x 50…350, y 400…550) with the text "Karte" in it.
    static let pictureWidth = 200, pictureHeight = 100
    static let picturePage: Data = {
        let resources = "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> /XObject << /Im1 5 0 R >> >>"
        return MiniPDF.page(
            width: 612, height: 792,
            content: "BT /F1 24 Tf 50 700 Td (Hallo Welt) Tj ET q 300 0 0 150 50 400 cm /Im1 Do Q",
            resources: resources,
            extra: [.stream(
                dictionary: "/Type /XObject /Subtype /Image /Width \(pictureWidth) /Height \(pictureHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8",
                data: S.textImage("Karte", width: pictureWidth, height: pictureHeight))])
    }()
    static let picture = NormalizedRect(x: 50.0 / 612, y: 242.0 / 792, width: 300.0 / 612, height: 150.0 / 792)

    @Test("Text in einem Bild: das Bild bleibt im Modus Text unverändert, der Text steht in der Textebene")
    func textInPicture() throws {
        let pdfPage = try S.pdfPage(Self.picturePage, 0)
        let embedded = try #require(EmbeddedTextExtractor.extract(from: pdfPage)).lines
        // "Karte" as the pipeline would map it back from the picture (upper part of the image).
        let inPicture = NormalizedRect(x: (50 + 25) / 612.0, y: (242 + 22) / 792.0, width: 160 / 612.0, height: 30 / 792.0)
        let line = RecognizedLine(
            text: "Karte", rect: inPicture, words: [RecognizedWord(text: "Karte", rect: inPicture)], order: 1)
        let input = DigitalPageInput(background: .pdf(data: Self.picturePage, pageIndex: 0, variant: nil), lines: embedded + [line])
        let original = try Self.image(input, .handwriting)
        let text = try Self.image(input, .textLayer)
        #expect(text.meanDifference(to: original, in: Self.picture) < 0.2)
        #expect(text.meanDifference(to: original) < 0.2, "auch der eingebettete Text bleibt, wie er ist")

        let opened = try DigitalPageSources().pdf(Self.picturePage)
        let checkedOut = try opened.checkOut()
        let source = try DigitalPageSource.open(input.background, pdf: opened, document: checkedOut)
        #expect(DigitalPageBuilder.textModeLines(input, source: source).isEmpty)

        let document = try Self.pdf([input])
        let page = try #require(document.page(at: 0))
        #expect(S.counts(S.tokens(page.string ?? "")) == ["hallo": 1, "welt": 1, "karte": 1])
        #expect(S.findsText("Karte", on: page, in: inPicture))
    }

    // MARK: 7. Shape arrows

    /// 600 × 800 with an arrow stamp in a row (x 180…212, y 750…762) and two scribbled words left and right of it.
    static let arrowPage = MiniPDF.page(
        width: 600, height: 800,
        annotations: [
            "<< /Type /Annot /Subtype /Stamp /Rect [180 750 212 762] /AP << /N 8 0 R >> >>",
            S.scribble(x: 100, y: 744, w: 70, h: 24),
            S.scribble(x: 222, y: 744, w: 80, h: 24),
        ],
        extra: [ShapeArrowsTests.arrowForm()])

    static func arrowInput() -> (input: DigitalPageInput, arrow: NormalizedRect) {
        let ursache = NormalizedRect(x: 98.0 / 600, y: 30.0 / 800, width: 74.0 / 600, height: 28.0 / 800)
        let wirkung = NormalizedRect(x: 220.0 / 600, y: 30.0 / 800, width: 84.0 / 600, height: 28.0 / 800)
        let line = RecognizedLine(
            text: "Ursache → Wirkung", rect: ursache.union(wirkung),
            words: [RecognizedWord(text: "Ursache", rect: ursache), RecognizedWord(text: "Wirkung", rect: wirkung)])
        let arrow = NormalizedRect(x: 180.0 / 600, y: 38.0 / 800, width: 32.0 / 600, height: 12.0 / 800)
        return (DigitalPageInput(background: .pdf(data: arrowPage, pageIndex: 0, variant: nil), lines: [line]), arrow)
    }

    @Test("Eingesetzter Formpfeil: in der Textebene an der Stelle des Pfeils, im Modus Text nicht doppelt gezeichnet")
    func insertedShapeArrow() throws {
        let (input, arrow) = Self.arrowInput()
        let document = try Self.pdf([input])
        let page = try #require(document.page(at: 0))
        #expect(page.string?.contains("Ursache → Wirkung") == true, "\(page.string ?? "")")
        #expect(S.findsText("→", on: page, in: arrow))

        let runs = DigitalPageText.runs(
            for: input.lines, highlights: [], arrows: ShapeArrows.arrows(of: try S.pdfPage(Self.arrowPage, 0)),
            size: PageSize(width: 600, height: 800))
        #expect(runs.map { $0.tokens.map(\.text) } == [["Ursache"], ["→"], ["Wirkung"]])
        #expect(runs.map { $0.tokens.allSatisfy(\.drawsVisibly) } == [true, false, true])

        let original = try Self.image(input, .handwriting, scale: 3)
        let hidden = try Self.image(input, .textLayer, scale: 3, drawsText: false)
        let shown = try Self.image(input, .textLayer, scale: 3)
        let stampInk = original.ink(in: arrow)
        #expect(stampInk > 50)
        #expect(hidden.ink(in: arrow) >= stampInk * 9 / 10, "der Pfeil bleibt")
        #expect(shown.ink(in: arrow) <= stampInk * 11 / 10, "kein zweiter Pfeil")
        // The scribbles are gone, the words are drawn instead.
        let words = input.lines[0].words.map(\.rect)
        #expect(words.reduce(0) { $0 + hidden.ink(in: $1) } < words.reduce(0) { $0 + original.ink(in: $1) } / 50)
    }

    // MARK: 8. Corrections

    @Test("Korrigierte Zeilen: die Textebene enthält den korrigierten Text, auch wenn die Wortboxen veraltet sind")
    func correctedLines() throws {
        var input = try S.editableInput(0)
        let same = try #require(input.lines.firstIndex { $0.text == "Pflanzen wandeln Lichtenergie" })
        input.lines[same].recognizedText = input.lines[same].text
        input.lines[same].text = "Pflanzen verwandeln Lichtenergie"
        input.lines[same].isUserCorrected = true
        let stale = try #require(input.lines.firstIndex { $0.text == "in chemische Energie um" })
        input.lines[stale].recognizedText = input.lines[stale].text
        input.lines[stale].text = "in die chemische Energie um"
        input.lines[stale].isUserCorrected = true

        let document = try Self.pdf([input])
        let page = try #require(document.page(at: 0))
        let tokens = S.tokens(page.string ?? "")
        #expect(tokens.contains("verwandeln") && !tokens.contains("wandeln"))
        #expect(page.string?.contains("in die chemische Energie um") == true)
        for index in [same, stale] {
            let line = input.lines[index]
            #expect(S.matchedTokens(line.text, on: page, in: line.rect) == WordTokenizer.tokens(in: line.text).count, "\(line.text)")
        }
        #expect(S.findsText("verwandeln", on: page, in: input.lines[same].words[1].rect))
    }

    // MARK: 9. Photos

    @Test("Foto: die Zeilen werden in Papierfarbe übermalt (Unterstreichung und Linien bleiben), danach steht der Text dort")
    func photoTextMode() throws {
        let (input, _) = try S.photoInput()
        let original = try Self.image(input, .handwriting, scale: 1)
        let hidden = try Self.image(input, .textLayer, scale: 1, drawsText: false)
        let shown = try Self.image(input, .textLayer, scale: 1)
        let words = try S.truthRects(.inkWord, page: 1)
        let before = words.reduce(0) { $0 + original.ink(in: $1) }
        let after = words.reduce(0) { $0 + hidden.ink(in: $1) }
        #expect(before > 1000)
        #expect(Double(after) <= 0.01 * Double(before), "\(after) von \(before) Tintenpixeln übrig")
        // Paper color, not white: the painted areas stay beige.
        let line = input.lines[1].rect
        let white = hidden.count(in: line) { r, g, b in r > 250 && g > 250 && b > 250 }
        #expect(white == 0)
        for rect in try S.truthRects(.underline, page: 1) + S.truthRects(.highlighter, page: 1) {
            #expect(Double(hidden.marked(in: rect)) >= 0.8 * Double(original.marked(in: rect, excluding: words)), "\(rect)")
        }
        let drawn = input.lines.reduce(0) { $0 + shown.ink(in: $1.rect) }
        #expect(Double(drawn) > 0.2 * Double(before))
    }
}

extension DigitalPageTestSupport.Pixels {
    /// `marked(in:)` without the pixels inside any of `excluded`.
    func marked(in rect: NormalizedRect, excluding excluded: [NormalizedRect]) -> Int {
        let range = pixelRange(rect)
        var count = 0
        for y in range.y {
            for x in range.x {
                let nx = (Double(x) + 0.5) / Double(width), ny = (Double(y) + 0.5) / Double(height)
                if excluded.contains(where: { $0.contains(x: nx, y: ny) }) { continue }
                let o = (y * width + x) * 4
                if min(rgba[o], rgba[o + 1], rgba[o + 2]) < 215 { count += 1 }
            }
        }
        return count
    }
}

