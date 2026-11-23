import CoreGraphics
import CoreText
import Foundation
import StudyCore
import StudyImport
import TestFixtures

/// A parsed fixture together with its ground truth.
struct GoodnotesLoaded: Sendable {
    let fixture: GoodnotesFixture
    let document: GoodnotesDocument
    let truth: GoodnotesGroundTruth
}

/// "Perfect" recognition of the handwriting of one page, built from the ground truth (no OCR involved).
struct GoodnotesPerfectPage {
    var lines: [RecognizedLine]
    /// Truth item ID (`p1-w03`) -> reference into `lines`.
    var references: [String: WordReference]
    /// Reverse lookup.
    var itemIDs: [WordReference: String]
}

enum GoodnotesTestSupport {
    private static let cache: [GoodnotesFixture: Result<GoodnotesLoaded, GoodnotesLoadError>] = {
        var result: [GoodnotesFixture: Result<GoodnotesLoaded, GoodnotesLoadError>] = [:]
        for fixture in GoodnotesFixture.allCases {
            do {
                let document = try GoodnotesParser.parse(url: fixture.url)
                let truth = try fixture.loadTruth()
                result[fixture] = .success(GoodnotesLoaded(fixture: fixture, document: document, truth: truth))
            } catch {
                result[fixture] = .failure(GoodnotesLoadError(description: "\(fixture.fileName): \(error)"))
            }
        }
        return result
    }()

    struct GoodnotesLoadError: Error, CustomStringConvertible {
        let description: String
    }

    static func load(_ fixture: GoodnotesFixture) throws -> GoodnotesLoaded {
        try cache[fixture]!.get()
    }

    // MARK: Perfect recognition

    /// Handwritten words of a truth page (`inkWord` items), grouped by line, sorted left to right.
    static func perfectPage(truth: GoodnotesGroundTruth, pageNumber: Int, wordColors: Bool = true) -> GoodnotesPerfectPage {
        let items = truth.items(ofKind: .inkWord, onPage: pageNumber)
        var order: [String] = []
        var byLine: [String: [GoodnotesTruthItem]] = [:]
        for item in items {
            let lineID = item.lineID ?? item.id
            if byLine[lineID] == nil { order.append(lineID) }
            byLine[lineID, default: []].append(item)
        }
        var lines: [RecognizedLine] = []
        var references: [String: WordReference] = [:]
        var itemIDs: [WordReference: String] = [:]
        for (lineNumber, lineID) in order.enumerated() {
            let sorted = byLine[lineID]!.sorted { $0.bbox[0] < $1.bbox[0] }
            let lineUUID = UUID()
            var words: [RecognizedWord] = []
            var lineRect = NormalizedRect.zero
            for (index, item) in sorted.enumerated() {
                let rect = normalized(item.bbox, truth: truth)
                lineRect = lineRect.union(rect)
                words.append(RecognizedWord(
                    text: item.text ?? "", rect: rect,
                    color: wordColors ? item.colorHex.flatMap { RGBColor(hex: $0) } : nil))
                let ref = WordReference(lineID: lineUUID, wordIndex: index)
                references[item.id] = ref
                itemIDs[ref] = item.id
            }
            lines.append(RecognizedLine(
                id: lineUUID, text: words.map(\.text).joined(separator: " "), rect: lineRect, words: words,
                order: lineNumber))
        }
        return GoodnotesPerfectPage(lines: lines, references: references, itemIDs: itemIDs)
    }

    static func normalized(_ bbox: [Double], truth: GoodnotesGroundTruth) -> NormalizedRect {
        .fromBottomLeft(
            x: bbox[0], y: bbox[1], width: bbox[2], height: bbox[3],
            spaceWidth: truth.pageWidth, spaceHeight: truth.pageHeight)
    }

    // MARK: Pixels

    /// Gray values (0 = black) of an image rendered by `InkLayerRenderer`, row 0 = top.
    static func grayPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// Number of dark pixels (< 128) inside a normalized rect (origin top-left).
    static func darkPixelCount(in pixels: [UInt8], width: Int, height: Int, rect: NormalizedRect) -> Int {
        let x0 = max(0, Int((rect.minX * Double(width)).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * Double(width)).rounded(.up)))
        let y0 = max(0, Int((rect.minY * Double(height)).rounded(.down)))
        let y1 = min(height, Int((rect.maxY * Double(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 where pixels[y * width + x] < 128 { count += 1 }
        }
        return count
    }

    // MARK: Colors

    /// Distinct colors by distance (first occurrence order).
    static func distinct(_ colors: [RGBColor], threshold: Double = 0.12) -> [RGBColor] {
        var result: [RGBColor] = []
        for c in colors where !result.contains(where: { $0.distance(to: c) < threshold }) { result.append(c) }
        return result
    }

    // MARK: Synthetic PDFs

    /// A normal digital worksheet: visible text, no annotations (must be detected as `.other`).
    static func plainWorksheetPDF() -> Data {
        worksheetPDF(invisibleText: false)
    }

    /// One A4 page with the text "Arbeitsblatt Zelle" drawn with CoreText, visible or in render mode 3.
    /// `userPassword` makes the file require a password to open.
    static func worksheetPDF(invisibleText: Bool, userPassword: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        var auxiliary: [CFString: Any] = [kCGPDFContextTitle: "Arbeitsblatt"]
        if let userPassword {
            auxiliary[kCGPDFContextUserPassword] = userPassword
            auxiliary[kCGPDFContextOwnerPassword] = userPassword + "-owner"
        }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, auxiliary as CFDictionary) else {
            return Data()
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        for (index, text) in ["Arbeitsblatt", "Zelle", "Aufgabe 1: Benenne die Teile."].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 60, y: 760 - 40 * Double(index))
            if invisibleText { context.setTextDrawingMode(.invisible) }
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
