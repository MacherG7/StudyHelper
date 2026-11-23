import Foundation

/// Settings of one digitization run (SPEC §2). Contains no secrets; the app keeps the user-facing
/// ones (e.g. `multiPass`) in `UserDefaults`.
public struct PipelineSettings: Hashable, Sendable {
    /// Recognize twice (second pass on a rescaled rendering); words that differ between the passes are
    /// marked uncertain. Costs time, therefore off by default.
    public var multiPass: Bool
    /// Confirmed subject terms of the subject, passed to Vision as `customWords`.
    public var customWords: [String]
    /// Pixels per point of the stored page image (JPEG with annotations). 2 is enough for display and review.
    public var renderScale: Double
    /// Pixels per point of the images that are recognized: Goodnotes ink layers and PDF pages without embedded text.
    public var recognitionScale: Double
    /// Scale of the second pass relative to the first (multi-pass only).
    public var secondPassScale: Double
    /// BCP-47 language codes for Vision, most important first.
    public var languages: [String]
    public var usesLanguageCorrection: Bool
    /// Use `RecognizeDocumentsRequest` (iOS/macOS 26+) to classify lines of photos, scans and printed pages.
    /// Never used for Goodnotes ink layers: handwriting strokes carry no table or list structure.
    public var prefersDocumentRecognition: Bool
    /// Alternative readings kept per line.
    public var maximumCandidates: Int
    /// JPEG quality of the stored page image.
    public var imageQuality: Double

    public init(
        multiPass: Bool = false, customWords: [String] = [], renderScale: Double = 2,
        recognitionScale: Double = 3, secondPassScale: Double = 0.7, languages: [String] = ["de-DE"],
        usesLanguageCorrection: Bool = true, prefersDocumentRecognition: Bool = true,
        maximumCandidates: Int = 3, imageQuality: Double = 0.85
    ) {
        self.multiPass = multiPass
        self.customWords = customWords
        self.renderScale = renderScale
        self.recognitionScale = recognitionScale
        self.secondPassScale = secondPassScale
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.prefersDocumentRecognition = prefersDocumentRecognition
        self.maximumCandidates = maximumCandidates
        self.imageQuality = imageQuality
    }

    func recognitionOptions(prefersDocumentRecognition: Bool) -> TextRecognitionOptions {
        TextRecognitionOptions(
            languages: languages, usesLanguageCorrection: usesLanguageCorrection, customWords: customWords,
            prefersDocumentRecognition: prefersDocumentRecognition, maximumCandidates: maximumCandidates)
    }
}
