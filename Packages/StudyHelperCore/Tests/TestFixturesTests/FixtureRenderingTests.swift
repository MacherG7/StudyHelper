import CoreGraphics
import Foundation
import Testing
@testable import TestFixtures
#if canImport(PDFKit)
import PDFKit

/// RGBA pixels of one rendered page (row 0 = top of the page).
struct PageBitmap: Sendable {
    let width: Int
    let height: Int
    let scale: Double
    let pixels: [UInt8]

    /// Renders with PDFKit (the same engine that shows the PDF in the app). `PDFPage.draw(with:to:)` draws the
    /// annotations' appearance streams, unlike `CGContext.drawPDFPage`.
    static func render(_ page: PDFPage, scale: Double, annotations: Bool = true) -> PageBitmap {
        page.displaysAnnotations = annotations
        let box = page.bounds(for: .mediaBox)
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            preconditionFailure("no bitmap context")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return PageBitmap(width: width, height: height, scale: scale,
                          pixels: Array(UnsafeBufferPointer(start: data, count: width * height * 4)))
    }

    static func render(_ pdf: Data, page index: Int, scale: Double, annotations: Bool = true) -> PageBitmap {
        guard let doc = PDFDocument(data: pdf), let page = doc.page(at: index) else {
            preconditionFailure("cannot open page \(index)")
        }
        return render(page, scale: scale, annotations: annotations)
    }

    /// Pixel rows/columns of a PDF-space rectangle (origin bottom-left), clamped to the bitmap.
    func pixelRange(of r: CGRect, pageHeight: Double) -> (xs: Range<Int>, ys: Range<Int>) {
        let x0 = max(0, Int((r.minX * scale).rounded(.down))), x1 = min(width, Int((r.maxX * scale).rounded(.up)))
        let y0 = max(0, Int(((pageHeight - r.maxY) * scale).rounded(.down)))
        let y1 = min(height, Int(((pageHeight - r.minY) * scale).rounded(.up)))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    /// Mean absolute RGB difference per channel (0...255) over the whole page.
    func meanDifference(to other: PageBitmap) -> Double {
        precondition(pixels.count == other.pixels.count)
        var sum = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<3 { sum += abs(Int(pixels[i + c]) - Int(other.pixels[i + c])) }
        }
        return Double(sum) / Double(pixels.count / 4 * 3)
    }

    /// Fraction of pixels whose largest channel difference exceeds `threshold`.
    func changedFraction(to other: PageBitmap, threshold: Int = 40) -> Double {
        precondition(pixels.count == other.pixels.count)
        var changed = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if (0..<3).contains(where: { abs(Int(pixels[i + $0]) - Int(other.pixels[i + $0])) > threshold }) { changed += 1 }
        }
        return Double(changed) / Double(pixels.count / 4)
    }

    func changedPixels(to other: PageBitmap, in range: (xs: Range<Int>, ys: Range<Int>), threshold: Int = 40) -> Int {
        var changed = 0
        for y in range.ys {
            for x in range.xs {
                let i = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(pixels[i + $0]) - Int(other.pixels[i + $0])) > threshold }) { changed += 1 }
            }
        }
        return changed
    }

    /// Number of pixels in `range` whose RGB is within `tolerance` (per channel) of the given color.
    func pixels(near rgb: (Int, Int, Int), in range: (xs: Range<Int>, ys: Range<Int>), tolerance: Int) -> Int {
        var n = 0
        for y in range.ys {
            for x in range.xs {
                let i = (y * width + x) * 4
                if abs(Int(pixels[i]) - rgb.0) <= tolerance && abs(Int(pixels[i + 1]) - rgb.1) <= tolerance
                    && abs(Int(pixels[i + 2]) - rgb.2) <= tolerance { n += 1 }
            }
        }
        return n
    }
}

private func rgb(_ hex: String) -> (Int, Int, Int) {
    let v = Int(hex.dropFirst(), radix: 16) ?? 0
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
}

/// Renders shared by the tests of this file (computed once, lazily, thread-safe).
private enum Renders {
    static let scale = 1.5

    static func pages(_ fixture: GoodnotesFixture, annotations: Bool = true) -> [PageBitmap] {
        guard let data = try? Data(contentsOf: fixture.url), let doc = PDFDocument(data: data) else {
            preconditionFailure("cannot open \(fixture.fileName)")
        }
        return (0..<doc.pageCount).map { PageBitmap.render(doc.page(at: $0)!, scale: scale, annotations: annotations) }
    }

    static let editable = pages(.fotosyntheseEditable)
    static let editableWithoutAnnotations = pages(.fotosyntheseEditable, annotations: false)
    static let reduced = pages(.fotosyntheseReduced)
}

@Suite("Goodnotes-Fixtures: Rendering mit PDFKit")
struct FixtureRenderingTests {
    @Test("Appearance-Streams der Annotationen werden wirklich gezeichnet (Seite mit vs. ohne Annotationen)",
          arguments: [1, 2, 3])
    func annotationsDrawAtTheirItems(pageNumber: Int) throws {
        let truth = try GoodnotesFixture.fotosyntheseEditable.loadTruth()
        let with = Renders.editable[pageNumber - 1], without = Renders.editableWithoutAnnotations[pageNumber - 1]
        #expect(with.changedFraction(to: without) > 0.002, "Seite \(pageNumber): Annotationen ändern kaum etwas")
        // Hiding the annotations must leave paper, worksheet and image: the page is not blank.
        let blank = PageBitmap(width: with.width, height: with.height, scale: with.scale,
                               pixels: [UInt8](repeating: 255, count: with.pixels.count))
        #expect(without.changedFraction(to: blank) > 0.001, "Seitenhintergrund fehlt")

        for item in truth.pages[pageNumber - 1].items where item.annotationCount > 0 {
            let range = with.pixelRange(of: item.rect.insetBy(dx: -1, dy: -1), pageHeight: truth.pageHeight)
            let changed = with.changedPixels(to: without, in: range)
            #expect(changed >= 4, "\(item.id) (\(item.kind)) wird nicht gezeichnet: \(changed) geänderte Pixel")
            guard let hex = item.colorHex else { continue }
            if item.kind == .highlighter {
                // Multiply of yellow over paper / ruled lines / black ink: strongly yellow pixels must dominate.
                let yellow = with.pixels(near: (255, 230, 0), in: range, tolerance: 30)
                #expect(yellow > 100, "\(item.id): Textmarker nicht gelb (\(yellow) Pixel)")
            } else if item.kind != .freeText {
                let colored = with.pixels(near: rgb(hex), in: range, tolerance: 45)
                #expect(colored >= 2, "\(item.id): Stiftfarbe \(hex) fehlt (\(colored) Pixel)")
            }
        }
        // The FreeText box draws its appearance text (dark pixels inside the box).
        if pageNumber == 1 {
            let free = try #require(truth.items(ofKind: .freeText).first)
            let range = with.pixelRange(of: free.rect, pageHeight: truth.pageHeight)
            #expect(with.pixels(near: (0, 0, 0), in: range, tolerance: 60) > 50)
        }
    }

    @Test("Bearbeitbares und reduziertes PDF sehen gleich aus", arguments: [1, 2, 3])
    func editableAndReducedLookTheSame(pageNumber: Int) {
        let e = Renders.editable[pageNumber - 1], r = Renders.reduced[pageNumber - 1]
        #expect(e.width == r.width && e.height == r.height)
        let mean = e.meanDifference(to: r)
        let changed = e.changedFraction(to: r)
        #expect(mean < 0.15, "Seite \(pageNumber): mittlere Abweichung \(mean)")
        #expect(changed < 0.001, "Seite \(pageNumber): \(changed) der Pixel weichen stark ab")
        // The comparison is meaningful: without annotations the editable page is clearly different.
        #expect(Renders.editableWithoutAnnotations[pageNumber - 1].meanDifference(to: r) > mean * 5)
    }

    @Test("Die unsichtbare Textebene verändert die Darstellung des reduzierten PDFs nicht", arguments: [1, 2, 3])
    func textLayerIsInvisible(pageNumber: Int) throws {
        let fixture = GoodnotesFixture.fotosyntheseReduced
        let withLayer = try fixture.generate(includeTextLayer: true).pdfData
        let withoutLayer = try fixture.generate(includeTextLayer: false).pdfData
        #expect(withLayer.count > withoutLayer.count)
        // The two files differ only by the text layer ...
        let a = try #require(PDFDocument(data: withLayer)?.page(at: pageNumber - 1))
        let b = try #require(PDFDocument(data: withoutLayer)?.page(at: pageNumber - 1))
        let probe = ["Lichtenergie", "Zellmembran", "Produzenten"][pageNumber - 1]
        #expect((a.string ?? "").contains(probe), "Textebene fehlt")
        #expect(!(b.string ?? "").contains(probe), "Textebene sollte fehlen")
        // ... yet render pixel-identically.
        let ra = PageBitmap.render(a, scale: Renders.scale), rb = PageBitmap.render(b, scale: Renders.scale)
        #expect(ra.pixels == rb.pixels, "Seite \(pageNumber): Textebene ist sichtbar")
        #expect(ra.pixels == Renders.reduced[pageNumber - 1].pixels, "Rendering weicht von der Datei im Bundle ab")
    }

    @Test("Kontrolle: ohne Render-Modus 3 wäre die Textebene sichtbar (der Test ist empfindlich)")
    func visibleTextLayerWouldBeDetected() throws {
        let original = try Data(contentsOf: GoodnotesFixture.fotosyntheseReduced.url)
        let visible = try #require(DriftComparison.replacing("3 Tr", with: "0 Tr", in: original, all: true))
        #expect(visible.count == original.count)
        let normal = Renders.reduced[0]
        let broken = PageBitmap.render(visible, page: 0, scale: Renders.scale)
        #expect(normal.changedFraction(to: broken) > 0.002, "sichtbarer Text hätte auffallen müssen")
    }
}
#endif
