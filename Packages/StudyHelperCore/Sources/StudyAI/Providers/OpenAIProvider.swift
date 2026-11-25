import Foundation

/// OpenAI via the Responses API (`POST /v1/responses`, always streaming). API shapes: docs/API-REFERENZ.md.
public struct OpenAIProvider: ModelProvider, ModelCatalog {
    public static let defaultBaseURL = "https://api.openai.com"
    public static let defaultMaxOutputTokens = 32_000

    public let kind: ProviderKind = .openAI
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
        var value: JSONValue?
        var sent: ReasoningLevel?
    }

    /// `reasoning` parameter for a level, limited to what the model supports:
    /// - nil or a model without levels: omitted (model default).
    /// - off: `{effort: "none"}` if the model accepts it; otherwise (like Claude) the lowest supported level, so
    ///   "off" never means more thinking than the model's minimum.
    /// - other levels: `{effort, summary: "auto"}`; an unsupported level falls back to the next lower supported
    ///   one (or the lowest); `minimal` is sent as is if supported.
    static func reasoningPlan(for level: ReasoningLevel?, capabilities: ProviderCapabilities) -> ReasoningPlan {
        guard let level, !capabilities.reasoningLevels.isEmpty else { return ReasoningPlan() }
        if level == .off {
            if capabilities.reasoningLevels.contains(.off) { return ReasoningPlan(value: ["effort": "none"], sent: .off) }
            guard let lowest = capabilities.reasoningLevels.filter({ $0 != .off }).min() else { return ReasoningPlan() }
            return ReasoningPlan(value: ["effort": .string(lowest.rawValue), "summary": "auto"], sent: lowest)
        }
        guard let chosen = ReasoningResolution.clamp(level, to: capabilities.reasoningLevels) else { return ReasoningPlan() }
        return ReasoningPlan(value: ["effort": .string(chosen.rawValue), "summary": "auto"], sent: chosen)
    }

    // MARK: Request

    static func body(
        for request: ModelRequest, model: String, plan: ReasoningPlan, redactImages: Bool
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model), "stream": true,
            "max_output_tokens": .number(Double(request.maxOutputTokens ?? defaultMaxOutputTokens)),
            "input": .array(inputItems(request.messages, redactImages: redactImages)),
        ]
        let system = request.system.combined
        if !system.isEmpty { body["instructions"] = .string(system) }
        if let reasoning = plan.value { body["reasoning"] = reasoning }
        if let schema = request.responseSchema {
            var format: [String: JSONValue] = [
                "type": "json_schema", "name": .string(sanitizedSchemaName(schema.name)),
                "strict": .bool(satisfiesStrictRules(schema.schema)), "schema": schema.schema,
            ]
            if let description = schema.description { format["description"] = .string(description) }
            body["text"] = ["format": .object(format)]
        }
        if !request.tools.isEmpty {
            // strict: false because our schemas do not necessarily satisfy the strict-mode rules.
            body["tools"] = .array(request.tools.map {
                [
                    "type": "function", "name": .string($0.name), "description": .string($0.description),
                    "parameters": $0.parameters, "strict": false,
                ]
            })
        }
        return .object(body)
    }

    /// Whether a schema meets the rules of `strict: true` (Structured Outputs): every object has
    /// `additionalProperties: false` and lists all its properties in `required`, recursively. Otherwise the request
    /// would be rejected, so `strict` is sent as false for such schemas.
    static func satisfiesStrictRules(_ schema: JSONValue) -> Bool {
        switch schema {
        case .array(let items): return items.allSatisfy(satisfiesStrictRules)
        case .object(let object):
            let types: [String]
            switch object["type"] {
            case .string(let type)?: types = [type]
            case .array(let list)?: types = list.compactMap { if case .string(let t) = $0 { return t } else { return nil } }
            default: types = []
            }
            if types.contains("object") || object["properties"] != nil {
                guard object["additionalProperties"] == .bool(false) else { return false }
                var properties: [String: JSONValue] = [:]
                if case .object(let declared)? = object["properties"] { properties = declared }
                var required: Set<String> = []
                if case .array(let list)? = object["required"] {
                    required = Set(list.compactMap { if case .string(let name) = $0 { return name } else { return nil } })
                }
                guard Set(properties.keys).isSubset(of: required) else { return false }
            }
            // Recurse into every nested schema (properties, items, anyOf, $defs, ...).
            return object.allSatisfy { key, value in
                switch key {
                case "properties", "$defs", "definitions", "patternProperties":
                    if case .object(let nested) = value { return nested.values.allSatisfy(satisfiesStrictRules) }
                    return true
                case "items", "anyOf", "oneOf", "allOf", "prefixItems", "not", "additionalProperties", "if", "then", "else":
                    return satisfiesStrictRules(value)
                default: return true
                }
            }
        default: return true
        }
    }

    /// Schema names allow letters, digits, "_" and "-" only.
    static func sanitizedSchemaName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        return cleaned.isEmpty ? "response" : String(cleaned.prefix(64))
    }

    /// Messages as Responses input items. User turns carry `input_text`/`input_image` parts; assistant text is a
    /// plain-string message; tool calls and results become `function_call` / `function_call_output` items.
    /// Reasoning items of this provider (`.reasoning`) go back before the function calls of the same turn.
    static func inputItems(_ messages: [ChatMessage], redactImages: Bool) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            var parts: [JSONValue] = []
            var assistantText = ""
            func flush() {
                if message.role == .assistant {
                    if !assistantText.isEmpty { items.append(["role": "assistant", "content": .string(assistantText)]) }
                } else if !parts.isEmpty {
                    items.append(["role": "user", "content": .array(parts)])
                }
                parts = []
                assistantText = ""
            }
            for part in message.content {
                switch part {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    if message.role == .assistant { assistantText += text }
                    else { parts.append(["type": "input_text", "text": .string(text)]) }
                case .image(let image):
                    let data = redactImages
                        ? ProviderJSON.placeholder(forImageBytes: image.data.count)
                        : "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"
                    parts.append(["type": "input_image", "image_url": .string(data)])
                case .toolCall(let call):
                    flush()
                    items.append([
                        "type": "function_call", "call_id": .string(call.id), "name": .string(call.name),
                        "arguments": .string(call.arguments),
                    ])
                case .reasoning(let block):
                    guard block.provider == .openAI else { continue }
                    flush()
                    items.append(block.payload)
                case .toolResult(let result):
                    flush()
                    items.append([
                        "type": "function_call_output", "call_id": .string(result.callID),
                        "output": .string(result.content),
                    ])
                }
            }
            flush()
        }
        return items
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
        let (model, base) = (configuration.model, base)
        let runner = StreamRunner(
            transport: transport, retry: retry, now: now, kind: .openAI, providerName: configuration.name,
            model: model, errorStyle: .openAI)
        let keyProvider: @Sendable () throws -> String = { try self.readKey() }
        let imagesAllowed = ProviderFactory.imagesAllowed(by: configuration)
        return runner.run(for: request, reasoningSent: plan.sent, accumulator: ResponsesStreamState()) {
            try RequestGuard.checkImages(request, allowed: imagesAllowed)
            let key = try keyProvider()
            var urlRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/v1/responses"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
            urlRequest.httpBody = ProviderJSON.encode(Self.body(for: request, model: model, plan: plan, redactImages: false))
            return PreparedRequest(
                urlRequest: urlRequest,
                logBody: ProviderJSON.encode(Self.body(for: request, model: model, plan: plan, redactImages: true)))
        }
    }

    // MARK: ModelCatalog

    /// The account's chat models (non-chat models such as embeddings or speech are filtered out) with capabilities
    /// from `OpenAIModelTable`, sorted by id.
    public func availableModels() async throws -> [ModelInfo] {
        let key = try readKey()
        var urlRequest = URLRequest(url: try ProviderEndpoint.url(base: base, path: "/v1/models"))
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await ProviderHTTP.send(urlRequest, transport: transport, retry: retry, style: .openAI)
        guard let root = ProviderJSON.object(data) else {
            throw ProviderError.invalidResponse("Die Modellliste von OpenAI ist kein JSON.")
        }
        return (root["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
            .filter(OpenAIModelTable.isChatModel)
            .sorted()
            .map { ModelInfo(id: $0, capabilities: OpenAIModelTable.capabilities(for: $0)) }
    }
}

// MARK: - Stream parsing

/// State of one Responses event stream.
struct ResponsesStreamState: StreamAccumulator {
    private struct PendingCall { var itemID: String; var callID: String; var name: String; var arguments = ""; var emitted = false }

    private var calls: [PendingCall] = []
    private var reasoningItems: [(id: String?, value: JSONValue)] = []
    private var finished = false
    private var usageValue = TokenUsage()
    private(set) var stopReason: StopReason?

    var usage: TokenUsage { usageValue }
    var reasoningBlocks: [ReasoningBlock] { reasoningItems.map { ReasoningBlock(provider: .openAI, payload: $0.value) } }

    private mutating func collectReasoning(_ item: [String: Any]) {
        guard item["type"] as? String == "reasoning", let value = ProviderJSON.jsonValue(item) else { return }
        let id = item["id"] as? String
        if let id, let existing = reasoningItems.firstIndex(where: { $0.id == id }) {
            reasoningItems[existing].value = value
        } else {
            reasoningItems.append((id, value))
        }
    }

    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
        guard let root = ProviderJSON.object(event.data), let type = root["type"] as? String ?? event.event else { return [] }
        switch type {
        case "response.output_text.delta":
            if let delta = root["delta"] as? String, !delta.isEmpty { return [.textDelta(delta)] }
        case "response.refusal.delta":
            if let delta = root["delta"] as? String, !delta.isEmpty {
                stopReason = .refusal
                return [.textDelta(delta)]
            }
        case "response.reasoning_summary_text.delta":
            if let delta = root["delta"] as? String, !delta.isEmpty { return [.reasoningDelta(delta)] }
        case "response.output_item.added":
            if let item = root["item"] as? [String: Any], item["type"] as? String == "function_call" {
                let itemID = item["id"] as? String ?? item["call_id"] as? String ?? ""
                calls.append(PendingCall(
                    itemID: itemID, callID: item["call_id"] as? String ?? itemID, name: item["name"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? ""))
            }
        case "response.function_call_arguments.delta":
            if let index = callIndex(root["item_id"] as? String) { calls[index].arguments += root["delta"] as? String ?? "" }
        case "response.function_call_arguments.done":
            if let index = callIndex(root["item_id"] as? String) {
                if let arguments = root["arguments"] as? String { calls[index].arguments = arguments }
                if let name = root["name"] as? String, !name.isEmpty { calls[index].name = name }
                return emit(index)
            }
        case "response.output_item.done":
            if let item = root["item"] as? [String: Any] { collectReasoning(item) }
            if let item = root["item"] as? [String: Any], item["type"] as? String == "function_call",
               let index = callIndex(item["id"] as? String) {
                if let arguments = item["arguments"] as? String, !arguments.isEmpty { calls[index].arguments = arguments }
                return emit(index)
            }
        case "response.completed", "response.incomplete":
            finished = true
            let response = root["response"] as? [String: Any] ?? [:]
            readUsage(response["usage"] as? [String: Any])
            for item in response["output"] as? [[String: Any]] ?? [] { collectReasoning(item) }
            if stopReason != .refusal {
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                if let reason {
                    stopReason = reason == "max_output_tokens" ? .maxTokens : .other(reason)
                } else if type == "response.incomplete" || response["status"] as? String == "incomplete" {
                    stopReason = .other("incomplete")
                } else {
                    stopReason = calls.isEmpty ? .endTurn : .toolUse
                }
            }
            return calls.indices.flatMap { emit($0) }
        case "response.failed":
            let response = root["response"] as? [String: Any] ?? [:]
            let error = response["error"] as? [String: Any] ?? [:]
            throw ProviderHTTP.streamError(
                type: error["type"] as? String, code: error["code"] as? String,
                message: error["message"] as? String ?? "Die Antwort ist fehlgeschlagen.", style: .openAI)
        case "error":
            let error = root["error"] as? [String: Any] ?? root
            throw ProviderHTTP.streamError(
                type: error["type"] as? String == "error" ? nil : error["type"] as? String,
                code: error["code"] as? String, message: error["message"] as? String, style: .openAI)
        default: break
        }
        return []
    }

    mutating func end() throws -> [ModelEvent] {
        guard finished else { throw ProviderError.network("Die Verbindung wurde vor dem Ende der Antwort getrennt.") }
        return []
    }

    private func callIndex(_ itemID: String?) -> Int? {
        guard let itemID else { return calls.indices.last }
        return calls.firstIndex { $0.itemID == itemID }
    }

    private mutating func emit(_ index: Int) -> [ModelEvent] {
        guard !calls[index].emitted else { return [] }
        calls[index].emitted = true
        let call = calls[index]
        let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.arguments
        return [.toolCall(ToolCall(id: call.callID, name: call.name, arguments: arguments))]
    }

    private mutating func readUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        usageValue.inputTokens = ProviderJSON.int(usage["input_tokens"])
        usageValue.outputTokens = ProviderJSON.int(usage["output_tokens"])
        usageValue.cacheReadTokens = ProviderJSON.int((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        usageValue.reasoningTokens = ProviderJSON.int((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
    }
}
