#if canImport(AppKit)
import AppKit
import Foundation
import Testing

@testable import StudyCore

/// macOS spell checker (German) for checks against a local recognition dump. Not used in regular test runs.
private struct MacSpellChecker: SpellChecking, @unchecked Sendable {
    let checker = NSSpellChecker.shared

    func isKnown(_ word: String) -> Bool {
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: "de", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    func guesses(for word: String) -> [String] {
        checker.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word, language: "de",
            inSpellDocumentWithTag: 0) ?? []
    }
}

/// Runs the word marking on a local recognition dump (`scripts/bench-recognition.sh` JSON: pages → lines with
/// text, rect, status, reasons). Only with `WORD_REVIEW_SAMPLE=<path>`; `WORD_REVIEW_PAGES=2,6` picks pages.
@Suite("Wortprüfung an lokaler Probe (nur mit WORD_REVIEW_SAMPLE)")
struct WordReviewSampleTests {
    private struct Dump: Decodable {
        struct Page: Decodable { var page: Int?; var lines: [Line] }
        struct Line: Decodable {
            var text: String; var rect: [Double]; var status: String; var reasons: [String]?; var origin: String?
        }
        var pages: [Page]
    }

    @Test("Einzelne Wörter prüfen (WORD_REVIEW_PROBE=Wort,Wort)", .enabled(if: ProcessInfo.processInfo.environment["WORD_REVIEW_PROBE"] != nil))
    @MainActor
    func probe() {
        let checker = MacSpellChecker()
        for word in (ProcessInfo.processInfo.environment["WORD_REVIEW_PROBE"] ?? "").split(separator: ",").map(String.init) {
            print("\(word): \(checker.isKnown(word) ? "bekannt" : "unbekannt") \(checker.guesses(for: word).prefix(5))")
        }
    }

    @Test("Markierte Wörter der Probe ausgeben",.enabled(if: ProcessInfo.processInfo.environment["WORD_REVIEW_SAMPLE"] != nil))
    @MainActor
    func sample() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["WORD_REVIEW_SAMPLE"])
        let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let wanted = (environment["WORD_REVIEW_PAGES"] ?? "2,6").split(separator: ",").compactMap { Int($0) }
        let checker = MacSpellChecker()
        for pageNumber in wanted where dump.pages.indices.contains(pageNumber - 1) {
            let page = dump.pages[pageNumber - 1]
            let lines = page.lines.enumerated().map { index, line in
                RecognizedLine(
                    text: line.text,
                    rect: NormalizedRect(x: line.rect[0], y: line.rect[1], width: line.rect[2], height: line.rect[3]),
                    status: ConfidenceStatus(rawValue: line.status) ?? .confident,
                    reviewReasons: (line.reasons ?? []).compactMap(ReviewReason.init(rawValue:)), order: index,
                    origin: line.origin.flatMap(LineOrigin.init(rawValue:)))
            }
            let result = WordReview.review(lines, checker: checker, isEmbedded: WordReview.isEmbedded)
            var report: [String] = []
            for line in lines {
                guard let marks = result.marks[line.id] else { continue }
                let tokens = WordReview.tokens(of: line)
                for index in marks {
                    let reason = result.reasons[WordReference(lineID: line.id, wordIndex: index)]
                    report.append("\(tokens[index].text) [\(reason?.rawValue ?? "?")]")
                }
            }
            print("Seite \(pageNumber): \(result.openCount) offene Stellen: " + report.joined(separator: ", "))
        }
    }
}
#endif
