import CoreGraphics
import Foundation
import StudyCore

/// Options for one OCR run.
public struct TextRecognitionOptions: Hashable, Sendable {
    /// BCP-47 language codes, most important first.
    public var languages: [String]
    public var usesLanguageCorrection: Bool
    /// Confirmed subject terms passed to Vision (`customWords`).
    public var customWords: [String]
    /// Use RecognizeDocumentsRequest when available (iOS/macOS 26+) for tables, lists, paragraphs.
    public var prefersDocumentRecognition: Bool
    /// Number of alternative readings to keep per line.
    public var maximumCandidates: Int

    public init(
        languages: [String] = ["de-DE"], usesLanguageCorrection: Bool = true,
        customWords: [String] = [], prefersDocumentRecognition: Bool = true,
        maximumCandidates: Int = 3
    ) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
        self.prefersDocumentRecognition = prefersDocumentRecognition
        self.maximumCandidates = maximumCandidates
    }
}

/// Result of one OCR run on one image.
public struct TextRecognitionOutput: Hashable, Sendable {
    /// Lines with rects normalized to the recognized image (origin top-left).
    public var lines: [RecognizedLine]
    /// E.g. the Vision request revision.
    public var engineVersion: String
    public var method: RecognitionMethod

    public init(lines: [RecognizedLine], engineVersion: String, method: RecognitionMethod) {
        self.lines = lines
        self.engineVersion = engineVersion
        self.method = method
    }
}

/// Anything that turns an image into recognized lines. The Vision implementation
/// is the production one; tests inject a counting mock.
public protocol TextRecognizing: Sendable {
    func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionOutput
}
