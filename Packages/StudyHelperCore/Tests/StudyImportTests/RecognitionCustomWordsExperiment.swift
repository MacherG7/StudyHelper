import CoreGraphics
import CoreText
import Foundation
import StudyCore
import Testing
@testable import TestFixtures
@testable import StudyImport

/// Experiment for SPEC §2 ("Bereits bestätigte Fachbegriffe des Fachs als `customWords` an Vision übergeben,
/// Wirkung testen und dokumentieren"). Results: docs/experiments/customWords.md.
///
/// Renders subject terms with the same glyph-outline "handwriting" as the Goodnotes fixtures (outlines of
/// Noteworthy, stroked with 1.6 pt) at small sizes and lets Vision read them with and without `customWords`.
/// The outcome depends on the OS and the device, so nothing here asserts Vision's behavior; the test only
/// prints the table. Run it with `CUSTOMWORDS_EXPERIMENT=1 swift test --filter RecognitionCustomWordsExperiment`.
@Suite("customWords-Experiment (informativ)")
struct RecognitionCustomWordsExperiment {
    static let terms = [
        "Thylakoidmembran", "Chlorophyllmolekül", "Mitochondrienmatrix", "Plastochinon",
        "Ribulosebisphosphat", "Stromathylakoid", "Calvin-Zyklus", "Photosystem",
    ]

    /// A word as outline strokes, `pixelsPerPoint` scaled, on white.
    static func render(word: String, fontSize: Double, pixelsPerPoint: Double = 3, lineWidth: Double = 1.6) -> CGImage {
        let font = HandwritingFont(size: fontSize)
        let margin = 12.0
        let layout = font.layoutWord(word, x: margin, baseline: fontSize + margin)
        let width = Int((layout.advance + 2 * margin) * pixelsPerPoint)
        let height = Int((fontSize * 2 + 2 * margin) * pixelsPerPoint)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in layout.strokes {
            guard let first = stroke.first else { continue }
            context.move(to: CGPoint(x: first.x, y: first.y))
            for p in stroke.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
            context.strokePath()
        }
        return context.makeImage()!
    }

    struct Reading {
        var best: String
        var candidates: [String]
        var exact: Bool
        var inCandidates: Bool
        var distance: Int
    }

    static func read(_ image: CGImage, term: String, customWords: [String], languageCorrection: Bool) async throws -> Reading {
        let options = TextRecognitionOptions(
            usesLanguageCorrection: languageCorrection, customWords: customWords, prefersDocumentRecognition: false,
            maximumCandidates: 5)
        let output = try await VisionTextRecognizer().recognize(image, options: options)
        let line = output.lines.first
        let best = line?.text ?? ""
        let expected = WordTokenizer.normalize(term)
        let candidates = [best] + (line?.candidates ?? [])
        return Reading(
            best: best, candidates: line?.candidates ?? [],
            exact: WordTokenizer.normalize(best) == expected,
            inCandidates: candidates.contains { WordTokenizer.normalize($0) == expected },
            distance: WordAlignment.characterDistance(WordTokenizer.normalize(best), expected))
    }

    @Test("customWords-Experiment", .enabled(if: ProcessInfo.processInfo.environment["CUSTOMWORDS_EXPERIMENT"] != nil))
    func experiment() async throws {
        var report = ""
        func log(_ line: String) { report += line + "\n" }
        let sizes = [12.0, 16.0, 22.0]

        struct Variant { var name: String; var customWords: (String) -> [String]; var languageCorrection: Bool }
        let variants = [
            Variant(name: "ohne customWords, Korrektur an", customWords: { _ in [] }, languageCorrection: true),
            Variant(name: "ohne customWords, Korrektur aus", customWords: { _ in [] }, languageCorrection: false),
            Variant(name: "customWords = [Begriff], Korrektur an", customWords: { [$0] }, languageCorrection: true),
            Variant(name: "customWords = [Begriff], Korrektur aus", customWords: { [$0] }, languageCorrection: false),
            Variant(name: "customWords = alle 8 Begriffe, Korrektur an", customWords: { _ in Self.terms }, languageCorrection: true),
            Variant(name: "customWords = Begriff + Kleinschreibung, Korrektur an", customWords: { [$0, $0.lowercased()] }, languageCorrection: true),
        ]

        log("Einzelne Wörter (\(Self.terms.count) Begriffe x \(sizes.count) Größen = \(Self.terms.count * sizes.count) Fälle je Variante)")
        for variant in variants {
            var exact = 0, anyCandidate = 0, distance = 0, total = 0
            var details: [String] = []
            for term in Self.terms {
                for size in sizes {
                    let reading = try await Self.read(Self.render(word: term, fontSize: size), term: term,
                                                      customWords: variant.customWords(term), languageCorrection: variant.languageCorrection)
                    total += 1
                    if reading.exact { exact += 1 }
                    if reading.inCandidates { anyCandidate += 1 }
                    distance += reading.distance
                    details.append("\(term)@\(Int(size)): \(reading.best)")
                }
            }
            log("\n\(variant.name): exakt \(exact)/\(total), Begriff unter den Kandidaten \(anyCandidate)/\(total), Summe Editierabstand \(distance)")
            log(details.joined(separator: "; "))
        }

        // Harder conditions: very small writing and a lower rendering scale.
        for pixelsPerPoint in [2.0, 3.0] {
            let small = [9.0, 10.0, 11.0]
            log("\nSchwierigere Bedingungen: Größen \(small.map { Int($0) }), \(Int(pixelsPerPoint)) px pro pt")
            for variant in [variants[0], variants[2], variants[4]] {
                var exact = 0, total = 0, distance = 0
                var details: [String] = []
                for term in Self.terms {
                    for size in small {
                        let image = Self.render(word: term, fontSize: size, pixelsPerPoint: pixelsPerPoint)
                        let reading = try await Self.read(image, term: term, customWords: variant.customWords(term), languageCorrection: variant.languageCorrection)
                        total += 1
                        if reading.exact { exact += 1 }
                        distance += reading.distance
                        details.append("\(term)@\(Int(size)): \(reading.best)")
                    }
                }
                log("\(variant.name): exakt \(exact)/\(total), Summe Editierabstand \(distance)")
                log(details.joined(separator: "; "))
            }
        }

        // Side effects: do the custom words pull other words towards them?
        let others = ["Membran", "Photosynthese", "Stroma", "Zellkern", "Chloroplast", "Mitochondrium", "Thylakoid", "Molekül", "Matrix", "Zyklus"]
        var changed: [String] = []
        var differing = 0
        for word in others {
            for size in [10.0, 12.0, 16.0] {
                let image = Self.render(word: word, fontSize: size, pixelsPerPoint: 2)
                let without = try await Self.read(image, term: word, customWords: [], languageCorrection: true)
                let with = try await Self.read(image, term: word, customWords: Self.terms, languageCorrection: true)
                if without.best != with.best { differing += 1; changed.append("\(word)@\(Int(size)): \(without.best) -> \(with.best)") }
            }
        }
        log("\nNebenwirkung: \(others.count * 3) andere Wörter mit und ohne die 8 customWords gelesen: \(differing) Lesungen weichen ab. \(changed.joined(separator: "; "))")

        // In a sentence, the way the pipeline sees it (the terms are one word of a line).
        log("\nBegriff im Satz („Die <Begriff> ist wichtig“), Größe 16")
        for variant in variants.prefix(4) {
            var exact = 0
            var details: [String] = []
            for term in Self.terms {
                let font = HandwritingFont(size: 16)
                // Render the sentence as one image by laying out the words one after another.
                let words = ["Die", term, "ist", "wichtig"]
                let image = Self.renderLine(words, font: font)
                let options = TextRecognitionOptions(usesLanguageCorrection: variant.languageCorrection, customWords: variant.customWords(term), prefersDocumentRecognition: false)
                let output = try await VisionTextRecognizer().recognize(image, options: options)
                let text = output.lines.map(\.text).joined(separator: " ")
                if text.lowercased().contains(term.lowercased()) { exact += 1 }
                details.append(text)
            }
            log("\(variant.name): Begriff exakt im Satz \(exact)/\(Self.terms.count); \(details.joined(separator: "; "))")
        }
        print("CUSTOMWORDS REPORT\n\(report)")
    }

    static func renderLine(_ words: [String], font: HandwritingFont) -> CGImage {
        let pixelsPerPoint = 3.0, margin = 12.0
        var pen = margin
        var strokes: [[Pt]] = []
        for word in words {
            let layout = font.layoutWord(word, x: pen, baseline: font.size + margin)
            strokes += layout.strokes
            pen += layout.advance + font.spaceAdvance
        }
        let width = Int((pen + margin) * pixelsPerPoint), height = Int((font.size * 2 + 2 * margin) * pixelsPerPoint)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            context.move(to: CGPoint(x: first.x, y: first.y))
            for p in stroke.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
            context.strokePath()
        }
        return context.makeImage()!
    }

    @Test("Ein gerendertes Wort ist nicht leer und hat sinnvolle Größe")
    func renderSanity() {
        let image = Self.render(word: "Thylakoidmembran", fontSize: 16)
        #expect(image.width > 200 && image.height > 50)
    }
}
