import CoreGraphics
import Foundation
import StudyCore
import StudyImport
import TestFixtures
import Testing

@Suite("Goodnotes: Stiftfarben und Farbebenen")
struct GoodnotesInkLayerTests {
    private static let scale = 2.0

    /// Truth: ink items that are pens (everything Ink except highlighters), in annotation order.
    private func truthPenColors(_ truth: GoodnotesGroundTruth, page: Int) -> [RGBColor] {
        let items = truth.pages[page - 1].items.filter { $0.annotationSubtype == "Ink" && $0.kind != .highlighter }
        return GoodnotesTestSupport.distinct(items.compactMap { $0.colorHex.flatMap { RGBColor(hex: $0) } })
    }

    @Test("penColors entspricht den Stiftfarben der Wahrheit je Seite, Reihenfolge des ersten Auftretens")
    func penColorsMatchTruth() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        for page in loaded.document.pages {
            let colors = InkLayerRenderer.penColors(on: page)
            let expected = truthPenColors(loaded.truth, page: page.index + 1)
            #expect(colors.count == expected.count, "Seite \(page.index + 1): \(colors.map(\.hex)) statt \(expected.map(\.hex))")
            for (actual, wanted) in zip(colors, expected) {
                #expect(actual.distance(to: wanted) < 0.01, "\(actual.hex) != \(wanted.hex)")
            }
            // Highlighter yellow never becomes a pen layer.
            #expect(!colors.contains { $0.isYellowish })
        }
        #expect(InkLayerRenderer.penColors(on: loaded.document.pages[0]).count == 4)
    }

    @Test("penColors fasst fast gleiche Farben zusammen und ignoriert Textmarker")
    func penColorClustering() {
        let size = PageSize(width: 100, height: 100)
        let pts = [PDFPoint(x: 10, y: 10), PDFPoint(x: 50, y: 10)]
        let page = GoodnotesPage(index: 0, size: size, strokes: [
            InkStroke(points: pts, color: RGBColor(red: 0.8, green: 0.1, blue: 0.1), width: 2),
            InkStroke(points: pts, color: RGBColor(red: 0.82, green: 0.11, blue: 0.1), width: 2),
            InkStroke(points: pts, color: RGBColor(red: 1, green: 0.9, blue: 0), width: 18),
            InkStroke(points: pts, color: RGBColor(red: 0, green: 0, blue: 1), width: 2),
            InkStroke(points: pts, color: RGBColor(red: 0.05, green: 0.05, blue: 0.05), width: 2),
        ])
        let colors = InkLayerRenderer.penColors(on: page)
        #expect(colors.count == 3)
        #expect(colors[0].red > 0.7)
        #expect(colors[1].blue > 0.9)
        #expect(colors[2].isNearlyBlack)
    }

    @Test("renderLayer: weißer Grund, Striche der Farbe schwarz, andere Farben und Textmarker fehlen")
    func renderLayersMatchTruth() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        for page in loaded.document.pages {
            let pageNumber = page.index + 1
            let words = loaded.truth.items(ofKind: .inkWord, onPage: pageNumber)
            for color in InkLayerRenderer.penColors(on: page) {
                let image = try #require(InkLayerRenderer.renderLayer(of: page, color: color, scale: Self.scale))
                #expect(image.width == Int((page.size.width * Self.scale).rounded(.up)))
                #expect(image.height == Int((page.size.height * Self.scale).rounded(.up)))
                let pixels = GoodnotesTestSupport.grayPixels(image)
                // The corner (paper) is white.
                #expect(pixels[0] == 255)

                for word in words {
                    let wordColor = RGBColor(hex: word.colorHex ?? "") ?? .black
                    let rect = GoodnotesTestSupport.normalized(word.bbox, truth: loaded.truth).insetBy(dx: 0.002, dy: 0.002)
                    let dark = GoodnotesTestSupport.darkPixelCount(in: pixels, width: image.width, height: image.height, rect: rect)
                    if wordColor.distance(to: color) < 0.12 {
                        #expect(dark >= 20, "\(word.id) \(word.text ?? "") fehlt in der Ebene \(color.hex)")
                    } else {
                        #expect(dark == 0, "\(word.id) \(word.text ?? "") (\(wordColor.hex)) stört in Ebene \(color.hex)")
                    }
                }
            }
        }
    }

    @Test("renderLayer: Textmarker-Gelb, Stempel und FreeText erzeugen keine Pixel")
    func highlighterAndShapesAreNotRendered() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let page = loaded.document.pages[0]
        let yellow = try #require(page.highlighterStrokes.first?.color)
        let yellowLayer = try #require(InkLayerRenderer.renderLayer(of: page, color: yellow, scale: 1))
        #expect(!GoodnotesTestSupport.grayPixels(yellowLayer).contains { $0 < 255 })

        // Union of all pen layers: nothing outside the area of ink items (no highlighter band, no stamp, no FreeText).
        var darkest = [UInt8](repeating: 255, count: yellowLayer.width * yellowLayer.height)
        var size = (yellowLayer.width, yellowLayer.height)
        for color in InkLayerRenderer.penColors(on: page) {
            let image = try #require(InkLayerRenderer.renderLayer(of: page, color: color, scale: 1))
            size = (image.width, image.height)
            let pixels = GoodnotesTestSupport.grayPixels(image)
            for i in pixels.indices { darkest[i] = min(darkest[i], pixels[i]) }
        }
        let inkItems = loaded.truth.pages[0].items.filter { $0.annotationSubtype == "Ink" && $0.kind != .highlighter }
        let inkRects = inkItems.map { GoodnotesTestSupport.normalized($0.bbox, truth: loaded.truth).insetBy(dx: -0.004, dy: -0.004) }
        let protected = loaded.truth.pages[0].items.filter { $0.kind == .highlighter || $0.kind == .freeText || $0.kind == .stamp }
        for item in protected {
            let rect = GoodnotesTestSupport.normalized(item.bbox, truth: loaded.truth)
            let x0 = Int(rect.minX * Double(size.0)), x1 = Int(rect.maxX * Double(size.0))
            let y0 = Int(rect.minY * Double(size.1)), y1 = Int(rect.maxY * Double(size.1))
            var stray = 0
            for y in max(0, y0)..<min(size.1, y1) {
                for x in max(0, x0)..<min(size.0, x1) where darkest[y * size.0 + x] < 128 {
                    let nx = Double(x) / Double(size.0), ny = Double(y) / Double(size.1)
                    if !inkRects.contains(where: { $0.contains(x: nx, y: ny) }) { stray += 1 }
                }
            }
            #expect(stray == 0, "\(item.kind.rawValue) \(item.id): \(stray) Pixel außerhalb der Stiftstriche")
        }
    }

    @Test("renderLayer: ungültige Eingaben und unbekannte Farbe")
    func renderEdgeCases() throws {
        let loaded = try GoodnotesTestSupport.load(.fotosyntheseEditable)
        let page = loaded.document.pages[0]
        #expect(InkLayerRenderer.renderLayer(of: page, color: .black, scale: 0) == nil)
        // An absurd scale is clamped to the maximum image size instead of failing.
        let huge = try #require(InkLayerRenderer.renderLayer(of: page, color: .black, scale: 1000))
        #expect(Double(max(huge.width, huge.height)) <= PageRenderer.maxSide)
        #expect(Double(huge.width) * Double(huge.height) <= PageRenderer.maxPixels * 1.01)
        // A color without strokes gives an all-white image, not nil.
        let magenta = try #require(InkLayerRenderer.renderLayer(of: page, color: RGBColor(red: 1, green: 0, blue: 1), scale: 1))
        #expect(!GoodnotesTestSupport.grayPixels(magenta).contains { $0 < 255 })
    }
}
