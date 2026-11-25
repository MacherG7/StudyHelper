import Foundation

/// Claude via the Messages API (`POST /v1/messages`, always streaming). API shapes: docs/API-REFERENZ.md.
public struct ClaudeProvider: ModelProvider, ModelCatalog {
    public static let defaultBaseURL = "https://api.anthropic.com"
    public static let apiVersion = "2026-10-21"
    /// `max_tokens` when the request names none (streaming allows large outputs).
    public static let defaultMaxTokens = 32_000

    public let kind: ProviderKind = .claude
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

    /// What goes into the request for a reasoning level, and the level that is really sent.
    struct ReasoningPlan: Equatable {
        var thinking: JSONValue?
        var effort: String?
        var sent: ReasoningLevel?
    }

    /// Mapping of `ReasoningLevel` to `thinking` + `output_config.effort`, limited to what the model supports:
    /// - nil: send nothing (model default).
    /// - off: `{type: "disabled"}` if the model can be switched off, `{type: "between_tools"}` for models that only
    ///   allow that; if `.off` is not offered at all, thinking is omitted and the lowest supported effort is used.
    /// - minimal maps to low; other levels use adaptive thinking with that effort; a level the model does not
    ///   support falls back to the next lower supported one (or the lowest).
    /// - Unknown capabilities (no levels): nothing is sent.
    static func reasoningPlan(for level: ReasoningLevel?, capabilities: ProviderCapabilities) -> ReasoningPlan {
        guard let level else { return ReasoningPlan() }
        let effortLevels = capabilities.reasoningLevels.filter { $0 != .off }
        if level == .off {
            if capabilities.reasoningLevels.contains(.off) {
                let type = capabilities.reasoningOffMode == .betweenTools ? "between_tools" : "disabled"
                return ReasoningPlan(thinking: ["type": .string(type)], effort: nil, sent: .off)
            }
            guard let lowest = effortLevels.min() else { return ReasoningPlan() }
            return ReasoningPlan(thinking: nil, effort: effortName(lowest), sent: lowest)
        }
        guard let chosen = ReasoningResolution.clamp(level == .minimal ? .low : level, to: effortLevels) else {
            return ReasoningPlan()
        }
        return ReasoningPlan(
            thinking: ["type": "adaptive", "display": "summarized"], effort: effortName(chosen), sent: chosen)
    }

    private static func effortName(_ level: ReasoningLevel) -> String {
        level == .minimal ? "low" : level.rawValue
    }

    // MARK: Request

    static func body(
        for request: ModelRequest, model: String, plan: ReasoningPlan, capabilities: ProviderCapabilities,
        redactImages: Bool
    ) -> JSONValue {
        var maxTokens = request.maxOutputTokens ?? defaultMaxTokens
        if let limit = capabilities.maxOutputTokens, limit > 0 { maxTokens = min(maxTokens, limit) }
        var body: [String: JSONValue] = [
            "model": .string(model), "max_tokens": .number(Double(maxTokens)), "stream": true,
            "messages": .array(messages(request.messages, redactImages: redactImages)),
        ]
        let system = request.system.combined
        if !system.isEmpty { body["system"] = .string(system) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters]
            })
            // Forced tool choice (any/tool) is rejected by current models: only auto.
            body["tool_choice"] = ["type": "auto"]
        }
        if let thinking = plan.thinking { body["thinking"] = thinking }
        var outputConfig: [String: JSONValue] = [:]
        if let effort = plan.effort { outputConfig["effort"] = .string(effort) }
        if let schema = request.responseSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema.schema]
        }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }
        // No temperature/top_p/top_k (400 since 2026-10-21) and no assistant prefill.
        return .object(body)
    }

    static func messages(_ messages: [ChatMessage], redactImages: Bool) -> [JSONValue] {
        messages.compactMap { message in
            let blocks: [JSONValue] = message.content.compactMap { part in
                switch part {
                case .text(let text):
                    guard !text.isEmpty else { return nil }
                    return ["type": "text", "text": .string(text)]
                case .image(let image):
                    let data = redactImages
                        ? ProviderJSON.placeholder(forImageBytes: image.data.count)
                        : image.data.base64EncodedString()
                    return [
                        "type": "image",
                        "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(data)],
                    ]
                case .toolCall(let call):
                    return [
                        "type": "tool_use", "id": .string(call.id), "name": .string(call.name),
                        "input": ProviderJSON.argumentsObject(call.arguments),
                    ]
                case .toolResult(let result):
                    var block: [String: JSONValue] = [
                        "type": "tool_result", "tool_use_id": .string(result.callID), "content": .string(result.content),
                    ]
                    if result.isError { block["is_error"] = true }
                    return .object(block)
                case .reasoning(let block):
                    // Thinking blocks (with signature) go back unchanged; other providers' blocks are dropped.
                    guard block.provider == .claude else { return nil }
                    return block.payload
                }
            }
            guard !blocks.isEmpty else { return nil }
            return ["role": .string(message.role.rawValue), "content": .array(blocks)]
        }
    }

    private func headers(key: String) -> [String: String] {
        ["x-api-key": key, "anthropic-version": Self.apiVersion, "content-type": "application/json"]
    }

    private func readKey() throws -> String {
        guard let key = try keyStore.readKey(for: configuration.id), !key.isEmpty else {
            throw ProviderError.missingAPIKey
        }
        return key
    }

    private var base: String { configuration.baseURL ?? Self.defaultBaseURL }

    // MARK: ModelProvider

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let plan = Self.reasoningPlan(for: request.reasoning ?? configuration.reasoning, capabilities: capabilities)
        let (model, capabilities, base) = (configuration.model, capabilities, base)
        let runner = StreamRunner(
            transport: transport, retry: retry, now: now, kind: .claude, providerName: configuration.name,
            model: model, errorStyle: .anthropic)
        let keyProvider: @Sendable () throws -> String = { try self.readKey() }
        let headerBuilder: @Sendable (String) -> [String: String] = { self.headers(key: $0) }
        let imagesAllowed = ProviderFactory.imagesAllowed(by: configuration)
        return runner.run(for: request, reasoningSent: plan.sent, accumulator: ClaudeStreamState()) {
            try RequestGuard.checkImages(request, allowed: imagesAllowed)
            let key = try keyProvider()
            var urlRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/v1/messages"))
            urlRequest.httpMethod = "POST"
            for (name, value) in headerBuilder(key) { urlRequest.setValue(value, forHTTPHeaderField: name) }
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
            urlRequest.httpBody = ProviderJSON.encode(Self.body(
                for: request, model: model, plan: plan, capabilities: capabilities, redactImages: false))
            return PreparedRequest(
                urlRequest: urlRequest,
                logBody: ProviderJSON.encode(Self.body(
                    for: request, model: model, plan: plan, capabilities: capabilities, redactImages: true)))
        }
    }

    // MARK: ModelCatalog

    public func availableModels() async throws -> [ModelInfo] {
        let key = try readKey()
        var models: [ModelInfo] = []
        var afterID: String?
        for _ in 0..<20 {
            var path = "/v1/models?limit=100"
            if let afterID { path += "&after_id=\(afterID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? afterID)" }
            var urlRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: path))
            urlRequest.httpMethod = "GET"
            for (name, value) in headers(key: key) { urlRequest.setValue(value, forHTTPHeaderField: name) }
            let data = try await ProviderHTTP.send(urlRequest, transport: transport, retry: retry, style: .anthropic)
            guard let root = ProviderJSON.object(data) else {
                throw ProviderError.invalidResponse("Die Modellliste von Claude ist kein JSON.")
            }
            for entry in root["data"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                models.append(ModelInfo(
                    id: id, displayName: entry["display_name"] as? String, capabilities: Self.capabilities(from: entry)))
            }
            guard root["has_more"] as? Bool == true, let last = root["last_id"] as? String, last != afterID else { break }
            afterID = last
        }
        return models
    }

    /// Capabilities from one `/v1/models` entry.
    static func capabilities(from entry: [String: Any]) -> ProviderCapabilities {
        let capabilities = entry["capabilities"] as? [String: Any] ?? [:]
        func supported(_ object: Any?) -> Bool { (object as? [String: Any])?["supported"] as? Bool == true }
        let types = (capabilities["thinking"] as? [String: Any])?["types"] as? [String: Any] ?? [:]
        let effort = capabilities["effort"] as? [String: Any] ?? [:]
        var levels: [ReasoningLevel] = []
        var offMode: ReasoningOffMode?
        if supported(types["disabled"]) { offMode = .disabled }
        else if supported(types["between_tools"]) { offMode = .betweenTools }
        if offMode != nil { levels.append(.off) }
        if supported(types["adaptive"]) {
            for (name, level) in [("low", ReasoningLevel.low), ("medium", .medium), ("high", .high), ("xhigh", .xhigh),
                                  ("max", .max)] where supported(effort[name]) {
                levels.append(level)
            }
        }
        return ProviderCapabilities(
            supportsImages: supported(capabilities["image_input"]), supportsTools: true, supportsStreaming: true,
            supportsStructuredOutput: supported(capabilities["structured_outputs"]), reasoningLevels: levels,
            contextSize: ProviderJSON.int(entry["max_input_tokens"]), maxOutputTokens: ProviderJSON.int(entry["max_tokens"]),
            reasoningOffMode: offMode)
    }
}

// MARK: - Stream parsing

/// State of one Claude event stream (`message_start` ... `message_stop`).
struct ClaudeStreamState: StreamAccumulator {
    private struct ToolBlock { var id: String; var name: String; var json = "" }
    private struct ThinkingBlock { var thinking = ""; var signature = "" }

    private var toolBlocks: [Int: ToolBlock] = [:]
    private var thinkingBlocks: [Int: ThinkingBlock] = [:]
    private(set) var reasoningBlocks: [ReasoningBlock] = []
    private var inputUsage = TokenUsage()
    private var outputTokens: Int?
    private var thinkingTokens: Int?
    private var finished = false
    private(set) var stopReason: StopReason?

    var usage: TokenUsage {
        var usage = inputUsage
        usage.outputTokens = outputTokens
        usage.reasoningTokens = thinkingTokens
        return usage
    }

    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
        guard let root = ProviderJSON.object(event.data), let type = root["type"] as? String ?? event.event else {
            return []  // not JSON or unknown: ignore
        }
        switch type {
        case "message_start":
            if let message = root["message"] as? [String: Any] { readUsage(message["usage"] as? [String: Any]) }
        case "content_block_start":
            guard let index = ProviderJSON.int(root["index"]), let block = root["content_block"] as? [String: Any]
            else { return [] }
            switch block["type"] as? String {
            case "tool_use":
                toolBlocks[index] = ToolBlock(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "")
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { return [.textDelta(text)] }
            case "thinking":
                thinkingBlocks[index] = ThinkingBlock(
                    thinking: block["thinking"] as? String ?? "", signature: block["signature"] as? String ?? "")
            case "redacted_thinking":
                if let data = block["data"] as? String {
                    reasoningBlocks.append(ReasoningBlock(
                        provider: .claude, payload: ["type": "redacted_thinking", "data": .string(data)]))
                }
            default: break
            }
        case "content_block_delta":
            guard let index = ProviderJSON.int(root["index"]), let delta = root["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty { return [.textDelta(text)] }
            case "thinking_delta":
                if let text = delta["thinking"] as? String, !text.isEmpty {
                    thinkingBlocks[index, default: ThinkingBlock()].thinking += text
                    return [.reasoningDelta(text)]
                }
            case "signature_delta":
                if let signature = delta["signature"] as? String {
                    thinkingBlocks[index, default: ThinkingBlock()].signature += signature
                }
            case "input_json_delta":
                toolBlocks[index]?.json += delta["partial_json"] as? String ?? ""
            default: break  // unknown deltas
            }
        case "content_block_stop":
            guard let index = ProviderJSON.int(root["index"]) else { return [] }
            if let thinking = thinkingBlocks.removeValue(forKey: index) {
                // A thinking block without signature cannot be passed back (the API would reject it).
                if !thinking.signature.isEmpty {
                    reasoningBlocks.append(ReasoningBlock(
                        provider: .claude,
                        payload: ["type": "thinking", "thinking": .string(thinking.thinking),
                                  "signature": .string(thinking.signature)]))
                }
                return []
            }
            guard let block = toolBlocks.removeValue(forKey: index) else { return [] }
            let arguments = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
            return [.toolCall(ToolCall(id: block.id, name: block.name, arguments: arguments.isEmpty ? "{}" : block.json))]
        case "message_delta":
            if let delta = root["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                if reason == "refusal" {
                    let details = delta["stop_details"] as? [String: Any] ?? root["stop_details"] as? [String: Any]
                    throw ProviderError.refused(category: details?["category"] as? String)
                }
                stopReason = Self.stopReason(reason)
            }
            readUsage(root["usage"] as? [String: Any])
        case "message_stop":
            finished = true
        case "error":
            let error = root["error"] as? [String: Any] ?? [:]
            throw ProviderHTTP.streamError(
                type: error["type"] as? String, code: nil, message: error["message"] as? String, style: .anthropic)
        default: break  // ping and unknown events
        }
        return []
    }

    mutating func end() throws -> [ModelEvent] {
        guard finished else { throw ProviderError.network("Die Verbindung wurde vor dem Ende der Antwort getrennt.") }
        return []
    }

    private mutating func readUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        if let value = ProviderJSON.int(usage["input_tokens"]) { inputUsage.inputTokens = value }
        if let value = ProviderJSON.int(usage["cache_creation_input_tokens"]) { inputUsage.cacheWriteTokens = value }
        if let value = ProviderJSON.int(usage["cache_read_input_tokens"]) { inputUsage.cacheReadTokens = value }
        if let value = ProviderJSON.int(usage["output_tokens"]) { outputTokens = value }
        if let details = usage["output_tokens_details"] as? [String: Any],
           let value = ProviderJSON.int(details["thinking_tokens"]) { thinkingTokens = value }
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "max_tokens": return .maxTokens
        case "tool_use": return .toolUse
        case "refusal": return .refusal
        default: return .other(raw)
        }
    }
}
