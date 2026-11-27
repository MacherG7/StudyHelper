#if canImport(AppKit)
// On-device Apple model for word-review-bench: the reordering the app uses (`WordSuggestions.rerank`).
import Foundation
import StudyAI
import StudyCore

enum AppleModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleFoundationProvider.availabilityStatus.isAvailable }
        #endif
        return false
    }

    /// The rerank closure of `WordRereadRequest`, as the app builds it, plus the seconds of the last answer.
    static func rerank(subject: String, timing: RerankTiming)
        -> @Sendable (_ candidates: [String], _ before: String, _ after: String) async -> [String]
    {
        { candidates, before, after in
            let start = Date()
            defer { timing.record(Date().timeIntervalSince(start)) }
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleFoundationProvider(configuration: ProviderConfiguration(
                    name: "bench", kind: .appleFoundation, model: "apple-foundation"))
                return (try? await WordSuggestions.rerank(
                    candidates: candidates, before: before, after: after, subject: subject, provider: provider)) ?? []
            }
            #endif
            return []
        }
    }
}

/// Seconds of the model answers (the provider stops waiting after its timeout; the answer may come later).
final class RerankTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ seconds: Double) { lock.withLock { values.append(seconds) } }

    /// Takes the recorded values.
    func drain() -> [Double] { lock.withLock { defer { values = [] }; return values } }
}

#else
#endif
