import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
import TestFixtures
@testable import StudyImport

@Suite("Eingebetteter PDF-Text: gedrehte Seiten")
struct EmbeddedTextRotationTests {
    /// Share of dark pixels inside `rect` of a rendered page.
    func darkShare(_ image: CGImage, in rect: NormalizedRect) -> Double {
        let width = image.width, height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var dark = 0, total = 0
        for py in Int(rect.minY * Double(height))..<min(height, Int(rect.maxY * Double(height)) + 1) {
            for px in Int(rect.minX * Double(width))..<min(width, Int(rect.maxX * Double(width)) + 1) {
                total += 1
                if pixels[(py * width + px) * 4] < 110 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    @Test("Bei gedrehten Seiten liegen die Rechtecke auf dem gedrehten Bild des Texts", arguments: [0, 90, 180, 270])
    func rotatedPages(rotation: Int) throws {
        let source = try #require(PDFDocument(url: DigitalWorksheetFixture.url))
        let original = try #require(source.page(at: 0))
        original.rotation = rotation
        let data = try #require(source.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: data))
        let page = try #require(reloaded.page(at: 0))
        let size = PageRenderer.pageSize(of: page)
        #expect(rotation % 180 == 0 ? size.width < size.height : size.width > size.height)

        let extracted = try #require(EmbeddedTextExtractor.extract(from: page))
        #expect(extracted.pageSize == size)
        let image = try #require(PageRenderer.render(page: page, scale: 2, includeAnnotations: true))
        let title = try #require(extracted.lines.first)
        #expect(darkShare(image, in: title.rect) > 0.08, "Titel steht im gedrehten Bild an dieser Stelle (\(rotation) Grad)")
        // The mirrored position must be empty paper.
        let mirrored = NormalizedRect(x: 1 - title.rect.maxX, y: 1 - title.rect.maxY, width: title.rect.width, height: title.rect.height)
        #expect(darkShare(image, in: mirrored) < 0.02)
    }
}
