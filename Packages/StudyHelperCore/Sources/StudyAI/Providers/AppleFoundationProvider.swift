#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// On-device Apple Foundation Model (iOS 26+, Apple Intelligence). No key, no cost.
///
/// Not in this step: images (iOS 27 `Attachment` API), tools and Guided Generation.
/// TODO Phase 4: Tool protocol and `respond(to:generating:)` for structured output; then switch the capabilities on.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleFoundationProvider: ModelProvider {
    public let kind: ProviderKind = .appleFoundation
    public let capabilities: ProviderCapabilities

    private let configuration: ProviderConfiguration
    private let now: @Sendable () -> Date

    public init(configuration: ProviderConfiguration, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.capabilities = ProviderCapabilities(
            supportsImages: false, supportsTools: false, supportsStreaming: true, supportsStructuredOutput: false,
            reasoningLevels: [], contextSize: SystemLanguageModel.default.contextSize)
        self.now = now
    }

    /// `SystemLanguageModel.default.availability` as the plain enum.
    public static var availabilityStatus: AppleModelAvailability {
        map(SystemLanguageModel.default.availability)
    }

    static func map(_ availability: SystemLanguageModel.Availability) -> AppleModelAvailability {
        switch availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let (configuration, now, capabilities) = (configuration, now, capabilities)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try RequestGuard.checkDocuments(request, allowed: false)
                    try RequestGuard.checkImages(request, allowed: capabilities.supportsImages)
                    let status = Self.availabilityStatus
                    guard status.isAvailable else { throw ProviderError.unavailable(status.germanDescription) }
                    let start = now()
                    let instructions = request.system.combined
                    let prompt = AppleFoundationText.prompt(from: request.messages)
                    guard !prompt.isEmpty else { throw ProviderError.badRequest("Die Anfrage enthält keinen Text.") }
                    let session = instructions.isEmpty
                        ? LanguageModelSession(model: .default)
                        : LanguageModelSession(model: .default, instructions: instructions)
                    var delivered = ""
                    var firstToken: Date?
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        let full = snapshot.content
                        let delta = AppleFoundationText.newSuffix(previous: delivered, current: full)
                        guard !delta.isEmpty else { continue }
                        if firstToken == nil { firstToken = now() }
                        delivered += delta
                        continuation.yield(.textDelta(delta))
                    }
                    let end = now()
                    var usage = TokenUsage()
                    var contextUsed: Int?
                    if #available(iOS 26.4, macOS 26.4, *) {
                        let model = SystemLanguageModel.default
                        let input = try? await model.tokenCount(for: instructions.isEmpty ? prompt : instructions + "\n\n" + prompt)
                        let output = try? await model.tokenCount(for: delivered)
                        usage = TokenUsage(inputTokens: input, outputTokens: output)
                        if let input, let output { contextUsed = input + output }
                    }
                    let metadata = ResponseMetadata(
                        task: request.task, providerKind: .appleFoundation, providerName: configuration.name,
                        model: configuration.model, reasoning: nil, usage: usage, date: start,
                        duration: end.timeIntervalSince(start), timeToFirstToken: firstToken.map { $0.timeIntervalSince(start) },
                        sentContent: request.sentContent, toolCalls: [],
                        learningUnitIDsInContext: request.learningUnitIDsInContext,
                        rawRequest: "System: \(instructions)\n\nPrompt: \(prompt)", rawResponse: delivered,
                        stopReason: .endTurn, contextTokensUsed: contextUsed, contextSize: capabilities.contextSize)
                    continuation.yield(.finished(ModelResponse(text: delivered, metadata: metadata)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: ProviderError.invalidResponse(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> ProviderError {
        switch error {
        case .guardrailViolation: return .refused(category: "guardrails")
        case .refusal: return .refused(category: nil)
        case .exceededContextWindowSize: return .badRequest("Der Text ist für das Apple-Modell zu lang.")
        case .unsupportedLanguageOrLocale: return .badRequest("Das Apple-Modell unterstützt diese Sprache nicht.")
        default: return .invalidResponse(error.localizedDescription)
        }
    }
}
#endif
