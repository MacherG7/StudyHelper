import Foundation

// Contract of the AI layer (docs/PLAN.md §4, docs/API-REFERENZ.md). The rest of the app only talks to
// `ModelProvider`; every provider (mock, Claude, OpenAI, OpenAI-compatible, Apple) implements it and reports the
// same `ResponseMetadata`, so request logs, prices and the developer mode work alike for all of them.

/// Kind of a provider configuration.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// Fixed answers for tests and UI tests. Never calls a network.
    case mock
    case claude
    case openAI
    /// Self-hosted OpenAI-compatible server (Ollama, LM Studio, llama.cpp, vLLM).
    case openAICompatible
    /// On-device Apple Foundation Model (iOS 26+, Apple Intelligence).
    case appleFoundation

    /// Providers that cost nothing per request (prices shown as 0 €).
    public var isFree: Bool { self == .mock || self == .openAICompatible || self == .appleFoundation }

    /// Whether this kind of provider can take a PDF as input at all (Claude, OpenAI; the mock mirrors them). The
    /// OpenAI-compatible servers and the on-device model cannot. A model that accepts PDFs also needs image support.
    public var acceptsDocuments: Bool { self == .mock || self == .claude || self == .openAI }
}

/// Reasoning depth, ordered from none to most. Each provider maps it to its own parameter; only the levels a model
/// supports (`ProviderCapabilities.reasoningLevels`) are offered.
public enum ReasoningLevel: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case off, minimal, low, medium, high, xhigh, max

    public static func < (lhs: ReasoningLevel, rhs: ReasoningLevel) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// How a model switches reasoning off (Claude: `thinking.type`).
public enum ReasoningOffMode: String, Codable, Sendable, Hashable {
    /// `thinking: {type: "disabled"}`.
    case disabled
    /// `thinking: {type: "between_tools"}` (models that cannot fully disable thinking).
    case betweenTools
}

/// What a model can do. Comes from the provider's model list (Claude `/v1/models`, Ollama `/api/show`), from a
/// maintained table (OpenAI) or from the user's setting ("Modell kann Bilder verarbeiten").
public struct ProviderCapabilities: Codable, Sendable, Hashable {
    public var supportsImages: Bool
    public var supportsTools: Bool
    public var supportsStreaming: Bool
    public var supportsStructuredOutput: Bool
    /// Selectable reasoning levels; empty = the model has no reasoning option.
    public var reasoningLevels: [ReasoningLevel]
    /// The level the API uses when none is sent, if known.
    public var defaultReasoning: ReasoningLevel?
    /// Context window in tokens, if known.
    public var contextSize: Int?
    /// Largest output in tokens, if known.
    public var maxOutputTokens: Int?
    /// How `ReasoningLevel.off` is sent, if `reasoningLevels` contains `.off` (nil = provider default).
    public var reasoningOffMode: ReasoningOffMode?

    public init(
        supportsImages: Bool = false, supportsTools: Bool = false, supportsStreaming: Bool = true,
        supportsStructuredOutput: Bool = false, reasoningLevels: [ReasoningLevel] = [],
        defaultReasoning: ReasoningLevel? = nil, contextSize: Int? = nil, maxOutputTokens: Int? = nil,
        reasoningOffMode: ReasoningOffMode? = nil
    ) {
        self.supportsImages = supportsImages
        self.supportsTools = supportsTools
        self.supportsStreaming = supportsStreaming
        self.supportsStructuredOutput = supportsStructuredOutput
        self.reasoningLevels = reasoningLevels
        self.defaultReasoning = defaultReasoning
        self.contextSize = contextSize
        self.maxOutputTokens = maxOutputTokens
        self.reasoningOffMode = reasoningOffMode
    }
}

/// A model offered by a provider's model list.
public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var capabilities: ProviderCapabilities

    public init(id: String, displayName: String? = nil, capabilities: ProviderCapabilities) {
        self.id = id
        self.displayName = displayName ?? id
        self.capabilities = capabilities
    }
}

/// Lists the models of a configured provider (needs the key for Claude/OpenAI).
public protocol ModelCatalog: Sendable {
    func availableModels() async throws -> [ModelInfo]
}

// MARK: - Request

/// System prompt in two parts: the fixed part (basic rule "nur Inhalte aus dem Lernstoff" and output format, added
/// by the app, never editable) and the editable part (default or user text, placeholders filled).
public struct PromptParts: Codable, Sendable, Hashable {
    public var fixed: String
    public var editable: String

    public init(fixed: String, editable: String = "") {
        self.fixed = fixed
        self.editable = editable
    }

    /// Both parts as one system prompt; the fixed part always comes first.
    public var combined: String {
        [fixed, editable].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Arbitrary JSON (tool parameter schemas, response schemas, tool arguments).
public indirect enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct ImagePayload: Codable, Sendable, Hashable {
    public var data: Data
    /// e.g. "image/jpeg", "image/png".
    public var mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}

/// A document (PDF) sent to the model as input. Only models that accept images can process it (each page is
/// sent as text and as image); the bytes never appear in logs.
public struct DocumentPayload: Codable, Sendable, Hashable {
    public var data: Data
    /// e.g. "application/pdf".
    public var mediaType: String
    /// Name shown to the model / required by OpenAI's `input_file`.
    public var filename: String

    public init(data: Data, mediaType: String = "application/pdf", filename: String = "seite.pdf") {
        self.data = data
        self.mediaType = mediaType
        self.filename = filename
    }

    private enum CodingKeys: String, CodingKey { case data, mediaType, filename }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(Data.self, forKey: .data)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType) ?? "application/pdf"
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "seite.pdf"
    }
}

/// A function the model may call (tool use / function calling).
public struct ToolDefinition: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments (type "object").
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    /// Provider id of the call (Claude `tool_use.id`, OpenAI `call_id`).
    public var id: String
    public var name: String
    /// Arguments as JSON text, exactly as the model produced them (may be invalid; parse defensively).
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Sendable, Hashable {
    public var callID: String
    public var content: String
    public var isError: Bool

    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}

/// Opaque reasoning data of one provider (Claude `thinking` / `redacted_thinking` block with its signature,
/// OpenAI Responses `reasoning` item). It must be passed back unchanged in the assistant message of a tool loop;
/// all other providers ignore it when sending.
public struct ReasoningBlock: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var payload: JSONValue

    public init(provider: ProviderKind, payload: JSONValue) {
        self.provider = provider
        self.payload = payload
    }
}

public enum MessageContent: Codable, Sendable, Hashable {
    case text(String)
    case image(ImagePayload)
    /// A PDF document (see `DocumentPayload`).
    case document(DocumentPayload)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// Provider reasoning data to send back (see `ReasoningBlock`); never shown as text.
    case reasoning(ReasoningBlock)
}

public struct ChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var content: [MessageContent]

    public init(role: Role, content: [MessageContent]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: [.text(text)]) }
}

/// JSON schema the answer must follow (structured output / Guided Generation).
public struct ResponseSchema: Codable, Sendable, Hashable {
    public var name: String
    public var schema: JSONValue
    public var description: String?

    public init(name: String, schema: JSONValue, description: String? = nil) {
        self.name = name
        self.schema = schema
        self.description = description
    }
}

/// What a request is for; reasoning can be overridden per task, and costs are reported per task.
public enum AITask: String, Codable, Sendable, CaseIterable, Hashable {
    case digitization, structuring, query, freeTextGrading, flashcards, chat, tips, connectionTest
}

public struct ModelRequest: Codable, Sendable, Hashable {
    public var task: AITask
    public var system: PromptParts
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var responseSchema: ResponseSchema?
    /// nil = the configuration's level (or the model default).
    public var reasoning: ReasoningLevel?
    /// nil = provider default.
    public var maxOutputTokens: Int?
    /// Learning units in the context (shown in the developer mode).
    public var learningUnitIDsInContext: [String]

    public init(
        task: AITask, system: PromptParts, messages: [ChatMessage], tools: [ToolDefinition] = [],
        responseSchema: ResponseSchema? = nil, reasoning: ReasoningLevel? = nil, maxOutputTokens: Int? = nil,
        learningUnitIDsInContext: [String] = []
    ) {
        self.task = task
        self.system = system
        self.messages = messages
        self.tools = tools
        self.responseSchema = responseSchema
        self.reasoning = reasoning
        self.maxOutputTokens = maxOutputTokens
        self.learningUnitIDsInContext = learningUnitIDsInContext
    }

    /// Whether images, documents or text were sent (developer mode: "Bild, gespeicherter Text oder beides").
    public var sentContent: Set<SentContent> {
        var result: Set<SentContent> = []
        for message in messages {
            for part in message.content {
                switch part {
                case .image: result.insert(.image)
                case .document: result.insert(.document)
                case .text, .toolResult: result.insert(.text)
                case .toolCall, .reasoning: break
                }
            }
        }
        return result
    }
}

public enum SentContent: String, Codable, Sendable, Hashable { case text, image, document }

// MARK: - Response

/// Token counts from the API's usage data; nil = the API did not report it.
public struct TokenUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Input tokens read from the prompt cache.
    public var cacheReadTokens: Int?
    /// Input tokens written to the prompt cache.
    public var cacheWriteTokens: Int?
    /// Reasoning tokens (already contained in `outputTokens` for OpenAI; reported separately if the API does).
    public var reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum StopReason: Codable, Sendable, Hashable {
    case endTurn, maxTokens, toolUse, refusal, other(String)
}

/// The same record for every provider: feeds the request log, the price estimate and the developer mode.
public struct ResponseMetadata: Codable, Sendable, Hashable {
    public var task: AITask
    public var providerKind: ProviderKind
    /// Name of the configuration ("Claude privat").
    public var providerName: String
    public var model: String
    /// Level actually sent (nil = model default / no reasoning).
    public var reasoning: ReasoningLevel?
    public var usage: TokenUsage
    public var date: Date
    /// Seconds from sending to the last byte.
    public var duration: TimeInterval
    /// Seconds until the first answer token (streaming only).
    public var timeToFirstToken: TimeInterval?
    public var sentContent: Set<SentContent>
    public var toolCalls: [ToolCall]
    public var learningUnitIDsInContext: [String]
    /// Request body as sent, without headers (keys never appear here).
    public var rawRequest: String
    /// Response body or the concatenated stream events.
    public var rawResponse: String
    /// Reasoning text or summary, if the API returned one (shown only in the developer mode).
    public var reasoningText: String?
    public var stopReason: StopReason?
    /// Set by the caller when the answer did not match the expected format.
    public var parsingError: String?
    /// Apple: tokens used of the context window (iOS 26.4+).
    public var contextTokensUsed: Int?
    public var contextSize: Int?

    public init(
        task: AITask, providerKind: ProviderKind, providerName: String, model: String, reasoning: ReasoningLevel?,
        usage: TokenUsage = TokenUsage(), date: Date = Date(), duration: TimeInterval = 0,
        timeToFirstToken: TimeInterval? = nil, sentContent: Set<SentContent> = [], toolCalls: [ToolCall] = [],
        learningUnitIDsInContext: [String] = [], rawRequest: String = "", rawResponse: String = "",
        reasoningText: String? = nil, stopReason: StopReason? = nil, parsingError: String? = nil,
        contextTokensUsed: Int? = nil, contextSize: Int? = nil
    ) {
        self.task = task
        self.providerKind = providerKind
        self.providerName = providerName
        self.model = model
        self.reasoning = reasoning
        self.usage = usage
        self.date = date
        self.duration = duration
        self.timeToFirstToken = timeToFirstToken
        self.sentContent = sentContent
        self.toolCalls = toolCalls
        self.learningUnitIDsInContext = learningUnitIDsInContext
        self.rawRequest = rawRequest
        self.rawResponse = rawResponse
        self.reasoningText = reasoningText
        self.stopReason = stopReason
        self.parsingError = parsingError
        self.contextTokensUsed = contextTokensUsed
        self.contextSize = contextSize
    }

    /// Output tokens per second after the first token (or over the whole duration without streaming).
    public var outputTokensPerSecond: Double? {
        guard let output = usage.outputTokens, output > 0 else { return nil }
        let seconds = duration - (timeToFirstToken ?? 0)
        return seconds > 0 ? Double(output) / seconds : nil
    }
}

public struct ModelResponse: Codable, Sendable, Hashable {
    /// Answer text (reasoning never included).
    public var text: String
    public var toolCalls: [ToolCall]
    /// Opaque reasoning blocks of the answer (Claude thinking with signature, OpenAI reasoning items).
    public var reasoningBlocks: [ReasoningBlock]
    public var metadata: ResponseMetadata

    public init(
        text: String, toolCalls: [ToolCall] = [], reasoningBlocks: [ReasoningBlock] = [], metadata: ResponseMetadata
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.reasoningBlocks = reasoningBlocks
        self.metadata = metadata
    }

    /// The answer as content of the assistant message to append to the conversation (e.g. before the tool results
    /// of a tool loop): reasoning blocks, text, tool calls, in this order.
    public var assistantContent: [MessageContent] {
        reasoningBlocks.map { MessageContent.reasoning($0) }
            + (text.isEmpty ? [] : [MessageContent.text(text)])
            + toolCalls.map { MessageContent.toolCall($0) }
    }
}

public enum ModelEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(ToolCall)
    /// Always the last event of a successful stream.
    case finished(ModelResponse)
}

/// Errors every provider maps its failures to. `LocalizedError` texts are German (shown in the app).
public enum ProviderError: Error, Sendable, Hashable {
    case missingAPIKey
    case invalidAPIKey
    case permissionDenied(String)
    case modelNotFound(String)
    /// Retry after the given seconds, if the API said so.
    case rateLimited(retryAfter: TimeInterval?)
    /// Spend limit, credit or quota exhausted: retrying does not help.
    case quotaExceeded(String)
    case overloaded
    case badRequest(String)
    case server(status: Int, message: String)
    case network(String)
    case invalidResponse(String)
    /// The model declined (Claude `stop_reason: refusal`).
    case refused(category: String?)
    /// Provider not usable on this device (Apple: no Apple Intelligence, model not ready, iOS too old).
    case unavailable(String)
    case cancelled

    /// Worth retrying automatically.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: return true
        case .server(let status, _): return status >= 500
        default: return false
        }
    }
}

/// A failed request that was already built and sent (or at least prepared): the error plus what is known about the
/// request so far (usage up to the failure, raw request, raw events, reasoning level actually sent). Errors before the
/// request existed (missing key, invalid address) stay plain `ProviderError`s. Callers match on
/// `error.providerError`.
public struct ProviderFailure: Error, Sendable, Hashable {
    public var underlying: ProviderError
    public var metadata: ResponseMetadata?

    public init(underlying: ProviderError, metadata: ResponseMetadata? = nil) {
        self.underlying = underlying
        self.metadata = metadata
    }
}

extension ProviderFailure: LocalizedError {
    public var errorDescription: String? { underlying.errorDescription }
}

extension Error {
    /// The `ProviderError` of this error, also when wrapped in a `ProviderFailure`.
    public var providerError: ProviderError? {
        if let failure = self as? ProviderFailure { return failure.underlying }
        return self as? ProviderError
    }

    /// Partial metadata of a failed request, if the provider attached any.
    public var failureMetadata: ResponseMetadata? { (self as? ProviderFailure)?.metadata }
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Für diesen Anbieter ist kein API-Key gespeichert."
        case .invalidAPIKey: return "Der API-Key wurde abgelehnt."
        case .permissionDenied(let message): return "Keine Berechtigung: \(message)"
        case .modelNotFound(let model): return "Das Modell „\(model)“ gibt es bei diesem Anbieter nicht."
        case .rateLimited: return "Zu viele Anfragen. Bitte gleich noch einmal versuchen."
        case .quotaExceeded(let message): return "Guthaben oder Limit erschöpft: \(message)"
        case .overloaded: return "Der Anbieter ist gerade überlastet."
        case .badRequest(let message): return "Die Anfrage wurde abgelehnt: \(message)"
        case .server(let status, let message): return "Fehler beim Anbieter (\(status)): \(message)"
        case .network(let message): return "Keine Verbindung: \(message)"
        case .invalidResponse(let message): return "Unerwartete Antwort: \(message)"
        case .refused(let category):
            return "Das Modell hat die Anfrage abgelehnt" + (category.map { " (\($0))" } ?? "") + "."
        case .unavailable(let reason): return "Nicht verfügbar: \(reason)"
        case .cancelled: return "Abgebrochen."
        }
    }
}

/// One AI provider. Implementations: `MockProvider`, `ClaudeProvider`, `OpenAIProvider`,
/// `OpenAICompatibleProvider`, `AppleFoundationProvider`.
public protocol ModelProvider: Sendable {
    var kind: ProviderKind { get }
    /// Capabilities of the configured model.
    var capabilities: ProviderCapabilities { get }
    /// Streams the answer; the last event is `.finished` with the complete response and metadata.
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    /// The complete answer (default: collects `stream`).
    func respond(to request: ModelRequest) async throws -> ModelResponse
}

extension ModelProvider {
    /// Whether requests may contain `.document` parts: the provider kind accepts PDFs and the model processes images
    /// (a PDF is read as text plus page images). Claude and OpenAI follow their image support, OpenAI-compatible
    /// and Apple never, the mock follows its configured image support. Use `PageContent.parts` to build the content.
    public var supportsDocuments: Bool { kind.acceptsDocuments && capabilities.supportsImages }

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        for try await event in stream(request) {
            if case .finished(let response) = event { return response }
        }
        throw ProviderError.invalidResponse("Die Antwort endete ohne Abschluss.")
    }
}
