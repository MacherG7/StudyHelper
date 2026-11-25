import Foundation
import Testing

@testable import StudyAI

private let adaptiveCaps = ProviderCapabilities(
    supportsImages: true, supportsTools: true, supportsStructuredOutput: true,
    reasoningLevels: [.off, .low, .medium, .high, .xhigh, .max], contextSize: 1_000_000, maxOutputTokens: 64_000,
    reasoningOffMode: .disabled)

private func makeClaude(
    capabilities: ProviderCapabilities? = adaptiveCaps, stub: StubTransport, key: String? = TestSupport.secretKey,
    reasoning: ReasoningLevel? = nil, clock: TestSupport.TickClock = TestSupport.TickClock()
) -> ClaudeProvider {
    let configuration = TestSupport.configuration(
        .claude, model: "claude-sonnet-5-5", capabilities: capabilities, reasoning: reasoning)
    return ClaudeProvider(
        configuration: configuration, keyStore: TestSupport.keyStore(for: configuration, key: key), transport: stub,
        retry: TestSupport.fastRetry, now: { clock.next() })
}

private let textStream: [String] = TestSupport.sse([
    ("message_start", #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":25,"cache_creation_input_tokens":100,"cache_read_input_tokens":300,"output_tokens":1}}}"#),
    ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Ich "}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"überlege."}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#),
    ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
    ("ping", #"{"type":"ping"}"#),
    ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hallo"}}"#),
    ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" Welt"}}"#),
    ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
    ("future_event", #"{"type":"future_event","x":1}"#),
    ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42,"output_tokens_details":{"thinking_tokens":7}}}"#),
    ("message_stop", #"{"type":"message_stop"}"#),
])

@Suite("Claude: Anfrage")
struct ClaudeRequestTests {
    @Test("Textanfrage: genauer JSON-Body, Header und kein temperature/top_p/top_k")
    func textRequest() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        _ = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request())
        let sent = try #require(stub.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(TestSupport.header(sent, "x-api-key") == TestSupport.secretKey)
        #expect(TestSupport.header(sent, "anthropic-version") == "2026-10-21")
        #expect(TestSupport.header(sent, "content-type") == "application/json")
        let expected = try TestSupport.json(#"""
        {"model":"claude-sonnet-5-5","max_tokens":32000,"stream":true,"system":"Regel\n\nStil",
         "messages":[{"role":"user","content":[{"type":"text","text":"Frage"}]}]}
        """#)
        #expect(try TestSupport.body(of: sent) == expected)
    }

    @Test("max_tokens: Wunsch der Anfrage, begrenzt durch das Modell")
    func maxTokens() async throws {
        let stub = StubTransport([.init(lines: textStream), .init(lines: textStream)])
        let provider = makeClaude(stub: stub)
        _ = try await TestSupport.collect(provider, TestSupport.request(maxOutputTokens: 2_000))
        _ = try await TestSupport.collect(provider, TestSupport.request(maxOutputTokens: 500_000))
        guard case .object(let first) = try TestSupport.body(of: stub.requests[0]),
              case .object(let second) = try TestSupport.body(of: stub.requests[1]) else { Issue.record("kein Objekt"); return }
        #expect(first["max_tokens"] == 2000)
        #expect(second["max_tokens"] == 64000)
    }

    @Test("Bild: base64-Block im Body, im Log nur ein Platzhalter; Key maskiert und nie im Log")
    func imageAndLog() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let message = ChatMessage(role: .user, content: [
            .text("Was steht da?"), .image(ImagePayload(data: TestSupport.pngBytes, mediaType: "image/png")),
        ])
        let (_, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request([message]))
        let expectedImage = try TestSupport.json(
            #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(TestSupport.pngBytes.base64EncodedString())"}}"#)
        let sent = try TestSupport.body(of: stub.requests[0])
        guard case .object(let object) = sent, case .array(let messages)? = object["messages"],
              case .object(let first) = messages[0], case .array(let content)? = first["content"] else {
            Issue.record("Body ohne Nachrichten"); return
        }
        #expect(content[1] == expectedImage)
        let raw = response.metadata.rawRequest
        #expect(!raw.contains(TestSupport.pngBytes.base64EncodedString()))
        #expect(raw.contains("<Bild, 10 Bytes>"))
        #expect(raw.contains("x-api-key: ***"))
        #expect(!raw.contains(TestSupport.secretKey))
        #expect(!response.metadata.rawResponse.contains(TestSupport.secretKey))
        #expect(response.metadata.sentContent == [.text, .image])
    }

    @Test("PDF: document-Block mit base64 im Body, im Log nur ein Platzhalter")
    func document() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let message = ChatMessage(role: .user, content: [
            .document(DocumentPayload(data: TestSupport.pdfBytes)), .text("Fasse zusammen."),
        ])
        let (_, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request([message]))
        let expectedBlock = try TestSupport.json(
            #"{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"\#(TestSupport.pdfBytes.base64EncodedString())"}}"#)
        guard case .object(let object) = try TestSupport.body(of: stub.requests[0]), case .array(let messages)? = object["messages"],
              case .object(let first) = messages[0], case .array(let content)? = first["content"] else {
            Issue.record("Body ohne Nachrichten"); return
        }
        #expect(content[0] == expectedBlock)
        let raw = response.metadata.rawRequest
        #expect(!raw.contains(TestSupport.pdfBytes.base64EncodedString()))
        #expect(raw.contains("<PDF, 10 Bytes>"))
        #expect(response.metadata.sentContent == [.text, .document])
    }

    @Test("Werkzeuge: tools mit input_schema, tool_choice nur auto; tool_use und tool_result in den Nachrichten")
    func tools() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let messages: [ChatMessage] = [
            .user("Suche"),
            ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "toolu_1", name: "search", arguments: #"{"query":"Zellen"}"#))]),
            ChatMessage(role: .user, content: [.toolResult(ToolResult(callID: "toolu_1", content: "Treffer", isError: true))]),
        ]
        _ = try await TestSupport.collect(
            makeClaude(stub: stub), TestSupport.request(messages, tools: [TestSupport.searchTool]))
        let expected = try TestSupport.json(#"""
        {"model":"claude-sonnet-5-5","max_tokens":32000,"stream":true,"system":"Regel\n\nStil",
         "tools":[{"name":"search","description":"Sucht im Lernstoff","input_schema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}],
         "tool_choice":{"type":"auto"},
         "messages":[
          {"role":"user","content":[{"type":"text","text":"Suche"}]},
          {"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"search","input":{"query":"Zellen"}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Treffer","is_error":true}]}]}
        """#)
        #expect(try TestSupport.body(of: stub.requests[0]) == expected)
    }

    @Test("Strukturierte Ausgabe: output_config.format json_schema (zusammen mit effort)")
    func structuredOutput() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        _ = try await TestSupport.collect(
            makeClaude(stub: stub), TestSupport.request(schema: TestSupport.answerSchema, reasoning: .medium))
        guard case .object(let object) = try TestSupport.body(of: stub.requests[0]) else { Issue.record("kein Objekt"); return }
        let expected = try TestSupport.json(
            #"{"effort":"medium","format":{"type":"json_schema","schema":{"type":"object","properties":{"text":{"type":"string"}}}}}"#)
        #expect(object["output_config"] == expected)
        #expect(object["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(object["tool_choice"] == nil)
    }
}

@Suite("Claude: Reasoning-Zuordnung")
struct ClaudeReasoningTests {
    private func plan(_ level: ReasoningLevel?, _ caps: ProviderCapabilities) -> ClaudeProvider.ReasoningPlan {
        ClaudeProvider.reasoningPlan(for: level, capabilities: caps)
    }

    @Test("Aus: thinking disabled, wenn das Modell es kann")
    func offDisabled() {
        let result = plan(.off, adaptiveCaps)
        #expect(result.thinking == ["type": "disabled"])
        #expect(result.effort == nil)
        #expect(result.sent == .off)
    }

    @Test("Aus: between_tools bei Modellen, die nur das anbieten")
    func offBetweenTools() {
        var caps = adaptiveCaps
        caps.reasoningOffMode = .betweenTools
        caps.reasoningLevels = [.off, .low, .medium, .high]
        #expect(plan(.off, caps).thinking == ["type": "between_tools"])
    }

    @Test("Aus nicht angeboten: thinking weglassen und niedrigste Stufe senden")
    func offNotOffered() {
        var caps = adaptiveCaps
        caps.reasoningLevels = [.medium, .high]
        let result = plan(.off, caps)
        #expect(result.thinking == nil)
        #expect(result.effort == "medium")
        #expect(result.sent == .medium)
    }

    @Test("Stufen: adaptive + effort; minimal wird zu low; nicht unterstützte Stufe fällt nach unten")
    func levels() {
        let adaptive: JSONValue = ["type": "adaptive", "display": "summarized"]
        for level in [ReasoningLevel.low, .medium, .high, .xhigh, .max] {
            let result = plan(level, adaptiveCaps)
            #expect(result.thinking == adaptive)
            #expect(result.effort == level.rawValue)
        }
        #expect(plan(.minimal, adaptiveCaps).effort == "low")
        var caps = adaptiveCaps
        caps.reasoningLevels = [.off, .low, .medium, .high]
        #expect(plan(.max, caps).effort == "high")
        #expect(plan(.max, caps).sent == .high)
    }

    @Test("nil und unbekannte Fähigkeiten: nichts senden")
    func nothing() {
        #expect(plan(nil, adaptiveCaps) == ClaudeProvider.ReasoningPlan())
        #expect(plan(.high, ProviderCapabilities()) == ClaudeProvider.ReasoningPlan())
        #expect(plan(.off, ProviderCapabilities()) == ClaudeProvider.ReasoningPlan())
    }

    @Test("Reasoning aus der Konfiguration landet im Body und in den Metadaten; Anfrage überschreibt")
    func configurationAndOverride() async throws {
        let stub = StubTransport([.init(lines: textStream), .init(lines: textStream)])
        let provider = makeClaude(stub: stub, reasoning: .high)
        let (_, first) = try await TestSupport.collect(provider, TestSupport.request())
        let (_, second) = try await TestSupport.collect(provider, TestSupport.request(reasoning: .off))
        guard case .object(let a) = try TestSupport.body(of: stub.requests[0]),
              case .object(let b) = try TestSupport.body(of: stub.requests[1]) else { Issue.record("kein Objekt"); return }
        #expect(a["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(a["output_config"] == ["effort": "high"])
        #expect(b["thinking"] == ["type": "disabled"])
        #expect(b["output_config"] == nil)
        #expect(first.metadata.reasoning == .high)
        #expect(second.metadata.reasoning == .off)
    }
}

@Suite("Claude: Stream")
struct ClaudeStreamTests {
    @Test("Ereignisreihenfolge, Text, Reasoning, Usage und Metadaten")
    func fullStream() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let (events, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request(reasoning: .high))
        #expect(events.count == 5)
        #expect(events[0] == .reasoningDelta("Ich "))
        #expect(events[1] == .reasoningDelta("überlege."))
        #expect(events[2] == .textDelta("Hallo"))
        #expect(events[3] == .textDelta(" Welt"))
        #expect(response.text == "Hallo Welt")
        let metadata = response.metadata
        #expect(metadata.providerKind == .claude)
        #expect(metadata.model == "claude-sonnet-5-5")
        #expect(metadata.reasoningText == "Ich überlege.")
        #expect(metadata.stopReason == .endTurn)
        #expect(metadata.usage == TokenUsage(
            inputTokens: 25, outputTokens: 42, cacheReadTokens: 300, cacheWriteTokens: 100, reasoningTokens: 7))
        #expect(metadata.learningUnitIDsInContext == ["lu-1"])
        #expect(metadata.duration > 0)
        #expect(metadata.timeToFirstToken != nil)
        #expect(metadata.rawResponse.contains("message_stop"))
    }

    @Test("Werkzeugaufruf: partial_json aus vielen Deltas wird zusammengesetzt und am Blockende gemeldet")
    func toolCallAccumulation() async throws {
        let pieces = ["", #"{"qu"#, #"ery": "Zel"#, #"len und "#, #"Kern"#, #""}"#]
        var events: [(String?, String)] = [
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":3}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ich suche."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"search","input":{}}}"#),
        ]
        for piece in pieces {
            let escaped = piece.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            events.append(("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(escaped)"}}"#))
        }
        events.append(("content_block_stop", #"{"type":"content_block_stop","index":1}"#))
        events.append(("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#))
        events.append(("message_stop", #"{"type":"message_stop"}"#))
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let (all, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request(tools: [TestSupport.searchTool]))
        let call = ToolCall(id: "toolu_9", name: "search", arguments: #"{"query": "Zellen und Kern"}"#)
        #expect(all.contains(.toolCall(call)))
        #expect(response.toolCalls == [call])
        #expect(response.metadata.stopReason == .toolUse)
        #expect(response.metadata.toolCalls == [call])
        #expect(response.metadata.usage.outputTokens == 9)
    }

    @Test("Stream an ungünstigen Stellen zerteilt: CRLF, Kommentare, event nach data, leere Deltas")
    func oddBoundaries() async throws {
        let lines = [
            ": Kommentar", "event: message_start\r",
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":4}}}"# + "\r", "\r",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Gr"}}"#, "event: content_block_delta", "",
            #"data:{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#, "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"üße ☀️"}}"#, "",
            "data: kein JSON", "",
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":2}}"#, "",
            #"data: {"type":"message_stop"}"#,  // last event without a blank line
        ]
        let stub = StubTransport([.init(lines: lines)])
        let (events, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request())
        #expect(TestSupport.textDeltas(events) == ["Gr", "üße ☀️"])
        #expect(response.text == "Grüße ☀️")
        #expect(response.metadata.stopReason == .maxTokens)
    }

    @Test("Verweigerung: stop_reason refusal mit Kategorie wird zu ProviderError.refused")
    func refusal() async {
        let events: [(String?, String)] = [
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":4}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}},"usage":{"output_tokens":0}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let error = await TestSupport.thrownError(makeClaude(stub: stub), TestSupport.request())
        #expect(error == .refused(category: "cyber"))
    }

    @Test("error-Ereignis mitten im Stream: überlastet, keine Wiederholung")
    func errorEventMidStream() async {
        let events: [(String?, String)] = [
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":4}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(events)), .init(lines: textStream)])
        var received: [ModelEvent] = []
        var thrown: ProviderError?
        do {
            for try await event in makeClaude(stub: stub).stream(TestSupport.request()) { received.append(event) }
        } catch { thrown = error.providerError }
        #expect(thrown == .overloaded)
        #expect(received == [.textDelta("Hal")])
        #expect(stub.requests.count == 1)
    }

    @Test("Stream ohne message_stop gilt als abgebrochen")
    func truncated() async {
        let stub = StubTransport([.init(lines: Array(textStream.prefix(12)))])
        let error = await TestSupport.thrownError(makeClaude(stub: stub), TestSupport.request())
        guard case .network? = error else { Issue.record("erwartet network, bekam \(String(describing: error))"); return }
    }
}

@Suite("Claude: Fehler und Wiederholung")
struct ClaudeErrorTests {
    private func errorBody(_ type: String, _ message: String = "Fehler") -> Data {
        Data(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8)
    }

    @Test("Ohne Key: missingAPIKey, es wird nichts gesendet")
    func missingKey() async {
        let stub = StubTransport([.init(lines: textStream)])
        let error = await TestSupport.thrownError(makeClaude(stub: stub, key: nil), TestSupport.request())
        #expect(error == .missingAPIKey)
        #expect(stub.requests.isEmpty)
    }

    @Test("401 wird zu invalidAPIKey und nicht wiederholt")
    func unauthorized() async {
        let stub = StubTransport([.init(status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"bad key"}}"#])])
        let error = await TestSupport.thrownError(makeClaude(stub: stub), TestSupport.request())
        #expect(error == .invalidAPIKey)
        #expect(stub.requests.count == 1)
    }

    @Test("429 mit retry-after wird wiederholt; danach Erfolg")
    func rateLimitedThenOK() async throws {
        let stub = StubTransport([
            .init(status: 429, headers: ["retry-after": "3"], lines: [#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#]),
            .init(lines: textStream),
        ])
        let (_, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request())
        #expect(response.text == "Hallo Welt")
        #expect(stub.requests.count == 2)
    }

    @Test("429 ohne Erfolg: rateLimited mit retry-after nach allen Versuchen")
    func rateLimitedGivesUp() async {
        let busy = StubTransport.Canned(status: 429, headers: ["Retry-After": "7"], lines: [#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#])
        let stub = StubTransport([busy, busy, busy])
        let error = await TestSupport.thrownError(makeClaude(stub: stub), TestSupport.request())
        #expect(error == .rateLimited(retryAfter: 7))
        #expect(stub.requests.count == 3)
    }

    @Test("529 wird zu overloaded, wiederholt, dann Erfolg")
    func overloadedThenOK() async throws {
        let stub = StubTransport([
            .init(status: 529, lines: [#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]),
            .init(lines: textStream),
        ])
        let (_, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request())
        #expect(response.text == "Hallo Welt")
        #expect(stub.requests.count == 2)
    }

    @Test("Verbindungsfehler vor dem ersten Byte werden wiederholt")
    func networkErrorRetried() async throws {
        let stub = StubTransport([.init(error: URLError(.notConnectedToInternet)), .init(lines: textStream)])
        let (_, response) = try await TestSupport.collect(makeClaude(stub: stub), TestSupport.request())
        #expect(response.text == "Hallo Welt")
        #expect(stub.requests.count == 2)
    }

    @Test("400 (z. B. unzulässiger Parameter) wird zu badRequest ohne Wiederholung")
    func badRequest() async {
        let stub = StubTransport([.init(status: 400, lines: [#"{"type":"error","error":{"type":"invalid_request_error","message":"temperature is not supported"}}"#])])
        let error = await TestSupport.thrownError(makeClaude(stub: stub), TestSupport.request())
        #expect(error == .badRequest("temperature is not supported"))
        #expect(stub.requests.count == 1)
    }
}

@Suite("Claude: Modellliste")
struct ClaudeCatalogTests {
    private let pageOne = #"""
    {"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000,
      "capabilities":{"image_input":{"supported":true},"structured_outputs":{"supported":true},
        "thinking":{"supported":true,"types":{"adaptive":{"supported":true},"between_tools":{"supported":false},"disabled":{"supported":true},"enabled":{"supported":false}}},
        "effort":{"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}}}}],
     "has_more":true,"last_id":"claude-opus-5-5"}
    """#
    private let pageTwo = #"""
    {"data":[{"id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","max_input_tokens":500000,"max_tokens":64000,
      "capabilities":{"image_input":{"supported":false},"structured_outputs":{"supported":false},
        "thinking":{"supported":true,"types":{"adaptive":{"supported":true},"between_tools":{"supported":true},"disabled":{"supported":false},"enabled":{"supported":false}}},
        "effort":{"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":false},"max":{"supported":false}}}},
      {"id":"claude-old","display_name":"Claude Old","capabilities":{"image_input":{"supported":true},
        "thinking":{"supported":true,"types":{"adaptive":{"supported":false},"enabled":{"supported":true}}}}}],
     "has_more":false,"last_id":"claude-old"}
    """#

    @Test("Paginierung über zwei Seiten (limit=100, after_id) und Zuordnung der Fähigkeiten")
    func pagination() async throws {
        let stub = StubTransport([.init(body: Data(pageOne.utf8)), .init(body: Data(pageTwo.utf8))])
        let models = try await makeClaude(stub: stub).availableModels()
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-old"])
        #expect(stub.requests.count == 2)
        #expect(stub.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100")
        #expect(stub.requests[1].url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100&after_id=claude-opus-5-5")
        #expect(TestSupport.header(stub.requests[0], "x-api-key") == TestSupport.secretKey)
        #expect(TestSupport.header(stub.requests[0], "anthropic-version") == "2026-10-21")

        let opus = models[0]
        #expect(opus.displayName == "Claude Opus 5.5")
        #expect(opus.capabilities.supportsImages)
        #expect(opus.capabilities.supportsStructuredOutput)
        #expect(opus.capabilities.supportsTools)
        #expect(opus.capabilities.reasoningLevels == [.off, .low, .medium, .high, .xhigh, .max])
        #expect(opus.capabilities.reasoningOffMode == .disabled)
        #expect(opus.capabilities.contextSize == 1_000_000)
        #expect(opus.capabilities.maxOutputTokens == 128_000)

        let sonnet = models[1]
        #expect(!sonnet.capabilities.supportsImages)
        #expect(sonnet.capabilities.reasoningLevels == [.off, .low, .medium, .high])
        #expect(sonnet.capabilities.reasoningOffMode == .betweenTools)

        let old = models[2]
        #expect(old.capabilities.reasoningLevels.isEmpty)
        #expect(old.capabilities.contextSize == nil)
    }

    @Test("Modellliste ohne Key und mit 401")
    func errors() async {
        let stub = StubTransport([.init(status: 401, body: Data(#"{"error":{"type":"authentication_error","message":"x"}}"#.utf8))])
        await #expect(throws: ProviderError.missingAPIKey) { _ = try await makeClaude(stub: stub, key: nil).availableModels() }
        await #expect(throws: ProviderError.invalidAPIKey) { _ = try await makeClaude(stub: stub).availableModels() }
    }
}
