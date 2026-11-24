import Foundation
import StudyCore
import StudyData
import UIKit

/// Demo data for UI tests (`-uiTestInMemory -uiTestSeed`): one subject with one
/// digitized page, so review and topic screens can be tested without pickers,
/// camera or Vision. With `-uiTestSeedVersions` the page has a second version
/// (as after a re-recognition) whose first line differs: `revisedFirstLine`. With `-uiTestSeedTopics`
/// the subject also has the unconfirmed topic `topicTitle` whose one entry (origin "Original") points at
/// line 2 of the page (`topicEntryText`) and which has the page assigned.
@MainActor
enum UITestSeeder {
    static let subjectName = "Biologie"
    static let lineTexts = [
        "Fotosynthese",
        "Ort: Chloroplasten",
        "Chlorophyl ist der grune Blattfarbstoff",
    ]

    static let revisedFirstLine = "Fotosynthese (überarbeitet)"

    static let topicTitle = "Fotosynthese"
    static let topicEntryText = "Ort: Chloroplasten"

    static func seed(_ repository: StudyRepository, withVersions: Bool = false, withTopics: Bool = false) throws {
        let subject = try repository.createSubject(name: subjectName)
        _ = try repository.createSubject(name: "Deutsch")

        let pageSize = PageSize(width: 600, height: 800)
        let rects = [
            NormalizedRect(x: 0.1, y: 0.08, width: 0.45, height: 0.06),
            NormalizedRect(x: 0.1, y: 0.2, width: 0.55, height: 0.05),
            NormalizedRect(x: 0.1, y: 0.3, width: 0.8, height: 0.05),
        ]
        let image = renderPage(size: pageSize, rects: rects)
        let batch = try repository.createBatch(
            in: subject, kind: .photo, originalFileName: "Fotosynthese.jpg",
            pages: [SourceInput(imageData: image, pageSize: pageSize)]
        )
        guard let source = batch.sortedSources.first else { return }

        var lines: [RecognizedLine] = []
        for (index, text) in lineTexts.enumerated() {
            let rect = rects[index]
            let parts = text.split(separator: " ").map(String.init)
            let wordWidth = rect.width / Double(max(parts.count, 1))
            let uncertain = index == 2
            let words = parts.enumerated().map { i, part in
                RecognizedWord(
                    text: part,
                    rect: NormalizedRect(x: rect.x + Double(i) * wordWidth, y: rect.y, width: wordWidth * 0.9, height: rect.height),
                    confidence: uncertain && (part == "Chlorophyl" || part == "grune") ? 0.4 : 0.95,
                    color: index == 2 ? RGBColor(hex: "#D32F2F") : .black,
                    status: uncertain && (part == "Chlorophyl" || part == "grune") ? .uncertain : .confident,
                    reviewReasons: uncertain && (part == "Chlorophyl" || part == "grune") ? [.lowConfidence] : []
                )
            }
            lines.append(RecognizedLine(
                text: text, rect: rect, confidence: uncertain ? 0.4 : 0.95,
                candidates: uncertain ? ["Chlorophyll ist der grüne Blattfarbstoff"] : [],
                words: words, status: uncertain ? .uncertain : .confident,
                reviewReasons: uncertain ? [.lowConfidence] : [], order: index
            ))
        }
        let highlights = [
            RecognizedHighlight(
                text: "Fotosynthese", kind: .underline, rect: rects[0], suggestedMeaning: .heading,
                source: .goodnotesShape, words: [WordReference(lineID: lines[0].id, wordIndex: 0)]
            ),
            RecognizedHighlight(
                text: "Chloroplasten", kind: .highlighter, color: RGBColor(hex: "#FFEB3B"), rect: rects[1],
                suggestedMeaning: .important, source: .goodnotesAnnotation,
                words: [WordReference(lineID: lines[1].id, wordIndex: 1)]
            ),
        ]
        func result(lines: [RecognizedLine], engine: String) -> DigitizationResult {
            DigitizationResult(
                lines: lines, highlights: highlights,
                metadata: RecognitionMetadata(method: .vision, engineVersion: engine, osVersion: "Test", deviceModel: "Simulator"),
                originalMarkdown: OriginalTextMarkdown.build(lines: lines, highlights: highlights),
                pageSize: pageSize
            )
        }
        _ = try repository.saveDigitization(result(lines: lines, engine: "UI-Test"), for: source)

        if withVersions {
            // A second recognition of the same page: same lines except the first one (the "re-recognition" result).
            try repository.prepareReRecognition(for: [source])
            var revised = lines
            revised[0].text = revisedFirstLine
            _ = try repository.saveDigitization(result(lines: revised, engine: "UI-Test 2"), for: source)
        }

        if withTopics, let digitization = source.currentDigitization,
           let line = digitization.lines.first(where: { $0.order == 1 }) {
            let topic = try repository.createTopic(in: subject, title: topicTitle)
            try repository.assign(source, to: topic)
            try repository.addEntry(
                to: topic, kind: .keyStatement, text: topicEntryText, origin: .original,
                sourceReferences: [SourceReference(
                    sourceID: source.id, lineIDs: [line.id], rect: line.rect,
                    digitizationID: digitization.id, digitizationVersion: digitization.versionNumber
                ).withSnapshot(SourceFingerprint.make(lines: [line], highlights: digitization.highlights))],
                highlight: EntryHighlight(kind: .highlighter, color: RGBColor(hex: "#FFEB3B")))
        }
    }

    /// A simple page image with the line texts at their rects.
    private static func renderPage(size: PageSize, rects: [NormalizedRect]) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            for (index, text) in lineTexts.enumerated() {
                let rect = rects[index]
                let frame = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont(name: "Noteworthy-Light", size: 24) ?? UIFont.systemFont(ofSize: 24),
                    .foregroundColor: index == 2 ? UIColor.systemRed : UIColor.black,
                ]
                (text as NSString).draw(in: frame, withAttributes: attributes)
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}
