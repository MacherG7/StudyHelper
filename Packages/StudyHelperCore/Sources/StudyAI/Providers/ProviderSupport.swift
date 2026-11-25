import Foundation
import StudyCore

// Shared building blocks of the HTTP providers: JSON helpers, one-shot requests with retry and error mapping, and the
// streaming runner (SSE -> ModelEvent + ResponseMetadata). Providers only add request bodies and event parsing.

// MARK: - JSON helpers

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

enum ProviderJSON {
    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func decode(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Tool arguments as JSON object; invalid or non-object text becomes `{}` (the original text stays in `ToolCall`).
    static func argumentsObject(_ text: String) -> JSONValue {
        if let value = decode(text), case .object = value { return value }
        return .object([:])
    }

    static func object(_ text: String) -> [String: Any]? {
        object(Data(text.utf8))
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        return nil
    }

    static func placeholder(forImageBytes count: Int) -> String { "<Bild, \(count) Bytes>" }

    /// A parsed JSON dictionary (from `JSONSerialization`) as `JSONValue`; nil if it cannot be converted.
    static func jsonValue(_ object: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Request checks

enum RequestGuard {
    static let imagesUnsupported = "Dieses Modell kann keine Bilder verarbeiten."

    /// Rejects a request with images before anything is sent when the model cannot process images.
    static func checkImages(_ request: ModelRequest, allowed: Bool) throws {
        if !allowed, request.sentContent.contains(.image) { throw ProviderError.badRequest(imagesUnsupported) }
    }
}

// MARK: - Endpoints

enum ProviderEndpoint {
    /// `base` + `path`; base must be http(s) with a host. A trailing slash and a trailing "/v1" of `base` are
    /// tolerated when `path` starts with "/v1".
    static func url(base: String, path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1"), path.hasPrefix("/v1") { trimmed.removeLast(3) }
        guard let components = URLComponents(string: trimmed + path), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              let url = components.url
        else { throw ProviderError.badRequest("Ungültige Serveradresse: \(URLRedaction.redact(url: base))") }
        return url
    }
}

// MARK: - One-shot requests

enum ProviderHTTP {
    /// Sends a request with retries; non-2xx responses become `ProviderError`s.
    static func send(
        _ request: URLRequest, transport: HTTPTransport, retry: RetryPolicy, style: HTTPErrorMapper.Style,
        model: String? = nil
    ) async throws -> Data {
        try await retry.run {
            do {
                let (data, response) = try await transport.send(request)
                guard (200..<300).contains(response.statusCode) else {
                    throw HTTPErrorMapper.map(
                        status: response.statusCode, body: data, headers: response.stringHeaders, style: style,
                        model: model)
                }
                return data
            } catch {
                throw providerError(from: error)
            }
        }
    }

    /// Like `send`, but returns nil instead of throwing (feature detection, e.g. Ollama's `/api/tags`).
    static func sendIfPossible(_ request: URLRequest, transport: HTTPTransport) async -> Data? {
        guard let (data, response) = try? await transport.send(request), (200..<300).contains(response.statusCode)
        else { return nil }
        return data
    }

    /// Error of a stream `error` event / failed response, mapped like an HTTP error.
    /// `type` and `code` are the API's error type and code.
    static func streamError(type: String?, code: String?, message: String?, style: HTTPErrorMapper.Style) -> ProviderError {
        let marker = "\(type ?? "") \(code ?? "")".lowercased()
        let status: Int
        if marker.contains("overloaded") { status = style == .anthropic ? 529 : 503 }
        else if marker.contains("rate_limit") { status = 429 }
        else if marker.contains("authentication") || marker.contains("invalid_api_key") { status = 401 }
        else if marker.contains("permission") { status = 403 }
        else if marker.contains("not_found") { status = 404 }
        else if marker.contains("billing") { status = 402 }
        else if marker.contains("invalid_request") { status = 400 }
        else { status = 500 }
        var error: [String: JSONValue] = ["message": .string(message ?? "")]
        if let type { error["type"] = .string(type) }
        if let code { error["code"] = .string(code) }
        let body = ProviderJSON.encode(["error": .object(error)])
        return HTTPErrorMapper.map(status: status, body: body, style: style)
    }
}

// MARK: - Streaming

/// A request ready to send plus its log text (masked headers, body without image bytes).
struct PreparedRequest: Sendable {
    var urlRequest: URLRequest
    var log: String

    init(urlRequest: URLRequest, logBody: Data) {
        self.urlRequest = urlRequest
        var logged = urlRequest
        logged.httpBody = logBody
        self.log = HeaderMasking.render(logged)
    }
}

/// Provider-specific parsing of the event stream. Text, reasoning and tool calls are collected by the runner from the
/// events the accumulator returns; the accumulator only tracks usage, stop reason and completeness.
protocol StreamAccumulator: Sendable {
    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent]
    /// The stream ended: flush pending data; throw if the stream was cut off.
    mutating func end() throws -> [ModelEvent]
    var usage: TokenUsage { get }
    var stopReason: StopReason? { get }
    /// Opaque reasoning blocks collected so far (to be passed back in tool loops).
    var reasoningBlocks: [ReasoningBlock] { get }
}

extension StreamAccumulator {
    var reasoningBlocks: [ReasoningBlock] { [] }
}

struct StreamRunner: Sendable {
    var transport: HTTPTransport
    var retry: RetryPolicy
    var now: @Sendable () -> Date
    var kind: ProviderKind
    var providerName: String
    var model: String
    var errorStyle: HTTPErrorMapper.Style

    private struct Collector {
        var text = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var firstToken: Date?

        mutating func record(_ event: ModelEvent, at date: Date) {
            switch event {
            case .textDelta(let delta):
                text += delta
                if firstToken == nil, !delta.isEmpty { firstToken = date }
            case .reasoningDelta(let delta):
                reasoning += delta
                if firstToken == nil, !delta.isEmpty { firstToken = date }
            case .toolCall(let call): toolCalls.append(call)
            case .finished: break
            }
        }
    }

    /// Retries only cover connecting and the HTTP status (before the first byte of the stream); errors inside the
    /// stream are not retried because text may already have been shown.
    private func open(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        do {
            let (lines, response) = try await transport.stream(request)
            guard (200..<300).contains(response.statusCode) else {
                var body: [String] = []
                for try await line in lines { body.append(line) }
                throw HTTPErrorMapper.map(
                    status: response.statusCode, body: Data(body.joined(separator: "\n").utf8),
                    headers: response.stringHeaders, style: errorStyle, model: model)
            }
            return lines
        } catch {
            throw providerError(from: error)
        }
    }

    private func metadata<A: StreamAccumulator>(
        for modelRequest: ModelRequest, reasoningSent: ReasoningLevel?, prepared: PreparedRequest, start: Date, end: Date,
        accumulator: A, collector: Collector, rawEvents: [String]
    ) -> ResponseMetadata {
        ResponseMetadata(
            task: modelRequest.task, providerKind: kind, providerName: providerName, model: model,
            reasoning: reasoningSent, usage: accumulator.usage, date: start, duration: end.timeIntervalSince(start),
            timeToFirstToken: collector.firstToken.map { $0.timeIntervalSince(start) },
            sentContent: modelRequest.sentContent, toolCalls: collector.toolCalls,
            learningUnitIDsInContext: modelRequest.learningUnitIDsInContext, rawRequest: prepared.log,
            rawResponse: rawEvents.joined(separator: "\n"),
            reasoningText: collector.reasoning.isEmpty ? nil : collector.reasoning, stopReason: accumulator.stopReason)
    }

    /// Runs the request. A failure after the request was prepared is thrown as `ProviderFailure` carrying the partial
    /// metadata (usage so far, raw request and events, reasoning level actually sent).
    func run<A: StreamAccumulator>(
        for modelRequest: ModelRequest, reasoningSent: ReasoningLevel?, accumulator: A,
        prepare: @escaping @Sendable () throws -> PreparedRequest
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let runner = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var prepared: PreparedRequest?
                var start = runner.now()
                var accumulator = accumulator
                var collector = Collector()
                var rawEvents: [String] = []
                do {
                    let request = try prepare()
                    prepared = request
                    start = runner.now()
                    let lines = try await runner.retry.run { try await runner.open(request.urlRequest) }
                    for try await sse in SSEParser.events(from: lines) {
                        rawEvents.append(sse.data)
                        for event in try accumulator.consume(sse) {
                            collector.record(event, at: runner.now())
                            continuation.yield(event)
                        }
                    }
                    try Task.checkCancellation()
                    for event in try accumulator.end() {
                        collector.record(event, at: runner.now())
                        continuation.yield(event)
                    }
                    let metadata = runner.metadata(
                        for: modelRequest, reasoningSent: reasoningSent, prepared: request, start: start,
                        end: runner.now(), accumulator: accumulator, collector: collector, rawEvents: rawEvents)
                    continuation.yield(.finished(
                        ModelResponse(
                            text: collector.text, toolCalls: collector.toolCalls,
                            reasoningBlocks: accumulator.reasoningBlocks, metadata: metadata)))
                    continuation.finish()
                } catch {
                    let underlying = providerError(from: error)
                    guard let prepared else {
                        continuation.finish(throwing: underlying)
                        return
                    }
                    let partial = runner.metadata(
                        for: modelRequest, reasoningSent: reasoningSent, prepared: prepared, start: start,
                        end: runner.now(), accumulator: accumulator, collector: collector, rawEvents: rawEvents)
                    continuation.finish(throwing: ProviderFailure(underlying: underlying, metadata: partial))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Reasoning helpers

enum ReasoningResolution {
    /// The highest supported level that is not above `target`; if all supported levels are above it, the lowest.
    static func clamp(_ target: ReasoningLevel, to supported: [ReasoningLevel]) -> ReasoningLevel? {
        let candidates = supported.filter { $0 != .off }
        return candidates.filter { $0 <= target }.max() ?? candidates.min()
    }
}
