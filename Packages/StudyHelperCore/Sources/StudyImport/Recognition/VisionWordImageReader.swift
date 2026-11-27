import CoreGraphics
import Foundation
import StudyCore
import Vision

// Kept apart from WordReread.swift: Vision also exports a type called `NormalizedRect`.

/// Vision, accurate, German, newest revision, up to 10 candidates per observation. Runs on the dedicated queue of
/// the word re-reading; cancelling the calling task cancels the Vision request.
struct VisionWordImageReader: WordImageReading {
    static let maximumCandidates = 10

    func read(_ image: CGImage, languageCorrection: Bool, customWords: [String]) async throws -> TextReading {
        let handle = RequestHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                WordRereadQueue.queue.async {
                    let request = VNRecognizeTextRequest()
                    request.revision = VisionTextRecognizer.latestRevision
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = languageCorrection
                    request.recognitionLanguages = ["de-DE"]
                    request.customWords = languageCorrection ? customWords : []
                    guard handle.start(request) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        let observations = (request.results ?? []).map { observation in
                            TextReading.Observation(
                                minX: Double(observation.boundingBox.minX), width: Double(observation.boundingBox.width),
                                candidates: observation.topCandidates(Self.maximumCandidates).map(\.string))
                        }
                        let cancelled = handle.finish()
                        if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: TextReading(observations: observations))
                        }
                    } catch {
                        let cancelled = handle.finish()
                        continuation.resume(throwing: cancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// The running request, so that cancelling the task cancels Vision.
    private final class RequestHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var request: VNRequest?
        private var isCancelled = false

        /// False if the task was cancelled before the request started.
        func start(_ request: VNRequest) -> Bool {
            lock.withLock {
                guard !isCancelled else { return false }
                self.request = request
                return true
            }
        }

        /// Ends the request; returns whether it was cancelled.
        func finish() -> Bool {
            lock.withLock {
                request = nil
                return isCancelled
            }
        }

        func cancel() {
            let running = lock.withLock { () -> VNRequest? in
                isCancelled = true
                return request
            }
            running?.cancel()
        }
    }
}
