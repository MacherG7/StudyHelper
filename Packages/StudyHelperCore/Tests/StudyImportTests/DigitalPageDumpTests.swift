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
}
