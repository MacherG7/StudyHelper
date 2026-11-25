import Foundation

/// Self-hosted OpenAI-compatible servers (Ollama, LM Studio, llama.cpp, vLLM) via `POST {base}/v1/chat/completions`.
/// The key is optional (sent as Bearer token only if one is stored). Structured output (`responseSchema`) is not
/// sent: the servers differ too much, and `supportsStructuredOutput` stays false. LAN addresses over http are allowed.
public struct OpenAICompatibleProvider: ModelProvider, ModelCatalog {
    public let kind: ProviderKind = .openAICompatible
    public let capabilities: ProviderCapabilities

    private let configuration: ProviderConfiguration
    private let keyStore: KeyStore
    private let transport: HTTPTransport
    private let retry: RetryPolicy
    private let now: @Sendable () -> Date

    public init(
        configuration: ProviderConfiguration, keyStore: KeyStore, transport: HTTPTransport,
        retry: RetryPolicy = RetryPolicy(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.capabilities = ProviderFactory.capabilities(of: configuration)
        self.keyStore = keyStore
        self.transport = transport
        self.retry = retry
        self.now = now
    }

    // MARK: Reasoning

    struct ReasoningPlan: Equatable {
        var effort: String?
        var sent: ReasoningLevel?
    }

    /// `reasoning_effort` for a level, only if the model has reasoning levels (Ollama: `thinking` capability).
    /// off -> "none" (ASSUMPTION: Ollama accepts "none" to switch thinking off; not stated in docs/API-REFERENZ.md,
    /// verify on a device); minimal -> low; xhigh/max -> high (the levels offered are off/low/medium/high).
    static func reasoningPlan(for level: ReasoningLevel?, capabilities: ProviderCapabilities) -> ReasoningPlan {
        guard let level, !capabilities.reasoningLevels.isEmpty else { return ReasoningPlan() }
        if level == .off {
            return capabilities.reasoningLevels.contains(.off) ? ReasoningPlan(effort: "none", sent: .off) : ReasoningPlan()
        }
        guard let chosen = ReasoningResolution.clamp(level == .minimal ? .low : level, to: capabilities.reasoningLevels)
        else { return ReasoningPlan() }
        return ReasoningPlan(effort: chosen.rawValue, sent: chosen)
    }

    // MARK: Request

    static func body(for request: ModelRequest, model: String, plan: ReasoningPlan, redactImages: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model), "stream": true, "stream_options": ["include_usage": true],
            "messages": .array(messages(request, redactImages: redactImages)),
        ]
        if let maxTokens = request.maxOutputTokens { body["max_tokens"] = .number(Double(maxTokens)) }
        if let effort = plan.effort { body["reasoning_effort"] = .string(effort) }
        if !request.tools.isEmpty {
            // No tool_choice: Ollama does not support it.
            body["tools"] = .array(request.tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters,
                    ],
                ]
            })
        }
        return .object(body)
    }

    static func messages(_ request: ModelRequest, redactImages: Bool) -> [JSONValue] {
        var result: [JSONValue] = []
        let system = request.system.combined
        if !system.isEmpty { result.append(["role": "system", "content": .string(system)]) }
        for message in request.messages {
            var parts: [JSONValue] = []
            var texts: [String] = []
            var calls: [JSONValue] = []
            var hasImage = false
            var results: [JSONValue] = []
            for part in message.content {
                switch part {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    texts.append(text)
                    parts.append(["type": "text", "text": .string(text)])
                case .image(let image):
                    hasImage = true
                    let url = redactImages
                        ? ProviderJSON.placeholder(forImageBytes: image.data.count)
                        : "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"
                    parts.append(["type": "image_url", "image_url": ["url": .string(url)]])
                case .document:
                    continue  // rejected before sending: Chat Completions has no PDF input
                case .toolCall(let call):
                    calls.append([
                        "id": .string(call.id), "type": "function",
                        "function": ["name": .string(call.name), "arguments": .string(call.arguments)],
                    ])
                case .reasoning:
                    continue  // provider-specific reasoning data is not sent to this API
                case .toolResult(let toolResult):
                    results.append(["role": "tool", "tool_call_id": .string(toolResult.callID),
                                    "content": .string(toolResult.content)])
                }
            }
            // Text-only turns use a plain string (widest compatibility); parts only when images are present.
            let content: JSONValue = hasImage ? .array(parts) : .string(texts.joined(separator: "\n\n"))
            switch message.role {
            case .user:
                if !parts.isEmpty { result.append(["role": "user", "content": content]) }
                result.append(contentsOf: results)
            case .assistant:
                if !texts.isEmpty || !calls.isEmpty {
                    var entry: [String: JSONValue] = ["role": "assistant", "content": .string(texts.joined(separator: "\n\n"))]
                    if !calls.isEmpty { entry["tool_calls"] = .array(calls) }
                    result.append(.object(entry))
                }
                result.append(contentsOf: results)
            }
        }
        return result
    }

    private func optionalKey() throws -> String? {
        guard let key = try keyStore.readKey(for: configuration.id), !key.isEmpty else { return nil }
        return key
    }

    private func applyHeaders(_ urlRequest: inout URLRequest, key: String?) {
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    private var base: String { configuration.baseURL ?? "" }

    // MARK: ModelProvider

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let plan = Self.reasoningPlan(for: request.reasoning ?? configuration.reasoning, capabilities: capabilities)
        let (model, base) = (configuration.model, base)
        let runner = StreamRunner(
            transport: transport, retry: retry, now: now, kind: .openAICompatible, providerName: configuration.name,
            model: model, errorStyle: .openAI)
        let keyProvider: @Sendable () throws -> String? = { try self.optionalKey() }
        let headerApplier: @Sendable (inout URLRequest, String?) -> Void = { self.applyHeaders(&$0, key: $1) }
        let imagesAllowed = ProviderFactory.imagesAllowed(by: configuration)
        return runner.run(for: request, reasoningSent: plan.sent, accumulator: ChatCompletionsStreamState()) {
            try RequestGuard.checkDocuments(request, allowed: false)
            try RequestGuard.checkImages(request, allowed: imagesAllowed)
            var urlRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/v1/chat/completions"))
            urlRequest.httpMethod = "POST"
            headerApplier(&urlRequest, try keyProvider())
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
            urlRequest.httpBody = ProviderJSON.encode(Self.body(for: request, model: model, plan: plan, redactImages: false))
            return PreparedRequest(
                urlRequest: urlRequest,
                logBody: ProviderJSON.encode(Self.body(for: request, model: model, plan: plan, redactImages: true)))
        }
    }

    // MARK: ModelCatalog

    /// Models of the server. If it is an Ollama server (`/api/tags` answers), each model's capabilities (vision,
    /// thinking, tools) come from `/api/show`; otherwise capabilities are unknown (images per user setting, no levels).
    public func availableModels() async throws -> [ModelInfo] {
        let key = try optionalKey()
        var listRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/v1/models"))
        listRequest.httpMethod = "GET"
        applyHeaders(&listRequest, key: key)
        let data = try await ProviderHTTP.send(listRequest, transport: transport, retry: retry, style: .openAI)
        guard let root = ProviderJSON.object(data) else {
            throw ProviderError.invalidResponse("Die Modellliste des Servers ist kein JSON.")
        }
        let ids = (root["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }

        var tagsRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/api/tags"))
        tagsRequest.httpMethod = "GET"
        applyHeaders(&tagsRequest, key: key)
        let isOllama = await ProviderHTTP.sendIfPossible(tagsRequest, transport: transport)
            .flatMap { ProviderJSON.object($0) }?["models"] is [Any]

        var models: [ModelInfo] = []
        for id in ids {
            guard isOllama else {
                models.append(ModelInfo(id: id, capabilities: ProviderCapabilities(supportsStreaming: true)))
                continue
            }
            var showRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/api/show"))
            showRequest.httpMethod = "POST"
            applyHeaders(&showRequest, key: key)
            showRequest.httpBody = ProviderJSON.encode(["model": .string(id)])
            let show = await ProviderHTTP.sendIfPossible(showRequest, transport: transport).flatMap { ProviderJSON.object($0) }
            guard let show else {
                models.append(ModelInfo(id: id, capabilities: ProviderCapabilities(supportsStreaming: true)))
                continue
            }
            if let capabilities = Self.ollamaCapabilities(from: show) {
                models.append(ModelInfo(id: id, capabilities: capabilities))
            }  // nil = no text generation (embedding model): left out
        }
        return models
    }

    /// Capabilities from an Ollama `/api/show` answer; nil for models that cannot generate text (embeddings only).
    static func ollamaCapabilities(from show: [String: Any]) -> ProviderCapabilities? {
        let names = Set((show["capabilities"] as? [String] ?? []).map { $0.lowercased() })
        if names.contains("embedding"), !names.contains("completion") { return nil }
        var levels: [ReasoningLevel] = []
        if names.contains("thinking") {
            // Documented: thinking on/off plus levels low/medium/high for models that offer them. A model that lists
            // its own `thinking.values` is limited to those.
            if let values = (show["thinking"] as? [String: Any])?["values"] as? [String] {
                levels = values.compactMap { ReasoningLevel(rawValue: $0.lowercased()) }
                if levels.isEmpty { levels = [.off, .low, .medium, .high] }
            } else {
                levels = [.off, .low, .medium, .high]
            }
        }
        return ProviderCapabilities(
            supportsImages: names.contains("vision"), supportsTools: names.contains("tools"), supportsStreaming: true,
            reasoningLevels: levels)
    }
}

// MARK: - Stream parsing

/// State of one Chat Completions chunk stream.
struct ChatCompletionsStreamState: StreamAccumulator {
    private struct PendingCall { var id: String?; var name = ""; var arguments = "" }

    private var calls: [Int: PendingCall] = [:]
    private var usageValue = TokenUsage()
    private var sawFinish = false
    private var done = false
    private(set) var stopReason: StopReason?

    var usage: TokenUsage { usageValue }

    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" {
            done = true
            return flushCalls()
        }
        guard let root = ProviderJSON.object(data) else { return [] }
        if let error = root["error"] as? [String: Any] {
            throw ProviderHTTP.streamError(
                type: error["type"] as? String, code: error["code"] as? String, message: error["message"] as? String,
                style: .openAI)
        } else if let error = root["error"] as? String {
            throw ProviderError.server(status: 500, message: error)
        }
        if let usage = root["usage"] as? [String: Any] { readUsage(usage) }
        var events: [ModelEvent] = []
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return [] }
        if let delta = choice["delta"] as? [String: Any] {
            if let reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let text = delta["content"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
            for entry in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = ProviderJSON.int(entry["index"]) ?? 0
                var call = calls[index] ?? PendingCall()
                if let id = entry["id"] as? String, !id.isEmpty { call.id = id }
                if let function = entry["function"] as? [String: Any] {
                    if let name = function["name"] as? String { call.name += name }
                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                }
                calls[index] = call
            }
        }
        if let reason = choice["finish_reason"] as? String {
            sawFinish = true
            stopReason = Self.stopReason(reason)
        }
        return events
    }

    mutating func end() throws -> [ModelEvent] {
        guard done || sawFinish else {
            throw ProviderError.network("Die Verbindung wurde vor dem Ende der Antwort getrennt.")
        }
        return flushCalls()
    }

    private mutating func flushCalls() -> [ModelEvent] {
        let events = calls.keys.sorted().map { index -> ModelEvent in
            let call = calls[index]!
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.arguments
            return .toolCall(ToolCall(id: call.id ?? "call_\(index)", name: call.name, arguments: arguments))
        }
        calls = [:]
        if !events.isEmpty, stopReason == nil || stopReason == .endTurn { stopReason = .toolUse }
        return events
    }

    private mutating func readUsage(_ usage: [String: Any]) {
        usageValue.inputTokens = ProviderJSON.int(usage["prompt_tokens"]) ?? usageValue.inputTokens
        usageValue.outputTokens = ProviderJSON.int(usage["completion_tokens"]) ?? usageValue.outputTokens
        if let cached = ProviderJSON.int((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]) {
            usageValue.cacheReadTokens = cached
        }
        if let reasoning = ProviderJSON.int((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]) {
            usageValue.reasoningTokens = reasoning
        }
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw {
        case "stop": return .endTurn
        case "length": return .maxTokens
        case "tool_calls", "function_call": return .toolUse
        case "content_filter": return .refusal
        default: return .other(raw)
        }
    }
}
