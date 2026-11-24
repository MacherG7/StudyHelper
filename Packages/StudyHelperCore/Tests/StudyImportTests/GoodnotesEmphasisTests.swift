import Foundation
import StudyCore
import StudyImport
import TestFixtures
import Testing

@Suite("Goodnotes: Hervorhebungen aus Annotationen und Strichformen")
struct GoodnotesEmphasisTests {
    private struct PageResult {
        let page: GoodnotesPage
        let perfect: GoodnotesPerfectPage
        let highlights: [RecognizedHighlight]
        let truthPage: Int

        /// Truth item IDs of the words of a highlight.
        func itemIDs(of highlight: RecognizedHighlight) -> Set<String> {
            Set(highlight.words.compactMap { perfect.itemIDs[$0] })
        }

        func highlights(of kind: HighlightKind) -> [RecognizedHighlight] {
            highlights.filter { $0.kind == kind }
        }
    }

    private func analyse(_ loaded: GoodnotesLoaded, pageIndex: Int, wordColors: Bool = true) -> PageResult {
        let page = loaded.document.pages[pageIndex]
        let perfect = GoodnotesTestSupport.perfectPage(truth: loaded.truth, pageNumber: pageIndex + 1, wordColors: wordColors)
        let highlights = GoodnotesEmphasisDetector.detect(page: page, lines: perfect.lines)
        return PageResult(page: page, perfect: perfect, highlights: highlights, truthPage: pageIndex + 1)
    }

    private func allPages() throws -> (GoodnotesLoaded, [PageResult]) {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        return (loaded, (0..<3).map { analyse(loaded, pageIndex: $0) })
    }

    // MARK: Highlighter

    @Test("Textmarker: genau die Wörter der Wahrheit, Beinahe-Treffer nie enthalten")
    func highlighterWordsMatchTruth() throws {
        let (loaded, pages) = try allPages()
        let truthHighlighters = loaded.truth.items(ofKind: .highlighter)
        #expect(truthHighlighters.count == 3)
        #expect(truthHighlighters.contains { $0.relatedItemIDs.count == 2 })
        #expect(truthHighlighters.contains { !$0.incidentalItemIDs.isEmpty })

        let found = pages.flatMap { $0.highlights(of: .highlighter) }
        #expect(found.count == truthHighlighters.count)

        for truth in truthHighlighters {
            let truthPage = Int(truth.id.dropFirst().prefix(while: { $0.isNumber })) ?? 1
            let page = pages[truthPage - 1]
            let expected = Set(truth.relatedItemIDs)
            let match = page.highlights(of: .highlighter).first { page.itemIDs(of: $0) == expected }
            let highlight = try #require(match, "Textmarker \(truth.id): erwartet \(expected.sorted()), gefunden \(page.highlights(of: .highlighter).map { page.itemIDs(of: $0).sorted() })")
            for incidental in truth.incidentalItemIDs {
                #expect(!page.itemIDs(of: highlight).contains(incidental), "\(incidental) darf nicht dazugehören")
            }
            #expect(highlight.source == .goodnotesAnnotation)
            #expect(highlight.status == .confident)
            #expect(highlight.color?.isYellowish == true)
            #expect(highlight.suggestedMeaning == .important)
            // Text is the words joined in reading order.
            let words = expected.sorted().compactMap { loaded.truth.item(withID: $0) }.sorted { $0.bbox[0] < $1.bbox[0] }
            #expect(highlight.text == words.compactMap(\.text).joined(separator: " "))
            // The rect is the area of the mark and covers the words' boxes at least horizontally.
            let truthRect = GoodnotesTestSupport.normalized(truth.bbox, truth: loaded.truth)
            #expect(highlight.rect.iou(truthRect) > 0.9)
        }
    }

    @Test("Textmarker: zwei Striche über denselben Wörtern ergeben eine Hervorhebung")
    func highlighterStrokesAreMerged() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        var page = loaded.document.pages[0]
        let perfect = GoodnotesTestSupport.perfectPage(truth: loaded.truth, pageNumber: 1)
        let original = try #require(page.highlighterStrokes.first)
        page.strokes.append(original)  // the same stroke a second time
        let highlights = GoodnotesEmphasisDetector.detect(page: page, lines: perfect.lines).filter { $0.kind == .highlighter }
        #expect(highlights.count == 3)
    }

    // MARK: Underlines

    @Test("Unterstreichung: Fotosynthese, ganze Zeile, kein Buchstabenteil, Bedeutung offen")
    func underlineMatchesTruth() throws {
        let (loaded, pages) = try allPages()
        let truthUnderlines = loaded.truth.items(ofKind: .underline)
        #expect(truthUnderlines.count == 1)
        let all = pages.flatMap { $0.highlights(of: .underline) }
        #expect(all.count == truthUnderlines.count, "gefunden: \(all.map(\.text))")
        for truth in truthUnderlines {
            let page = pages[(Int(truth.id.dropFirst().prefix(while: { $0.isNumber })) ?? 1) - 1]
            let expected = Set(truth.relatedItemIDs)
            let highlight = try #require(page.highlights(of: .underline).first { page.itemIDs(of: $0) == expected })
            #expect(highlight.source == .goodnotesShape)
            #expect(highlight.suggestedMeaning == nil)
            #expect(highlight.status == .confident)
            #expect(highlight.text == "Fotosynthese")
            #expect(highlight.rect.iou(GoodnotesTestSupport.normalized(truth.bbox, truth: loaded.truth)) > 0.8)
        }
    }

    @Test("Doppelte Unterstreichung: zwei parallele Striche werden eine Hervorhebung")
    func doubleUnderlineMatchesTruth() throws {
        let (loaded, pages) = try allPages()
        let truthDouble = loaded.truth.items(ofKind: .doubleUnderline)
        #expect(truthDouble.count == 1)
        #expect(pages.flatMap { $0.highlights(of: .doubleUnderline) }.count == 1)
        for truth in truthDouble {
            let page = pages[(Int(truth.id.dropFirst().prefix(while: { $0.isNumber })) ?? 1) - 1]
            let highlight = try #require(page.highlights(of: .doubleUnderline).first { page.itemIDs(of: $0) == Set(truth.relatedItemIDs) })
            #expect(highlight.source == .goodnotesShape)
            #expect(highlight.text == "Zellwand")
            // The two strokes are not additionally reported as two single underlines.
            #expect(!page.highlights(of: .underline).contains { page.itemIDs(of: $0) == Set(truth.relatedItemIDs) })
            #expect(highlight.color?.distance(to: RGBColor(hex: truth.colorHex ?? "") ?? .black) ?? 1 < 0.01)
        }
    }

    @Test("Tabellenlinien zählen nicht als Unterstreichung")
    func tableLinesAreNoUnderlines() throws {
        let (loaded, pages) = try allPages()
        let tableLines = loaded.truth.items(ofKind: .tableLine, onPage: 3)
        #expect(tableLines.count >= 6)
        let page3 = pages[2]
        #expect(page3.highlights(of: .underline).isEmpty)
        #expect(page3.highlights(of: .doubleUnderline).isEmpty)
        // No underline/double underline anywhere sits on a table line.
        for h in pages.flatMap({ $0.highlights }) where h.kind == .underline || h.kind == .doubleUnderline {
            for line in tableLines {
                let rect = GoodnotesTestSupport.normalized(line.bbox, truth: loaded.truth)
                #expect(h.rect.iou(rect) < 0.5)
            }
        }
        // Without the vertical grid lines the horizontal ones would qualify: proves that the grid rule does the work.
        var stripped = loaded.document.pages[2]
        let verticalNames = Set(tableLines.filter { $0.emphasis == "vertical" }.map(\.id))
        stripped.strokes.removeAll { stroke in
            guard let name = stroke.name else { return false }
            return verticalNames.contains(String(name.prefix(while: { $0 != "#" })))
        }
        let withoutGrid = GoodnotesEmphasisDetector.detect(page: stripped, lines: page3.perfect.lines)
        #expect(withoutGrid.contains { $0.kind == .underline || $0.kind == .doubleUnderline })
    }

    @Test("Buchstabenteile der Handschrift sind nie Unterstreichung oder Kreis")
    func glyphContoursAreIgnored() throws {
        let (_, pages) = try allPages()
        for page in pages {
            for h in page.highlights where h.kind == .underline || h.kind == .doubleUnderline || h.kind == .circled {
                #expect(h.source == .goodnotesShape)
            }
        }
        // Page 1 has lots of handwriting (hundreds of contours) but a single underline and no circle.
        #expect(pages[0].highlights(of: .underline).count == 1)
        #expect(pages[0].highlights(of: .circled).isEmpty)
        #expect(pages[2].highlights(of: .circled).isEmpty)
    }

    // MARK: Circles

    @Test("Kreis: Mitochondrien")
    func circleMatchesTruth() throws {
        let (loaded, pages) = try allPages()
        let truthCircles = loaded.truth.items(ofKind: .circle)
        #expect(truthCircles.count == 1)
        #expect(pages.flatMap { $0.highlights(of: .circled) }.count == 1)
        for truth in truthCircles {
            let page = pages[(Int(truth.id.dropFirst().prefix(while: { $0.isNumber })) ?? 1) - 1]
            let highlight = try #require(page.highlights(of: .circled).first { page.itemIDs(of: $0) == Set(truth.relatedItemIDs) })
            #expect(highlight.text == "Mitochondrien")
            #expect(highlight.source == .goodnotesShape)
            #expect(highlight.suggestedMeaning == .term)
            #expect(highlight.status == .confident)
            #expect(highlight.rect.iou(GoodnotesTestSupport.normalized(truth.bbox, truth: loaded.truth)) > 0.8)
        }
    }

    // MARK: Colored pen

    @Test("Farbiger Stift: je Zeile ein Lauf pro zusammenhängender Farbe")
    func coloredPenRuns() throws {
        let (loaded, pages) = try allPages()
        for page in pages {
            let runs = page.highlights(of: .coloredPen)
            var expectedRuns = 0
            for line in page.perfect.lines {
                let color = line.words.first?.color
                let isColored = color.map { !$0.isNearlyBlack } ?? false
                guard isColored, let color else { continue }
                expectedRuns += 1
                let match = runs.first { Set($0.words.map(\.lineID)) == [line.id] }
                let run = try #require(match, "Zeile \(line.text) ohne farbigen Stift")
                #expect(run.words.count == line.words.count)
                #expect(run.text == line.text)
                #expect(run.color?.distance(to: color) ?? 1 < 0.01)
                #expect(run.source == .goodnotesAnnotation)
                #expect(run.status == .confident)
            }
            #expect(runs.count == expectedRuns, "Seite \(page.truthPage): \(runs.map(\.text))")
        }
        // Page 1: red, blue and green lines.
        let colors = Set(pages[0].highlights(of: .coloredPen).compactMap { $0.color?.hex })
        #expect(colors == Set(["#D32F2F", "#1565C0", "#2E7D32"]))
        _ = loaded
    }

    @Test("Farbiger Stift: gemischte Zeile ergibt mehrere Läufe, Schwarz unterbricht")
    func coloredPenMixedLine() {
        let page = GoodnotesPage(index: 0, size: PageSize(width: 200, height: 100))
        func word(_ text: String, _ x: Double, _ color: RGBColor?) -> RecognizedWord {
            RecognizedWord(text: text, rect: NormalizedRect(x: x, y: 0.4, width: 0.15, height: 0.1), color: color)
        }
        let red = RGBColor(hex: "#D32F2F"), blue = RGBColor(hex: "#1565C0")
        let words = [word("a", 0.0, red), word("b", 0.2, red), word("c", 0.4, .black), word("d", 0.6, blue), word("e", 0.8, nil)]
        let line = RecognizedLine(text: "a b c d e", rect: NormalizedRect(x: 0, y: 0.4, width: 0.95, height: 0.1), words: words)
        let runs = GoodnotesEmphasisDetector.detect(page: page, lines: [line]).filter { $0.kind == .coloredPen }
        #expect(runs.map(\.text) == ["a b", "d"])
        #expect(runs.map(\.color) == [red, blue])
    }

    // MARK: Robustness

    @Test("Ohne Zeilen oder Wörter entsteht nichts, Seiten ohne Striche liefern keine Strichformen")
    func emptyInputs() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        #expect(GoodnotesEmphasisDetector.detect(page: loaded.document.pages[0], lines: []).isEmpty)
        let reduced = try GoodnotesTestSupport.load(.fotosyntheseReduced)
        let perfect = GoodnotesTestSupport.perfectPage(truth: reduced.truth, pageNumber: 1)
        let highlights = GoodnotesEmphasisDetector.detect(page: reduced.document.pages[0], lines: perfect.lines)
        #expect(highlights.allSatisfy { $0.kind == .coloredPen })
    }

    @Test("Wortfarben fehlen: keine farbigen Stifte, Annotationsformen bleiben")
    func withoutWordColors() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let result = analyse(loaded, pageIndex: 0, wordColors: false)
        #expect(result.highlights(of: .coloredPen).isEmpty)
        #expect(result.highlights(of: .highlighter).count == 3)
        #expect(result.highlights(of: .underline).count == 1)
    }

    @Test("Ungenaue Wortboxen (Vision): zu enge und zu weite Boxen ändern die Wörter der Hervorhebungen nicht")
    func sloppyWordBoxes() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        for factor in [0.85, 1.12] {
            for pageIndex in 0..<3 {
                let perfect = GoodnotesTestSupport.perfectPage(truth: loaded.truth, pageNumber: pageIndex + 1)
                var lines = perfect.lines
                for l in lines.indices {
                    var union = NormalizedRect.zero
                    for w in lines[l].words.indices {
                        let r = lines[l].words[w].rect
                        let scaled = NormalizedRect(
                            x: r.midX - r.width * factor / 2, y: r.midY - r.height * factor / 2,
                            width: r.width * factor, height: r.height * factor)
                        lines[l].words[w].rect = scaled
                        union = union.union(scaled)
                    }
                    lines[l].rect = union
                }
                let reference = GoodnotesEmphasisDetector.detect(page: loaded.document.pages[pageIndex], lines: perfect.lines)
                let sloppy = GoodnotesEmphasisDetector.detect(page: loaded.document.pages[pageIndex], lines: lines)
                func signature(_ hs: [RecognizedHighlight]) -> [String] {
                    hs.map { "\($0.kind.rawValue):\($0.text)" }.sorted()
                }
                #expect(signature(sloppy) == signature(reference), "Faktor \(factor), Seite \(pageIndex + 1)")
            }
        }
    }
}
