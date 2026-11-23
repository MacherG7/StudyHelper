import CoreGraphics
import Foundation
import StudyCore
import Vision

/// iOS/macOS 26+: structure-aware recognition with `RecognizeDocumentsRequest` (title, paragraphs,
/// list items, table cells).
///
/// Findings (Xcode 27.2 SDK, synthetic handwriting and printed text): the request returns word boxes
/// (`RecognizedText.boundingBox(for:)`), but its confidence scale is much lower than the classic request
/// (0.3 to 0.7 for text that is read correctly) and on handwriting it merged or dropped some short lines.
/// It is therefore used only to classify the lines of the classic request (`blockKind`), never as the
/// source of text, confidence or word boxes. Any failure returns nil and the classic result stands.
@available(iOS 26, macOS 26, *)
enum VisionDocumentRecognizer {
    static let engineVersion = "RecognizeDocumentsRequest rev 1"

    static func structure(of image: CGImage, options: TextRecognitionOptions) async -> [DocumentBlockLine]? {
        var request = RecognizeDocumentsRequest()
        var text = request.textRecognitionOptions
        text.useLanguageCorrection = options.usesLanguageCorrection
        text.customWords = options.customWords
        text.maximumCandidateCount = 1
        if !options.languages.isEmpty {
            text.recognitionLanguages = options.languages.map { Locale.Language(identifier: $0) }
        }
        request.textRecognitionOptions = text

        guard let observations = try? await request.perform(on: image) else { return nil }
        var blocks: [DocumentBlockLine] = []
        var seen: Set<UUID> = []
        for observation in observations {
            collect(observation.document, into: &blocks, seen: &seen)
        }
        return blocks.isEmpty ? nil : blocks
    }

    private static func collect(
        _ container: DocumentObservation.Container, into blocks: inout [DocumentBlockLine], seen: inout Set<UUID>
    ) {
        if let title = container.title { append(title.lines, kind: .title, to: &blocks, seen: &seen) }
        for list in container.lists {
            for item in list.items {
                append(item.content.text.lines, kind: .listItem, to: &blocks, seen: &seen)
            }
        }
        for table in container.tables {
            for row in table.rows {
                for cell in row { append(cell.content.text.lines, kind: .tableCell, to: &blocks, seen: &seen) }
            }
        }
        // Paragraphs last: lines already claimed by a list or table keep that more specific kind.
        for paragraph in container.paragraphs { append(paragraph.lines, kind: .paragraph, to: &blocks, seen: &seen) }
    }

    private static func append(
        _ observations: [RecognizedTextObservation], kind: LineBlockKind,
        to blocks: inout [DocumentBlockLine], seen: inout Set<UUID>
    ) {
        for observation in observations where seen.insert(observation.uuid).inserted {
            blocks.append(DocumentBlockLine(
                rect: .fromVision(observation.boundingBox.cgRect),
                kind: observation.isTitle ? .title : kind
            ))
        }
    }
}
