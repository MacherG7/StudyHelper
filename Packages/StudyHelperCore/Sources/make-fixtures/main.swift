import Foundation
import TestFixtures

// Usage: swift run --package-path Packages/StudyHelperCore make-fixtures [outputDir]
// Default output: Sources/TestFixtures/Resources/Goodnotes inside the package.

let defaultDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // make-fixtures
    .deletingLastPathComponent()  // Sources
    .appendingPathComponent("TestFixtures/Resources/Goodnotes", isDirectory: true)
let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : defaultDirectory

// The committed fixtures must be made with the real handwriting font. With the fallback font the outlines (and
// therefore every committed file) would change silently, so refuse to write anything.
guard GoodnotesFixture.handwritingFontName == GoodnotesFixture.preferredHandwritingFontName else {
    FileHandle.standardError.write(Data("""
        make-fixtures: refusing to write fixtures. The handwriting font \(GoodnotesFixture.preferredHandwritingFontName)         is not available (CoreText resolved \(GoodnotesFixture.handwritingFontName) instead). Run this tool on a Mac         with Noteworthy installed so that the committed fixtures keep their glyph outlines. Nothing was written.

        """.utf8))
    exit(2)
}
print("Handwriting font: \(GoodnotesFixture.handwritingFontName), \(GoodnotesFixture.handwritingFontVersion)")

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    print("Writing synthetic Goodnotes fixtures to \(outputDirectory.path)")
    for (fixture, result) in try GoodnotesFixture.allCases.map({ ($0, try $0.generate()) }) {
        try result.pdfData.write(to: outputDirectory.appendingPathComponent(fixture.fileName))
        try result.truthData.write(to: outputDirectory.appendingPathComponent(fixture.truthFileName))

        let truth = result.truth
        var counts: [String: Int] = [:]
        for item in truth.pages.flatMap(\.items) where item.annotationCount > 0 {
            counts[item.annotationSubtype ?? "?", default: 0] += item.annotationCount
        }
        let annotations = truth.variant == "editable"
            ? "annotations Ink=\(counts["Ink", default: 0]) FreeText=\(counts["FreeText", default: 0]) Stamp=\(counts["Stamp", default: 0])"
            : "no annotations, \(truth.items(ofKind: .ocrWord).count) text-layer words, \(truth.ocrErrors.count) deliberate errors"
        print("\(fixture.fileName): \(truth.variant), \(truth.pageCount) page(s), \(annotations), \(result.pdfData.count / 1024) KB")
    }
} catch {
    FileHandle.standardError.write(Data("make-fixtures failed: \(error)\n".utf8))
    exit(1)
}
