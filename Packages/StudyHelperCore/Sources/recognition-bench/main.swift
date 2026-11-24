// recognition-bench <pdf> <out.json> [pages…]
// Digitizes a (local, never committed) PDF with the real pipeline and writes every page's lines as JSON,
// so that scripts/score-recognition.py can compare runs against a reference and against each other.
// Used to tune the recognition on real Goodnotes exports in LocalSamples/ (docs/DECISIONS.md D-022).
import Foundation
import StudyCore
import StudyImport

struct BenchLine: Codable {
    var text: String
    var status: String
    var reasons: [String]
    var rect: [Double]
}
struct BenchParagraph: Codable {
    var text: String
    var rect: [Double]
    var lines: Int
}
struct BenchPage: Codable {
    var page: Int
    var lines: [BenchLine]
    var paragraphs: [BenchParagraph]
    var warnings: [String]
    var error: String?
}
struct BenchRun: Codable {
    var file: String
    var seconds: Double
    var pages: [BenchPage]
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("Aufruf: recognition-bench <pdf> <out.json> [Seiten…]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let selected = Set(arguments.dropFirst(3).compactMap { Int($0) }.map { $0 - 1 })
let data = try Data(contentsOf: input)
let pipeline = DigitizationPipeline(recognizer: VisionTextRecognizer())

func box(_ r: NormalizedRect) -> [Double] { [r.x, r.y, r.width, r.height].map { ($0 * 10000).rounded() / 10000 } }

nonisolated(unsafe) var pages: [BenchPage] = []
let start = Date()
try await pipeline.digitizePDFPages(data: data, pageIndices: selected.isEmpty ? nil : selected) { result, _, _ in
    switch result {
    case .success(let page):
        let lines = page.result.lines.sorted { $0.order < $1.order }
        pages.append(BenchPage(
            page: page.pageIndex + 1,
            lines: lines.map { BenchLine(text: $0.text, status: $0.status.rawValue, reasons: $0.reviewReasons.map(\.rawValue), rect: box($0.rect)) },
            paragraphs: page.result.paragraphs.map { BenchParagraph(text: $0.text, rect: box($0.rect), lines: $0.lineIDs.count) },
            warnings: page.result.warnings, error: nil))
    case .failure(let failure):
        pages.append(BenchPage(page: failure.pageIndex + 1, lines: [], paragraphs: [], warnings: [], error: "\(failure)"))
    }
}
let run = BenchRun(file: input.lastPathComponent, seconds: Date().timeIntervalSince(start), pages: pages.sorted { $0.page < $1.page })
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(run).write(to: output)
print("\(run.pages.count) Seiten in \(String(format: "%.1f", run.seconds)) s → \(output.path)")
