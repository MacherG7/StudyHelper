import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Testing
@testable import StudyImport

/// Writes the fixture pages in both modes as PNGs (and the PDFs) for a visual check:
/// `DIGITAL_PAGE_DUMP=1 [DIGITAL_PAGE_DUMP_DIR=…] swift test --filter DigitalPageDump`.
@Suite("Digitale Seite: Bilder zum Ansehen")
struct DigitalPageDumpTests {
    static let enabled = ProcessInfo.processInfo.environment["DIGITAL_PAGE_DUMP"] != nil

    @Test("Fixture-Seiten in beiden Modi als PNG ablegen", .enabled(if: enabled))
    func dump() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["DIGITAL_PAGE_DUMP_DIR"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("digitalpage"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var inputs: [(String, DigitalPageInput)] = []
        for index in 0..<3 { inputs.append(("bearbeitbar-s\(index + 1)", try DigitalPageTestSupport.editableInput(index))) }
        for index in 0..<3 { inputs.append(("reduziert-s\(index + 1)", try DigitalPageTestSupport.reducedInput(index))) }
        for index in 0..<2 { inputs.append(("arbeitsblatt-s\(index + 1)", try DigitalPageTestSupport.worksheetInput(index))) }
        inputs.append(("foto", try DigitalPageTestSupport.photoInput().input))
        let extra: [(String, DigitalPageInput)] = [
            ("formpfeil", DigitalPageTests.arrowInput().input), ("gedreht", DigitalPageTests.rotatedInput()),
        ]
        let sources = DigitalPageSources()
        for (name, input) in inputs + extra {
            for mode in [DigitalPageMode.handwriting, .textLayer] {
                let start = Date()
                let scale = { if case .image = input.background { 1.0 } else { 2.0 } }()
                let image = try DigitalPageBuilder.makeImage(input, mode: mode, scale: scale, sources: sources)
                let ms = Date().timeIntervalSince(start) * 1000
                print("[digitalpage] \(name) \(mode.rawValue): \(Int(ms)) ms")
                let data = try #require(PageRenderer.pngData(from: image))
                try data.write(to: directory.appendingPathComponent("\(name)-\(mode.rawValue).png"))
            }
        }
        for (name, group) in [("bearbeitbar", inputs[0..<3]), ("reduziert", inputs[3..<6]), ("arbeitsblatt", inputs[6..<8]), ("foto", inputs[8..<9])] {
            let start = Date()
            let pdf = try DigitalPageBuilder.makePDF(group.map(\.1), title: "Test", sources: sources)
            print("[digitalpage] PDF \(name): \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(pdf.count / 1024) KB")
            try pdf.write(to: directory.appendingPathComponent("\(name).pdf"))
            if let document = PDFDocument(data: pdf) {
                for index in 0..<document.pageCount {
                    print("[digitalpage] \(name) S.\(index + 1) Text: \(document.page(at: index)?.string?.replacingOccurrences(of: "\n", with: " | ") ?? "")")
                }
            }
        }
    }

    /// Dense handwriting (overlapping line boxes) and a printed question above handwriting, on blank pages; both modes.
    @Test("Dichte Handschrift und feste Zeilen als PNG ablegen", .enabled(if: enabled))
    func dumpDense() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIGITAL_PAGE_DUMP_DIR"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("digitalpage"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paragraph = UUID()
        let dense = DigitalPageDenseTests.lines(DigitalPageDenseTests.denseBoxes.map { ($0.0, $0.1) }, paragraph: paragraph)
        let sheet = DigitalPageDenseTests.worksheet
        let printed = DigitalPageDenseTests.lines(sheet.printed), written = DigitalPageDenseTests.lines(sheet.written)
        for (name, shown, fixed) in [("dicht", dense, []), ("gedruckt-darueber", written, printed)] {
            let size = DigitalPageDenseTests.page
            let runs = DigitalPageText.runs(for: shown, highlights: [], arrows: [], size: size)
            let obstacles = DigitalPageText.obstacleRects(of: shown + fixed, excluding: shown, size: size)
            for withObstacles in [false, true] {
                guard let bitmap = Bitmap(size: size, scale: 2) else { throw DigitalPageError.renderingFailed }
                let context = bitmap.context
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                // Line boxes (blue: drawn lines, red: fixed lines), then the text on top.
                for (lines, color) in [(shown, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.35)), (fixed, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))] {
                    context.setStrokeColor(color)
                    context.setLineWidth(0.6)
                    for line in lines {
                        let l = line.rect.toBottomLeft(spaceWidth: size.width, spaceHeight: size.height)
                        context.stroke(CGRect(x: l.x, y: l.y, width: l.width, height: l.height))
                    }
                }
                DigitalPageText.draw(runs, in: context, visible: true, pageWidth: size.width, obstacles: withObstacles ? obstacles : [])
                let image = try #require(context.makeImage())
                let data = try #require(PageRenderer.pngData(from: image))
                try data.write(to: directory.appendingPathComponent("\(name)\(withObstacles ? "" : "-ohne-hindernis").png"))
            }
        }
    }

    /// Real pages from lines in a benchmark JSON (`DIGITAL_PAGE_REAL_PDF`, `DIGITAL_PAGE_REAL_JSON`,
    /// `DIGITAL_PAGE_REAL_PAGES` like "2,3"): line level only (no words); both modes as PNGs.
    @Test("Echte Datei auf Zeilenebene als PNG ablegen", .enabled(if: ProcessInfo.processInfo.environment["DIGITAL_PAGE_REAL_PDF"] != nil))
    func dumpReal() throws {
        let environment = ProcessInfo.processInfo.environment
        let pdf = try Data(contentsOf: URL(fileURLWithPath: try #require(environment["DIGITAL_PAGE_REAL_PDF"])))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try #require(environment["DIGITAL_PAGE_REAL_JSON"])))) as? [String: Any]
        let pages = try #require(json?["pages"] as? [[String: Any]])
        let directory = URL(fileURLWithPath: environment["DIGITAL_PAGE_DUMP_DIR"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("digitalpage"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wanted = (environment["DIGITAL_PAGE_REAL_PAGES"] ?? "2,3").split(separator: ",").compactMap { Int($0) }
        let sources = DigitalPageSources()
        for number in wanted {
            guard let page = pages.first(where: { $0["page"] as? Int == number }), let raw = page["lines"] as? [[String: Any]] else { continue }
            var lines: [RecognizedLine] = []
            let paragraphs = (page["paragraphs"] as? [[String: Any]])?.compactMap { $0["lines"] as? Int } ?? []
            var ids: [UUID] = []
            for count in paragraphs { let id = UUID(); ids += Array(repeating: id, count: count) }
            for (index, item) in raw.enumerated() {
                guard let r = item["rect"] as? [Double], r.count == 4, let text = item["text"] as? String else { continue }
                let status: ConfidenceStatus = (item["status"] as? String) == "confident" ? .confident : .uncertain
                lines.append(RecognizedLine(
                    text: text, rect: NormalizedRect(x: r[0], y: r[1], width: r[2], height: r[3]), status: status, order: index,
                    paragraphID: index < ids.count ? ids[index] : nil))
            }
            let input = DigitalPageInput(background: .pdf(data: pdf, pageIndex: number - 1, variant: nil), lines: lines)
            for mode in [DigitalPageMode.handwriting, .textLayer] {
                let image = try DigitalPageBuilder.makeImage(input, mode: mode, scale: 2, sources: sources)
                try #require(PageRenderer.pngData(from: image)).write(to: directory.appendingPathComponent("echt-s\(number)-\(mode.rawValue).png"))
            }
        }
    }
}
