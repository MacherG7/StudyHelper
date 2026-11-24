import Foundation
import Testing

@testable import StudyAI

/// Shared helpers of the provider tests. Everything runs on `StubTransport`; no test touches a network.
enum TestSupport {
    static let secretKey = "sk-test-SECRET-1234567890"

    /// Retries without waiting.
    static let fastRetry = RetryPolicy(maxRetries: 2, baseDelay: 0, maxDelay: 0, sleep: { _ in }, jitter: { 0 })

    /// A clock that advances one second per call.
    final class TickClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 0.0
        func next() -> Date { lock.withLock { seconds += 1; return Date(timeIntervalSince1970: 1_000 + seconds) } }
    }

    static func configuration(
        _ kind: ProviderKind, model: String = "test-model", baseURL: String? = nil,
        capabilities: ProviderCapabilities? = nil, reasoning: ReasoningLevel? = nil, imageOverride: Bool? = nil
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            name: "Test", kind: kind, baseURL: baseURL, model: model, reasoning: reasoning,
            imageSupportOverride: imageOverride, cachedCapabilities: capabilities)
    }

    static func keyStore(for configuration: ProviderConfiguration, key: String? = secretKey) -> InMemoryKeyStore {
        InMemoryKeyStore(keys: key.map { [configuration.id: $0] } ?? [:])
    }

    static func request(
        _ messages: [ChatMessage] = [.user("Frage")], system: PromptParts = PromptParts(fixed: "Regel", editable: "Stil"),
        tools: [ToolDefinition] = [], schema: ResponseSchema? = nil, reasoning: ReasoningLevel? = nil,
        maxOutputTokens: Int? = nil
    ) -> ModelRequest {
        ModelRequest(
            task: .chat, system: system, messages: messages, tools: tools, responseSchema: schema,
            reasoning: reasoning, maxOutputTokens: maxOutputTokens, learningUnitIDsInContext: ["lu-1"])
    }

    static let searchTool = ToolDefinition(
        name: "search", description: "Sucht im Lernstoff",
        parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]])

    static let answerSchema = ResponseSchema(
        name: "answer v1", schema: ["type": "object", "properties": ["text": ["type": "string"]]], description: "Antwort")

    static func body(of request: URLRequest) throws -> JSONValue {
        let data = try #require(request.httpBody)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// SSE lines: `event:` (optional), `data:` and the blank separator.
    static func sse(_ events: [(String?, String)]) -> [String] {
        events.flatMap { event, data -> [String] in
            (event.map { ["event: \($0)"] } ?? []) + ["data: \(data)", ""]
        }
    }

    static func collect(
        _ provider: any ModelProvider, _ request: ModelRequest
    ) async throws -> (events: [ModelEvent], response: ModelResponse) {
        var events: [ModelEvent] = []
        var finished: ModelResponse?
        for try await event in provider.stream(request) {
            events.append(event)
            if case .finished(let response) = event { finished = response }
        }
        return (events, try #require(finished))
    }

    static func thrownError(_ provider: any ModelProvider, _ request: ModelRequest) async -> ProviderError? {
        do {
            _ = try await collect(provider, request)
            return nil
        } catch {
            return error as? ProviderError
        }
    }

    static func textDeltas(_ events: [ModelEvent]) -> [String] {
        events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }
    }

    static func header(_ request: URLRequest, _ name: String) -> String? { request.value(forHTTPHeaderField: name) }

    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE])
}
