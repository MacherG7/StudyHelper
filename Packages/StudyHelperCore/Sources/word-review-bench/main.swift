#if canImport(AppKit)
// word-review-bench: measures the word-level review (WordReview, D-044) and its reading suggestions
// (VisionWordCandidateProvider, D-046) on a local, never committed sample (LocalSamples/, see docs/MANUAL_TESTS.md).
//
//   swift run -c release word-review-bench dump <pdf> <lines.json> [pages…]
//       Runs the real digitization pipeline and writes every page's RecognizedLines as JSON.
//   swift run -c release word-review-bench measure <pdf> <lines.json> <ref.json> <out.json>
//                                                 [--rerank] [--terms none|suggested|reference] [--subject <name>]
//       Aligns the recognized words with the reference text (`*.reference.json`: {"pages": {"2": ["line", …]}}),
//       marks them with WordReview (NSSpellChecker "de" instead of UITextChecker; without terms, with the reference's
//       unknown words as terms, and with the terms TermSuggestions proposes), and asks the production provider for
//       suggestions for every wrong or marked word. --rerank lets the on-device Apple model reorder the candidates
//       (as the app does), --terms chooses the subject terms passed to the provider (default: none).
//
//   scripts/score-word-review.py <out.json> [--list] turns the output into tables.
import Foundation
import StudyCore
import StudyImport

let args = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
guard args.count >= 4 else {
    fail("Aufruf: word-review-bench dump <pdf> <lines.json> [Seiten…] | measure <pdf> <lines.json> <ref.json> <out.json>")
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

// MARK: dump

/// Collects the pages of the pipeline's callback (called serially).
final class PageCollector: @unchecked Sendable {
    var pages: [String: [RecognizedLine]] = [:]
}

if args[1] == "dump" {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let selected = Set(args.dropFirst(4).compactMap { Int($0) }.map { $0 - 1 })
    let pipeline = DigitizationPipeline(recognizer: VisionTextRecognizer())
    let collector = PageCollector()
    try await pipeline.digitizePDFPages(data: data, pageIndices: selected.isEmpty ? nil : selected) { result, _, _ in
        if case .success(let page) = result {
            collector.pages[String(page.pageIndex + 1)] = page.result.lines.sorted { $0.order < $1.order }
        }
    }
    try encoder.encode(collector.pages).write(to: URL(fileURLWithPath: args[3]))
    print("\(collector.pages.count) Seiten → \(args[3])")
    exit(0)
}

// MARK: measure

guard args[1] == "measure", args.count >= 6 else { fail("measure braucht <pdf> <lines.json> <ref.json> <out.json>") }
let useModel = args.contains("--rerank") && AppleModel.isAvailable
if args.contains("--rerank"), !useModel { FileHandle.standardError.write(Data("Apple-Modell nicht verfügbar\n".utf8)) }
let termMode = option("--terms") ?? "none"
let subject = option("--subject") ?? "Geographie"

let pdfData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let allLines = try JSONDecoder().decode(
    [String: [RecognizedLine]].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
struct Reference: Decodable { var pages: [String: [String]] }
let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
let checker = CachingSpellChecker(MacSpellChecker())
let sources = DigitalPageSources()
let provider = VisionWordCandidateProvider(sources: sources)
let timing = RerankTiming()

struct Suggestions: Codable {
    var local: [String] = []
    var localTerms: [String] = []
    /// The production provider's candidates, best first, with their sources.
    var provider: [String] = []
    var providerSources: [[String]] = []
    var providerScores: [Double] = []
    var seconds: Double = 0
    /// Seconds of the model's answer (nil without --rerank).
    var rerankSeconds: Double?
    var known: [String: Bool] = [:]
}

struct TokenRecord: Codable {
    var page: Int
    var line: Int
    var index: Int
    var text: String
    var core: String
    var ref: String?
    var alignment: String                  // match | sub | extra
    var wrong: Bool
    var caseOnly: Bool                     // matches the reference except for upper/lower case
    var structural: Bool
    var wordStatus: String
    var hasWordRect: Bool
    var rect: [Double]
    var bandRect: [Double]
    var lineText: String
    var lineStatus: String
    var lineOrigin: String?
    var lineTokenCount: Int
    var lineCost: Double
    var contextWords: Int
    var markedPlain: String?               // reason or nil
    var markedTerms: String?               // with the reference's unknown words as terms
    var markedSuggested: String?           // with TermSuggestions' terms adopted
    var suggestions: Suggestions?
}

struct PageSummary: Codable {
    var page: Int
    var referenceWords: Int
    var missingReferenceWords: [String]
    var terms: [String]
}

struct Output: Codable {
    var model: Bool
    var termMode: String
    var suggestedTerms: [String]
    var firstCallSeconds: Double?
    var tokens: [TokenRecord]
    var pages: [PageSummary]
}

func box(_ r: NormalizedRect) -> [Double] { [r.x, r.y, r.width, r.height].map { ($0 * 10000).rounded() / 10000 } }

let pageKeys = reference.pages.keys.compactMap(Int.init).sorted()
// Terms the app would propose for the whole document (every page of the reference).
let documentLines = pageKeys.flatMap { key in
    (allLines[String(key)] ?? []).map { line -> RecognizedLine in
        var copy = line
        copy.order += key * 10_000
        return copy
    }
}
let suggestedTerms = TermSuggestions.candidates(lines: documentLines, checker: checker, known: [])

var records: [TokenRecord] = []
var summaries: [PageSummary] = []
var firstCallSeconds: Double?
let started = Date()

for pageNumber in pageKeys {
    let pageKey = String(pageNumber)
    guard let lines = allLines[pageKey], let refLines = reference.pages[pageKey] else { continue }
    var refTokens: [RefToken] = []
    for (i, l) in refLines.enumerated() {
        for t in WordTokenizer.tokens(in: l) {
            refTokens.append(RefToken(text: t.original, norm: t.normalized, folded: t.folded, refLine: i))
        }
    }
    // Reference terms: reference words the spell check (WordReview rules) does not accept.
    let refAsLines = refTokens.enumerated().map {
        RecognizedLine(text: $1.text, rect: .zero, order: $0, origin: .recognizer)
    }
    let refReview = WordReview.review(refAsLines, checker: checker)
    let refTerms = Set(refAsLines.filter { refReview.marks[$0.id] != nil }.map { WordReview.splitPunctuation($0.text).core })
    let providerTerms: Set<String> = switch termMode {
    case "reference": refTerms
    case "suggested": Set(suggestedTerms)
    default: []
    }

    let plain = WordReview.review(lines, checker: checker)
    let withTerms = WordReview.review(lines, checker: checker, terms: refTerms)
    let withSuggested = WordReview.review(lines, checker: checker, terms: Set(suggestedTerms))

    var covered = Set<Int>()
    var expectedEnd = 0
    for line in lines where !WordReview.isEmbedded(line) && !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
        let tokens = WordReview.tokens(of: line)
        let wordTokens = WordTokenizer.tokens(in: line.text)
        let (steps, cost) = ReferenceAligner.align(wordTokens, refTokens, expectedEnd: expectedEnd + wordTokens.count)
        var refFor: [Int: String] = [:]
        var kind: [Int: String] = [:]
        for step in steps {
            switch step {
            case .match(let i, let j):
                refFor[i] = refTokens[j].text; kind[i] = "match"; covered.insert(j); expectedEnd = j + 1
            case .sub(let i, let j):
                refFor[i] = refTokens[j].text; kind[i] = "sub"; covered.insert(j); expectedEnd = j + 1
            case .extra(let i): kind[i] = "extra"
            case .missing: break
            }
        }
        for token in tokens {
            let i = token.index
            let k = kind[i] ?? "extra"
            let ref = refFor[i]
            let wrong = k != "match"
            let reference = WordReference(lineID: line.id, wordIndex: i)
            let core = token.core
            let structural = core.count <= 1 || core.allSatisfy { $0.isNumber || ".,:/-–".contains($0) }
            let ctx = WordReview.context(of: i, in: line.id, lines: lines, radius: 8)
            let ctxCount = WordTokenizer.tokens(in: ctx.before).count + WordTokenizer.tokens(in: ctx.after).count
            var record = TokenRecord(
                page: pageNumber, line: line.order, index: i, text: token.text, core: core, ref: ref, alignment: k,
                wrong: wrong, caseOnly: !wrong && ref.map { WordReview.splitPunctuation($0).core != core } == true,
                structural: structural, wordStatus: token.status.rawValue, hasWordRect: token.wordIndex != nil,
                rect: box(token.rect), bandRect: box(WordGeometry.bandRect(for: token.rect, line: line, pageLines: lines)),
                lineText: line.text, lineStatus: line.status.rawValue, lineOrigin: line.origin?.rawValue,
                lineTokenCount: tokens.count, lineCost: cost, contextWords: ctxCount,
                markedPlain: plain.reasons[reference]?.rawValue, markedTerms: withTerms.reasons[reference]?.rawValue,
                markedSuggested: withSuggested.reasons[reference]?.rawValue, suggestions: nil)

            let marked = record.markedPlain != nil || record.markedTerms != nil || record.markedSuggested != nil
            if (wrong || marked) && !structural {
                var s = Suggestions()
                s.local = WordReview.localSuggestions(line: line, wordIndex: i, checker: checker)
                s.localTerms = WordReview.localSuggestions(line: line, wordIndex: i, checker: checker, terms: refTerms)
                let request = WordRereadRequest(
                    background: .pdf(data: pdfData, pageIndex: pageNumber - 1, variant: nil), line: line, wordIndex: i,
                    pageLines: lines, terms: providerTerms, spellChecker: checker,
                    rerank: useModel ? AppleModel.rerank(subject: subject, timing: timing) : nil)
                if firstCallSeconds == nil {
                    // The first call opens and parses the PDF; measured separately.
                    let start = Date()
                    _ = try await provider.candidates(for: request)
                    firstCallSeconds = Date().timeIntervalSince(start)
                    _ = timing.drain()
                }
                let start = Date()
                let candidates = try await provider.candidates(for: request)
                s.seconds = Date().timeIntervalSince(start)
                s.rerankSeconds = timing.drain().last
                s.provider = candidates.map(\.text)
                s.providerSources = candidates.map { $0.sources.map(\.rawValue).sorted() }
                s.providerScores = candidates.map { ($0.score * 1000).rounded() / 1000 }
                for c in s.local + s.localTerms + s.provider + [core] where s.known[c] == nil {
                    s.known[c] = WordReview.review(
                        [RecognizedLine(text: c, rect: .zero, origin: .recognizer)], checker: checker, terms: refTerms
                    ).marks.isEmpty
                }
                record.suggestions = s
            }
            records.append(record)
        }
    }
    let missing = refTokens.indices.filter { !covered.contains($0) }.map { refTokens[$0].text }
    summaries.append(PageSummary(
        page: pageNumber, referenceWords: refTokens.count, missingReferenceWords: missing, terms: refTerms.sorted()))
    let count = records.filter { $0.page == pageNumber }.count
    let elapsed = String(format: "%.0f", Date().timeIntervalSince(started))
    FileHandle.standardError.write(Data("Seite \(pageNumber): \(count) Wörter, \(elapsed) s\n".utf8))
}

try encoder.encode(Output(
    model: useModel, termMode: termMode, suggestedTerms: suggestedTerms, firstCallSeconds: firstCallSeconds,
    tokens: records, pages: summaries
)).write(to: URL(fileURLWithPath: args[5]))
print("\(records.count) Wörter → \(args[5]) (Modell: \(useModel ? "ja" : "nein"), Fachbegriffe: \(termMode))")

#else
print("word-review-bench läuft nur auf dem Mac.")
#endif
