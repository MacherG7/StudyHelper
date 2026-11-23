import CoreGraphics
import Foundation
import PDFKit
import StudyCore

/// Reads the text layer of every page with PDFKit: `page.string` is split into words and every word is
/// located with `selection(for:)`. Rects are normalized (origin top-left), relative to the MediaBox.
enum GoodnotesTextLayerReader {
    static func readAll(data: Data, pageCount: Int) -> [[TextLayerWord]] {
        guard let document = PDFDocument(data: data) else { return [] }
        if document.isLocked { _ = document.unlock(withPassword: "") }
        var result: [[TextLayerWord]] = []
        for index in 0..<min(pageCount, document.pageCount) {
            guard let page = document.page(at: index) else {
                result.append([])
                continue
            }
            result.append(words(of: page))
        }
        return result
    }

    static func words(of page: PDFPage) -> [TextLayerWord] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return [] }
        let ns = string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var words: [TextLayerWord] = []
        var i = 0
        let length = ns.length
        while i < length {
            while i < length, isWhitespace(ns.character(at: i), whitespace) { i += 1 }
            let start = i
            while i < length, !isWhitespace(ns.character(at: i), whitespace) { i += 1 }
            guard i > start else { continue }
            let range = NSRange(location: start, length: i - start)
            guard let selection = page.selection(for: range) else { continue }
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { continue }
            let rect = NormalizedRect.fromBottomLeft(
                x: Double(bounds.minX - box.minX), y: Double(bounds.minY - box.minY),
                width: Double(bounds.width), height: Double(bounds.height),
                spaceWidth: Double(box.width), spaceHeight: Double(box.height))
            words.append(TextLayerWord(text: ns.substring(with: range), rect: rect))
        }
        return words
    }

    private static func isWhitespace(_ unit: unichar, _ set: CharacterSet) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return set.contains(scalar)
    }
}
