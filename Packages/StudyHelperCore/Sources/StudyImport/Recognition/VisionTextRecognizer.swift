import CoreGraphics
import Foundation
import StudyCore
import Vision

/// Production `TextRecognizing`: Apple Vision, accurate mode (SPEC §2, step 1).
///
/// - `VNRecognizeTextRequest` with `.accurate`, languages and language correction from the options,
///   `customWords`, and the newest supported revision (recorded as `engineVersion`).
/// - With `prefersDocumentRecognition` on iOS/macOS 26+ the structure-aware `RecognizeDocumentsRequest`
///   additionally classifies the lines (`blockKind`: title, paragraph, list item, table cell); text,
///   confidence and word boxes always come from the classic request. Failures there are silent.
/// - Per-word boxes come from `VNRecognizedText.boundingBox(for:)` over the `WordTokenizer` token ranges.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    /// The newest `VNRecognizeTextRequest` revision this OS supports.
    public static var latestRevision: Int {
        VNRecognizeTextRequest.supportedRevisions.max() ?? VNRecognizeTextRequestRevision3
    }

    /// "VNRecognizeTextRequest rev 3"
    public static var engineVersion: String {
        "VNRecognizeTextRequest rev \(latestRevision)"
    }

    /// Builds the configured request. Exposed (internal) so tests can check what is passed to Vision.
    static func makeRequest(options: TextRecognitionOptions) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = latestRevision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if !options.languages.isEmpty { request.recognitionLanguages = options.languages }
        request.customWords = options.customWords
        return request
    }

    public func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> TextRecognitionOutput {
        let classic = try await Self.recognizeClassic(image, options: options)
        var output = TextRecognitionOutput(lines: classic, engineVersion: Self.engineVersion, method: .vision)
        if options.prefersDocumentRecognition, !classic.isEmpty, #available(iOS 26, macOS 26, *) {
            // Structure (title, list item, table cell) from RecognizeDocumentsRequest; failures are silent.
            if let blocks = await VisionDocumentRecognizer.structure(of: image, options: options) {
                let classified = DocumentStructure.classify(classic, with: blocks)
                if classified.contains(where: { $0.blockKind != nil }) {
                    output = TextRecognitionOutput(
                        lines: classified,
                        engineVersion: "\(Self.engineVersion) + \(VisionDocumentRecognizer.engineVersion)",
                        method: .visionDocument
                    )
                }
            }
        }
        return output
    }

    // MARK: Classic path

    static func recognizeClassic(_ image: CGImage, options: TextRecognitionOptions) async throws -> [RecognizedLine] {
        // VNImageRequestHandler.perform is synchronous and can take seconds: keep it off the cooperative pool.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = makeRequest(options: options)
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let observations = request.results ?? []
                    continuation.resume(returning: convert(observations, maximumCandidates: options.maximumCandidates))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func convert(_ observations: [VNRecognizedTextObservation], maximumCandidates: Int) -> [RecognizedLine] {
        var lines: [RecognizedLine] = []
        for observation in observations {
            let candidates = observation.topCandidates(max(1, maximumCandidates))
            guard let best = candidates.first, !best.string.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            lines.append(VisionLineBuilder.makeLine(
                text: best.string, confidence: Double(best.confidence),
                alternatives: candidates.dropFirst().map(\.string),
                lineRect: .fromVision(observation.boundingBox), blockKind: nil,
                wordRect: { range in
                    (try? best.boundingBox(for: range)).map { .fromVision($0.boundingBox) }
                }
            ))
        }
        return VisionLineBuilder.sortAndNumber(lines)
    }
}
