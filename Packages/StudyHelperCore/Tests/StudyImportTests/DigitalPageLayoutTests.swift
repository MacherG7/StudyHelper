import CoreGraphics
import CoreText
import Foundation
import PDFKit
import StudyCore
import Testing
@testable import StudyImport

/// Text-mode layout, editable pages with scans or flattened writing, shared sources and short underlines on photos.
@Suite("Digitale Seite: Schriftbild, Quellen und Sonderfälle")
struct DigitalPageLayoutTests {
    typealias S = DigitalPageTestSupport

    // MARK: Visible layout

    static let seedPage = PageSize(width: 600, height: 800)

    /// The lines of the app's UI test seed: word boxes split the line box evenly (coarse: "Ort:" gets about 3 times
    /// its width, "ist" and "der" about twice).
    static func seedLines(_ texts: [String] = ["Fotosynthese", "Ort: Chloroplasten", "Chlorophyl ist der grune Blattfarbstoff"])
        -> [RecognizedLine] {
        let rects = [
            NormalizedRect(x: 0.1, y: 0.08, width: 0.45, height: 0.06),
            NormalizedRect(x: 0.1, y: 0.2, width: 0.55, height: 0.05),
            NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05),
        ]
        return zip(texts, rects).enumerated().map { index, pair in
            let (text, rect) = pair
            let parts = text.split(separator: " ").map(String.init)
            let slot = rect.width / Double(parts.count)
            let words = parts.enumerated().map { i, part in
                RecognizedWord(text: part, rect: NormalizedRect(x: rect.x + Double(i) * slot, y: rect.y, width: slot * 0.9, height: rect.height))
            }
            return RecognizedLine(text: text, rect: rect, words: words, order: index)
        }
    }

    /// Checks the layout rules for the runs of one line; returns the layouts of the drawn runs:
    /// - scales within the visible range, each run starting at its box, never reaching the next word;
    /// - one baseline; one font size, except for words that are forced smaller: those are squeezed to the minimum
    ///   scale and end right before the next word.
    @discardableResult
    static func checkLine(_ runs: [DigitalTextRun], sourceLocation: SourceLocation = #_sourceLocation) -> [VisibleRunLayout] {
        let layouts = DigitalPageText.visibleLayouts(runs)
        let drawn = zip(runs, layouts).compactMap { run, layout in layout.map { (run, $0) } }
        #expect(!drawn.isEmpty, sourceLocation: sourceLocation)
        let baselines = Set(drawn.map(\.1.origin.y))
        #expect(baselines.count == 1, "eine Grundlinie je Zeile: \(baselines)", sourceLocation: sourceLocation)
        let lineSize = drawn.map(\.1.fontSize).max() ?? 0
        let lineHeight = Double(runs.first?.lineRect.height ?? 0)
        let gap = DigitalPageText.visibleGap * naturalWidth(" ", size: DigitalPageText.fontSize(forHeight: lineHeight))
        for (run, layout) in drawn {
            let text = run.tokens.map(\.text).joined(separator: " ")
            #expect(layout.horizontalScale >= DigitalPageText.visibleMinimumScale - 1e-9
                    && layout.horizontalScale <= DigitalPageText.visibleMaximumScale + 1e-9,
                    "\(text): Skalierung \(layout.horizontalScale)", sourceLocation: sourceLocation)
            #expect(abs(layout.origin.x - run.rect.minX) < 1e-9, "\(text) beginnt an der Wortbox", sourceLocation: sourceLocation)
            let next = runs.map(\.rect.minX).filter { $0 > run.rect.minX + 0.01 }.min()
            if let next {
                #expect(layout.origin.x + layout.width <= next + 1e-6,
                        "\(text) reicht bis \(layout.origin.x + layout.width), nächstes Wort ab \(next)", sourceLocation: sourceLocation)
            }
            if layout.fontSize < lineSize - 1e-9 {
                // Forced: only when the word does not fit before the next one (the last word: before its overflow
                // limit) even at the minimum scale.
                #expect(abs(layout.horizontalScale - DigitalPageText.visibleMinimumScale) < 1e-9, "\(text)", sourceLocation: sourceLocation)
                let limit = next.map { $0 - gap } ?? (max(run.rect.maxX, run.lineRect.maxX) + DigitalPageText.lastWordOverflow * lineHeight)
                #expect(layout.origin.x + layout.width >= limit - 1e-3,
                        "\(text) ist kleiner, ohne an das nächste Wort zu stoßen: \(layout), Grenze \(limit)",
                        sourceLocation: sourceLocation)
            }
            if run.isWholeLine {
                #expect(layout.width <= DigitalPageText.wholeLineOverflow * run.lineRect.width + 1e-6, sourceLocation: sourceLocation)
            }
        }
        return drawn.map(\.1)
    }

    static func naturalWidth(_ text: String, size: Double) -> Double {
        let font = CTFontCreateWithName(DigitalPageText.regularFont as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    @Test("Modus Text: grobe Wortboxen verzerren die Wörter nicht; eine Schriftgröße und Grundlinie je Zeile")
    func coarseWordBoxes() throws {
        let lines = Self.seedLines()
        for line in lines {
            let runs = DigitalPageText.runs(for: [line], highlights: [], arrows: [], size: Self.seedPage)
            #expect(runs.count == line.words.count)
            let layouts = Self.checkLine(runs)
            // Drawn width stays close to the natural width, whatever the box.
            for (run, layout) in zip(runs, layouts) {
                let natural = Self.naturalWidth(run.tokens[0].text, size: layout.fontSize)
                #expect(layout.width <= 1.1 * natural + 1e-6 && layout.width >= 0.85 * natural - 1e-6, "\(run.tokens[0].text)")
            }
        }
        // The seed boxes really are coarse: "Ort:" has more than twice, "ist" and "der" 1.5 times their width.
        let ort = try #require(DigitalPageText.runs(for: [lines[1]], highlights: [], arrows: [], size: Self.seedPage).first)
        let size = try #require(DigitalPageText.visibleLayouts([ort]).first??.fontSize)
        #expect(ort.rect.width >= 2 * Self.naturalWidth("Ort:", size: size))
        let third = DigitalPageText.runs(for: [lines[2]], highlights: [], arrows: [], size: Self.seedPage)
        let thirdSize = try #require(DigitalPageText.visibleLayouts(third)[1]?.fontSize)
        #expect(third[1].rect.width >= 1.5 * Self.naturalWidth("ist", size: thirdSize))
        #expect(third[2].rect.width >= 1.5 * Self.naturalWidth("der", size: thirdSize))

        // Boxes of exactly 3 ("Ort:") and 2 ("ist", "der") natural widths: drawn at (nearly) natural width, one size.
        let height = 24.0, lineSize = DigitalPageText.fontSize(forHeight: height)
        let factors: [(String, Double)] = [("Ort:", 3), ("ist", 2), ("der", 2), ("Licht", 1)]
        var x = 60.0
        var words: [RecognizedWord] = []
        for (text, factor) in factors {
            let width = factor * Self.naturalWidth(text, size: lineSize)
            words.append(RecognizedWord(text: text, rect: NormalizedRect(x: x / 600, y: 0.5, width: width / 600, height: height / 800)))
            x += width + 8
        }
        let coarse = RecognizedLine(
            text: factors.map(\.0).joined(separator: " "),
            rect: NormalizedRect(x: 60.0 / 600, y: 0.5, width: (x - 68) / 600, height: height / 800), words: words)
        let coarseRuns = DigitalPageText.runs(for: [coarse], highlights: [], arrows: [], size: Self.seedPage)
        let coarseLayouts = Self.checkLine(coarseRuns)
        #expect(Set(coarseLayouts.map(\.fontSize)).count == 1)
        for (run, layout) in zip(coarseRuns, coarseLayouts) {
            #expect(layout.width <= 1.1 * Self.naturalWidth(run.tokens[0].text, size: lineSize) + 1e-6, "\(run.tokens[0].text)")
        }
    }

    @Test("Modus Text: zu enge Wortboxen – Wörter überlappen das nächste Wort nicht, Grundlinie bleibt gemeinsam")
    func tightWordBoxes() throws {
        let size = PageSize(width: 600, height: 800)
        let lineRect = NormalizedRect(x: 0.1, y: 0.4, width: 0.3, height: 0.04)
        // Three words squeezed into 0.3 of the page: every box is narrower than its word.
        let texts = ["Fotosynthese", "braucht", "Licht"]
        let words = texts.enumerated().map { i, text in
            RecognizedWord(text: text, rect: NormalizedRect(x: 0.1 + Double(i) * 0.1, y: 0.4, width: 0.09, height: 0.04))
        }
        let tight = RecognizedLine(text: texts.joined(separator: " "), rect: lineRect, words: words)
        let runs = DigitalPageText.runs(for: [tight], highlights: [], arrows: [], size: size)
        let layouts = Self.checkLine(runs)
        #expect(layouts.allSatisfy { $0.fontSize < DigitalPageText.fontSize(forHeight: 0.04 * 800) }, "die ganze Zeile wird kleiner")

        // Only one word too tight: that word alone gets smaller, on the shared baseline.
        var one = words
        one[0].rect = NormalizedRect(x: 0.1, y: 0.4, width: 0.03, height: 0.04)
        one[1].rect = NormalizedRect(x: 0.14, y: 0.4, width: 0.2, height: 0.04)
        one[2].rect = NormalizedRect(x: 0.36, y: 0.4, width: 0.1, height: 0.04)
        var line = tight
        line.words = one
        line.rect = NormalizedRect(x: 0.1, y: 0.4, width: 0.36, height: 0.04)
        let oneRuns = DigitalPageText.runs(for: [line], highlights: [], arrows: [], size: size)
        let oneLayouts = Self.checkLine(oneRuns)
        #expect(oneLayouts[0].fontSize < oneLayouts[1].fontSize)
        #expect(oneLayouts[1].fontSize == oneLayouts[2].fontSize)
    }

    @Test("Modus Text: korrigierte Zeile mit anderer Wortzahl steht als Ganzes, höchstens 10 % breiter als die Zeile")
    func wholeLineRun() throws {
        var line = Self.seedLines()[2]
        line.text = "Chlorophyll ist der grüne Farbstoff der Blätter und noch viel mehr Text"
        line.isUserCorrected = true
        let runs = DigitalPageText.runs(for: [line], highlights: [], arrows: [], size: Self.seedPage)
        #expect(runs.count == 1 && runs[0].isWholeLine)
        let layout = try #require(Self.checkLine(runs).first)
        #expect(layout.width <= 1.1 * runs[0].lineRect.width + 1e-6)

        line.text = "Chlorophyll"
        let short = DigitalPageText.runs(for: [line], highlights: [], arrows: [], size: Self.seedPage)
        let shortLayout = try #require(Self.checkLine(short).first)
        #expect(shortLayout.horizontalScale <= DigitalPageText.visibleMaximumScale, "kurzer Text wird nicht auf die Zeile gezogen")
    }

    // MARK: Editable page with a scan or flattened writing

    /// 612 × 792 editable page: a page-sized scan with the printed word "Scanwort" (or flattened vector writing) and
    /// one Ink word (scribble at x 100…200, y 200…230).
    static func editablePage(scan: Bool) -> (data: Data, written: NormalizedRect) {
        let scribble = S.scribble(x: 100, y: 200, w: 100, h: 30)
        if scan {
            let (rgb, rect) = Self.scanImage(width: 612, height: 792)
            let data = MiniPDF.page(
                width: 612, height: 792, content: "q 612 0 0 792 0 0 cm /Im1 Do Q",
                resources: "<< /XObject << /Im1 6 0 R >> >>", annotations: [scribble],
                extra: [.stream(dictionary: "/Type /XObject /Subtype /Image /Width 612 /Height 792 /ColorSpace /DeviceRGB /BitsPerComponent 8", data: rgb)])
            return (data, rect)
        }
        // Flattened writing: thick zig-zag paths in the page content (x 300…460, y 600…630).
        var path = "q 0 g 0 G 3 w 1 J 300 602 m"
        for i in 1...16 { path += " \(300 + i * 10) \(i % 2 == 0 ? 602 : 628) l" }
        path += " S Q"
        let data = MiniPDF.page(width: 612, height: 792, content: path, annotations: [scribble])
        return (data, NormalizedRect(x: 298.0 / 612, y: (792 - 630.0) / 792, width: 164.0 / 612, height: 32.0 / 792))
    }

    /// RGB bytes of a scanned page: off-white paper with the dark word "Scanwort"; also the word's normalized rect.
    static func scanImage(width: Int, height: Int) -> (Data, NormalizedRect) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var rect = NormalizedRect.zero
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Scanwort", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 300, y: 600)
            let bounds = CTLineGetImageBounds(line, context)
            CTLineDraw(line, context)
            rect = NormalizedRect(
                x: (bounds.minX - 2) / Double(width), y: (Double(height) - bounds.maxY - 2) / Double(height),
                width: (bounds.width + 4) / Double(width), height: (bounds.height + 4) / Double(height))
        }
        var rgb = Data(capacity: width * height * 3)
        for i in 0..<(width * height) { rgb.append(contentsOf: rgba[(i * 4)..<(i * 4 + 3)]) }
        return (rgb, rect)
    }

    static func editableInput(scan: Bool) -> (input: DigitalPageInput, written: NormalizedRect, ink: NormalizedRect) {
        let (data, written) = Self.editablePage(scan: scan)
        let ink = NormalizedRect(x: 98.0 / 612, y: (792 - 232.0) / 792, width: 104.0 / 612, height: 34.0 / 792)
        let lines = [
            RecognizedLine(text: "Scanwort", rect: written, words: [RecognizedWord(text: "Scanwort", rect: written)], order: 0),
            RecognizedLine(text: "Tinte", rect: ink, words: [RecognizedWord(text: "Tinte", rect: ink)], order: 1),
        ]
        return (DigitalPageInput(background: .pdf(data: data, pageIndex: 0, variant: nil), lines: lines), written, ink)
    }

    @Test("Bearbeitbares PDF mit Scan und Tinte: gedruckter Scantext bleibt unverändert, die Tinte wird ausgeblendet")
    func editableWithScan() throws {
        let (input, written, ink) = Self.editableInput(scan: true)
        let original = try DigitalPageTests.image(input, .handwriting)
        let hidden = try DigitalPageTests.image(input, .textLayer, drawsText: false)
        let shown = try DigitalPageTests.image(input, .textLayer)
        #expect(original.ink(in: written) > 200)
        #expect(original.ink(in: ink) > 100)
        // Live ink on the page: the scan is a printed worksheet; its text is neither painted over nor redrawn.
        #expect(hidden.ink(in: written) == original.ink(in: written), "Scantext unverändert: \(hidden.ink(in: written))")
        #expect(shown.ink(in: written) == original.ink(in: written), "kein Text über dem Scantext")
        #expect(Double(hidden.ink(in: ink)) <= 0.02 * Double(original.ink(in: ink)), "Tinte ausgeblendet: \(hidden.ink(in: ink))")
        #expect(shown.ink(in: ink) > hidden.ink(in: ink) + 50, "Text steht an der Stelle der Tinte")

        let document = try DigitalPageTests.pdf([input])
        let page = try #require(document.page(at: 0))
        #expect(S.counts(S.tokens(page.string ?? "")) == ["scanwort": 1, "tinte": 1])
    }

    @Test("Bearbeitbares PDF mit eingebetteter Schrift ohne Tinte: kein sichtbarer Text darüber, nur in der Textebene")
    func editableWithFlattenedWriting() throws {
        let (input, written, ink) = Self.editableInput(scan: false)
        let original = try DigitalPageTests.image(input, .handwriting)
        let shown = try DigitalPageTests.image(input, .textLayer)
        #expect(original.ink(in: written) > 200)
        #expect(shown.meanDifference(to: original, in: written) < 0.5, "die Schrift bleibt unverändert, nichts darüber")
        #expect(Double(shown.count(in: ink) { r, g, b in max(r, g, b) < 100 }) > 50, "die Tinte wird durch Text ersetzt")

        let document = try DigitalPageTests.pdf([input])
        let page = try #require(document.page(at: 0))
        #expect(S.findsText("Scanwort", on: page, in: written))
    }

    // MARK: Sources

    @Test("Quellen: höchstens zwei PDFs offen, gleiche Bytes finden dasselbe PDF, jeder Aufruf zeichnet mit eigenem Dokument")
    func sourcesCache() throws {
        let sources = DigitalPageSources()
        let a = try sources.pdf(DigitalPageTests.rotatedPage)
        let again = try sources.pdf(Data(Array(DigitalPageTests.rotatedPage)))
        #expect(again === a, "gleiche Bytes, andere Data-Instanz")
        _ = try sources.pdf(DigitalPageTests.arrowPage)
        _ = try sources.pdf(DigitalPageTests.picturePage)
        #expect(sources.cached.count == DigitalPageSources.capacity)
        #expect(!sources.cached.contains { $0 === a }, "das am längsten nicht benutzte PDF ist entlassen")
        let reopened = try sources.pdf(DigitalPageTests.rotatedPage)
        #expect(reopened !== a)
        #expect(sources.cached.last === reopened)

        let opened = try sources.pdf(DigitalPageTests.arrowPage)
        let first = try opened.checkOut()
        let second = try opened.checkOut()
        #expect(first !== second, "ein zweiter Aufruf wartet nicht, er bekommt ein eigenes Dokument")
        opened.checkIn(first)
        opened.checkIn(second)
        let reused = try opened.checkOut()
        #expect(reused === first)
    }

    @Test("Quellen: gleichzeitige Aufrufe mit denselben Quellen liefern dieselben Bilder wie nacheinander")
    func concurrentBuilds() async throws {
        let input = try S.editableInput(0)
        let sources = DigitalPageSources()
        let modes: [DigitalPageMode] = [.handwriting, .textLayer]
        var reference: [DigitalPageMode: S.Pixels] = [:]
        for mode in modes {
            reference[mode] = S.Pixels(try DigitalPageBuilder.makeImage(input, mode: mode, scale: 1, sources: DigitalPageSources()))
        }
        let results = try await withThrowingTaskGroup(of: (DigitalPageMode, S.Pixels).self) { group in
            for index in 0..<8 {
                let mode = modes[index % 2]
                group.addTask { (mode, S.Pixels(try DigitalPageBuilder.makeImage(input, mode: mode, scale: 1, sources: sources))) }
            }
            var all: [(DigitalPageMode, S.Pixels)] = []
            for try await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 8)
        for (mode, pixels) in results {
            let expected = try #require(reference[mode])
            #expect(pixels.meanDifference(to: expected) < 0.01, "\(mode): \(pixels.meanDifference(to: expected))")
        }
    }

    @Test("Modus Text verändert das geteilte Dokument nicht: Handschrift und PDF danach sehen aus wie das Original")
    func textModeLeavesSharedDocument() throws {
        let input = try S.editableInput(0)
        let data = try S.data(.fotosyntheseEditable)
        let sources = DigitalPageSources()
        let originalDocument = try #require(PDFDocument(data: data))
        let originalPage = try #require(originalDocument.page(at: 0))
        let original = S.Pixels(try #require(PageRenderer.render(page: originalPage, scale: 1.5)))

        _ = try DigitalPageBuilder.makeImage(input, mode: .textLayer, scale: 1.5, sources: sources)
        let handwriting = S.Pixels(try DigitalPageBuilder.makeImage(input, mode: .handwriting, scale: 1.5, sources: sources))
        #expect(handwriting.meanDifference(to: original) < 0.3, "\(handwriting.meanDifference(to: original))")

        _ = try DigitalPageBuilder.makeImage(input, mode: .textLayer, scale: 1.5, sources: sources)
        let pdfData = try DigitalPageBuilder.makePDF([input], sources: sources)
        let pdf = try #require(PDFDocument(data: pdfData))
        let pdfPage = try #require(pdf.page(at: 0))
        let rendered = S.Pixels(try #require(PageRenderer.render(page: pdfPage, scale: 1.5)))
        #expect(rendered.meanDifference(to: original) < 0.5, "\(rendered.meanDifference(to: original))")

        // The cached document shows all its ink.
        let cached = try sources.pdf(data).checkOut()
        let inks = try #require(cached.page(at: 0)).annotations.filter { $0.type == "Ink" }
        #expect(!inks.isEmpty)
        let hiddenInks = inks.filter { !$0.shouldDisplay }.count
        #expect(hiddenInks == 0)
    }

    // MARK: Short underline on a photo

    /// A photo (900 × 200 px, beige paper) with the dark text "Die Sonne ist hell" and a short underline below "ist".
    static func underlinedPhoto() throws -> (input: DigitalPageInput, underline: NormalizedRect, words: [NormalizedRect]) {
        let width = 900, height = 200
        let context = try requireValue(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.92, blue: 0.84, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ink = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.2, alpha: 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let texts = ["Die", "Sonne", "ist", "hell"]
        let text = texts.joined(separator: " ")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        ]))
        let x0 = 60.0, baseline = 100.0
        context.textPosition = CGPoint(x: x0, y: baseline)
        CTLineDraw(line, context)
        // Word boxes (pixels, bottom-left): from the cap height down to just below the underline.
        let top = baseline + 30, bottom = baseline - 12
        var location = 0
        var boxes: [CGRect] = []
        for word in texts {
            let start = CTLineGetOffsetForStringIndex(line, location, nil)
            let end = CTLineGetOffsetForStringIndex(line, location + word.count, nil)
            boxes.append(CGRect(x: x0 + start, y: bottom, width: end - start, height: top - bottom))
            location += word.count + 1
        }
        // The underline: 3 px thick, 6 px below the baseline, as long as "ist".
        let underline = CGRect(x: boxes[2].minX, y: baseline - 8, width: boxes[2].width, height: 3)
        context.setFillColor(ink)
        context.fill(underline)
        let photo = try requireValue(context.makeImage())
        let png = try requireValue(PageRenderer.pngData(from: photo))

        func normalized(_ r: CGRect) -> NormalizedRect {
            NormalizedRect(x: r.minX / Double(width), y: (Double(height) - r.maxY) / Double(height),
                           width: r.width / Double(width), height: r.height / Double(height))
        }
        let words = boxes.map(normalized)
        let lineRect = words.dropFirst().reduce(words[0]) { $0.union($1) }
        let recognized = RecognizedLine(
            text: text, rect: lineRect, words: zip(texts, words).map { RecognizedWord(text: $0, rect: $1) })
        return (DigitalPageInput(background: .image(data: png), lines: [recognized]), normalized(underline), words)
    }

    @Test("Foto: eine kurze Unterstreichung unter einem Wort bleibt im Modus Text stehen")
    func shortUnderlineOnPhoto() throws {
        let (input, underline, words) = try Self.underlinedPhoto()
        let original = try DigitalPageTests.image(input, .handwriting, scale: 1)
        let hidden = try DigitalPageTests.image(input, .textLayer, scale: 1, drawsText: false)
        let kept = hidden.ink(in: underline), before = original.ink(in: underline)
        #expect(before > 60)
        #expect(Double(kept) >= 0.9 * Double(before), "Unterstreichung: \(kept) von \(before) Pixeln")
        // The writing itself is gone (outside the underline).
        let glyphs = words.map { NormalizedRect(x: $0.x, y: $0.y, width: $0.width, height: underline.y - $0.y - 0.005) }
        let left = glyphs.reduce(0) { $0 + hidden.ink(in: $1) }, all = glyphs.reduce(0) { $0 + original.ink(in: $1) }
        #expect(all > 1000)
        #expect(Double(left) <= 0.02 * Double(all), "Schrift: \(left) von \(all) Pixeln übrig")
    }

    @Test("Waagrechte Linien: Regel für kurze Unterstreichungen, Bindestriche und t-Striche bleiben Schrift")
    func horizontalLineRule() {
        let h = 40.0
        func line(_ length: Int, thick: Double, width: Int = 600) -> Bool {
            DigitalPagePaper.isHorizontalLine(length: length, areaWidth: width, lineHeight: h, thickness: { thick })
        }
        #expect(line(400, thick: 20), "über 60 % der Breite")
        #expect(line(70, thick: 8), "länglich, 1,5 Zeilenhöhen")
        #expect(line(30, thick: 3), "dünn und mindestens 0,6 Zeilenhöhen lang")
        #expect(!line(16, thick: 3), "Bindestrich")
        #expect(!line(30, thick: 12), "zu dick für einen Strich")
        #expect(!line(50, thick: 15), "ein Buchstabenbogen")
    }
}
