import CoreGraphics
import Foundation
import PDFKit
import Testing
import TestFixtures
@testable import StudyImport

@Suite("Erkennung: Umgebung und Seiten-Rendering")
struct RecognitionEnvironmentTests {
    @Test("Betriebssystem-Version wird als Name plus Version formatiert")
    func osVersionFormat() {
        #expect(RecognitionEnvironment.formatOSVersion(name: "iOS", version: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0)) == "iOS 27.2")
        #expect(RecognitionEnvironment.formatOSVersion(name: "iOS", version: .init(majorVersion: 27, minorVersion: 2, patchVersion: 1)) == "iOS 27.2.1")
        #expect(RecognitionEnvironment.formatOSVersion(name: "macOS", version: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)) == "macOS 27.0")
    }

    @Test("Aktuelle Umgebung: Version und Gerätemodell sind gefüllt")
    func currentEnvironment() {
        let environment = RecognitionEnvironment.current
        #if os(macOS)
        #expect(environment.osVersion.hasPrefix("macOS "))
        #elseif os(iOS)
        #expect(environment.osVersion.hasPrefix("iOS "))
        #endif
        #expect(!environment.deviceModel.isEmpty)
        #expect(environment.deviceModel != "unknown")
    }

    @Test("Die Umgebung lässt sich für Tests vorgeben")
    func injectable() {
        let environment = RecognitionEnvironment(osVersion: "iOS 27.2", deviceModel: "iPhone17,1")
        #expect(environment.osVersion == "iOS 27.2")
        #expect(environment.deviceModel == "iPhone17,1")
    }

    @Test("Seite wird in der gewünschten Größe gerendert, mit und ohne Annotationen")
    func renderWithAndWithoutAnnotations() throws {
        let document = try #require(PDFDocument(url: GoodnotesFixture.fotosyntheseEditable.url))
        let page = try #require(document.page(at: 0))
        let with = try #require(PageRenderer.render(page: page, scale: 1, includeAnnotations: true))
        let without = try #require(PageRenderer.render(page: page, scale: 1, includeAnnotations: false))
        #expect(with.width == 595 && with.height == 842)
        #expect(without.width == with.width && without.height == with.height)
        #expect(darkPixels(with) > 500, "Stift-Annotationen sichtbar")
        #expect(darkPixels(without) < 50, "ohne Annotationen nur das helle Linienpapier")
        #expect(page.displaysAnnotations, "Zustand der Seite bleibt unverändert")
    }

    @Test("Bilddaten: JPEG und PNG lassen sich wieder laden")
    func encoding() throws {
        let image = blankImage(width: 64, height: 48)
        let jpeg = try #require(PageRenderer.jpegData(from: image))
        let png = try #require(PageRenderer.pngData(from: image))
        #expect(Array(jpeg.prefix(2)) == [0xFF, 0xD8])
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        for data in [jpeg, png] {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == 64 && decoded.height == 48)
        }
    }

    @Test("Verkleinertes Bild hat die erwartete Größe")
    func scaling() throws {
        let scaled = try #require(PageRenderer.scaled(blankImage(width: 200, height: 100), by: 0.7))
        #expect(scaled.width == 140 && scaled.height == 70)
    }

    private func darkPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) where pixels[i] < 100 && pixels[i + 1] < 100 && pixels[i + 2] < 100 { count += 1 }
        return count
    }
}
