import Foundation

/// What a `MockProvider` answers. Fixed data for unit and UI tests; never touches the network.
public struct MockScript: Sendable {
    public enum ErrorTiming: Sendable, Hashable {
        /// Thrown before any event.
        case beforeStream
        /// Thrown after this many text chunks were delivered.
        case afterChunks(Int)
    }

    public var chunks: [String]
    public var reasoningText: String?
    public var toolCalls: [ToolCall]
    public var usage: TokenUsage
    public var stopReason: StopReason
    public var error: ProviderError?
    public var errorTiming: ErrorTiming
    /// Pause before each chunk (seconds); 0 in tests.
    public var chunkDelay: TimeInterval

    public init(
        chunks: [String] = ["Das ist eine Testantwort."], reasoningText: String? = nil, toolCalls: [ToolCall] = [],
        usage: TokenUsage = TokenUsage(inputTokens: 10, outputTokens: 5), stopReason: StopReason = .endTurn,
        error: ProviderError? = nil, errorTiming: ErrorTiming = .beforeStream, chunkDelay: TimeInterval = 0
    ) {
        self.chunks = chunks
        self.reasoningText = reasoningText
        self.toolCalls = toolCalls
        self.usage = usage
        self.stopReason = stopReason
        self.error = error
        self.errorTiming = errorTiming
        self.chunkDelay = chunkDelay
    }

    /// Answer split into chunks of `chunkSize` characters.
    public init(answer: String, chunkSize: Int = 8, reasoningText: String? = nil, toolCalls: [ToolCall] = [],
                usage: TokenUsage = TokenUsage(inputTokens: 10, outputTokens: 5)) {
        let characters = Array(answer)
        let size = max(1, chunkSize)
        let chunks = stride(from: 0, to: characters.count, by: size).map {
            String(characters[$0..<min($0 + size, characters.count)])
        }
        self.init(chunks: chunks, reasoningText: reasoningText, toolCalls: toolCalls, usage: usage)
    }

    public var answer: String { chunks.joined() }
}

public final class MockProvider: ModelProvider, @unchecked Sendable {
    public let kind: ProviderKind = .mock
    public let capabilities: ProviderCapabilities
    public let name: String
    public let model: String
    public var script: MockScript {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    /// Requests received so far (for assertions).
    public var receivedRequests: [ModelRequest] { lock.withLock { _requests } }

    private let lock = NSLock()
    private var _script: MockScript
    private var _requests: [ModelRequest] = []
    private let now: @Sendable () -> Date

    public init(
        script: MockScript = MockScript(), name: String = "Mock", model: String = "mock-1",
        capabilities: ProviderCapabilities = ProviderCapabilities(
            supportsImages: true, supportsTools: true, supportsStreaming: true, supportsStructuredOutput: true,
            reasoningLevels: [.off, .low, .medium, .high]),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self._script = script
        self.name = name
        self.model = model
        self.capabilities = capabilities
        self.now = now
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let script = lock.withLock { () -> MockScript in
            _requests.append(request)
            return _script
        }
        let start = now()
        let rawRequest = Self.rawRequest(of: request)
        let (name, model, now) = (name, model, now)
        let imagesAllowed = capabilities.supportsImages
        return AsyncThrowingStream { continuation in
            let task = Task {
                var events: [String] = []
                var firstToken: Date?
                do {
                    try RequestGuard.checkDocuments(request, allowed: imagesAllowed)
                    try RequestGuard.checkImages(request, allowed: imagesAllowed)
                    if script.error != nil, script.errorTiming == .beforeStream { throw script.error! }
                    if let reasoning = script.reasoningText, !reasoning.isEmpty {
                        continuation.yield(.reasoningDelta(reasoning))
                        events.append("reasoning: \(reasoning)")
                    }
                    for (index, chunk) in script.chunks.enumerated() {
                        if script.chunkDelay > 0 { try await Task.sleep(nanoseconds: UInt64(script.chunkDelay * 1e9)) }
                        try Task.checkCancellation()
                        if let error = script.error, script.errorTiming == .afterChunks(index) { throw error }
                        if firstToken == nil { firstToken = now() }
                        continuation.yield(.textDelta(chunk))
                        events.append("text: \(chunk)")
                    }
                    if let error = script.error, case .afterChunks(let count) = script.errorTiming,
                       count >= script.chunks.count { throw error }
                    for call in script.toolCalls {
                        continuation.yield(.toolCall(call))
                        events.append("tool: \(call.name) \(call.arguments)")
                    }
                    let end = now()
                    let metadata = ResponseMetadata(
                        task: request.task, providerKind: .mock, providerName: name, model: model,
                        reasoning: request.reasoning, usage: script.usage, date: start,
                        duration: end.timeIntervalSince(start), timeToFirstToken: firstToken.map { $0.timeIntervalSince(start) },
                        sentContent: request.sentContent, toolCalls: script.toolCalls,
                        learningUnitIDsInContext: request.learningUnitIDsInContext, rawRequest: rawRequest,
                        rawResponse: events.joined(separator: "\n"), reasoningText: script.reasoningText,
                        stopReason: script.stopReason)
                    continuation.yield(.finished(
                        ModelResponse(text: script.answer, toolCalls: script.toolCalls, metadata: metadata)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    // Errors of the script happen "after sending": attach what is known so far.
                    if case .badRequest(let message) = error,
                       message == RequestGuard.imagesUnsupported || message == RequestGuard.documentsUnsupported {
                        continuation.finish(throwing: error)
                        return
                    }
                    let end = now()
                    let metadata = ResponseMetadata(
                        task: request.task, providerKind: .mock, providerName: name, model: model,
                        reasoning: request.reasoning, date: start, duration: end.timeIntervalSince(start),
                        timeToFirstToken: firstToken.map { $0.timeIntervalSince(start) },
                        sentContent: request.sentContent, learningUnitIDsInContext: request.learningUnitIDsInContext,
                        rawRequest: rawRequest, rawResponse: events.joined(separator: "\n"))
                    continuation.finish(throwing: ProviderFailure(underlying: error, metadata: metadata))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The request as JSON text; image and PDF bytes are replaced by a placeholder so logs stay small.
    static func rawRequest(of request: ModelRequest) -> String {
        var copy = request
        copy.messages = request.messages.map { message in
            var message = message
            message.content = message.content.map { part in
                if case .image(let image) = part { return .text(ProviderJSON.placeholder(forImageBytes: image.data.count)) }
                if case .document(let document) = part {
                    return .text(ProviderJSON.placeholder(forPDFBytes: document.data.count))
                }
                return part
            }
            return message
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
