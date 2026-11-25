import Foundation
import Testing

@testable import StudyAI

private let gptCaps = ProviderCapabilities(
    supportsImages: true, supportsTools: true, supportsStructuredOutput: true,
    reasoningLevels: [.off, .low, .medium, .high], defaultReasoning: .medium)

private func makeOpenAI(
    capabilities: ProviderCapabilities? = gptCaps, stub: StubTransport, key: String? = TestSupport.secretKey,
    model: String = "gpt-5.5", reasoning: ReasoningLevel? = nil
) -> OpenAIProvider {
    let configuration = TestSupport.configuration(.openAI, model: model, capabilities: capabilities, reasoning: reasoning)
    let clock = TestSupport.TickClock()
    return OpenAIProvider(
        configuration: configuration, keyStore: TestSupport.keyStore(for: configuration, key: key), transport: stub,
        retry: TestSupport.fastRetry, now: { clock.next() })
}

private let textStream: [String] = TestSupport.sse([
    (nil, #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#),
    (nil, #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"Ich prüfe "}"#),
    (nil, #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"die Frage."}"#),
    (nil, #"{"type":"response.output_text.delta","item_id":"msg_1","delta":"Hallo"}"#),
    (nil, #"{"type":"response.output_text.delta","item_id":"msg_1","delta":" Welt"}"#),
    (nil, #"{"type":"response.some_future_event","x":1}"#),
    (nil, #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":64},"output_tokens":80,"output_tokens_details":{"reasoning_tokens":30}}}}"#),
])

@Suite("OpenAI: Anfrage")
struct OpenAIRequestTests {
    @Test("Textanfrage: genauer JSON-Body und Header")
    func textRequest() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        _ = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request())
        let sent = try #require(stub.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(TestSupport.header(sent, "Authorization") == "Bearer \(TestSupport.secretKey)")
        let expected = try TestSupport.json(#"""
        {"model":"gpt-5.5","stream":true,"max_output_tokens":32000,"instructions":"Regel\n\nStil",
         "input":[{"role":"user","content":[{"type":"input_text","text":"Frage"}]}]}
        """#)
        #expect(try TestSupport.body(of: sent) == expected)
    }

    @Test("Bild als input_image mit Data-URL; Log ohne Bildbytes, Key maskiert")
    func image() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let message = ChatMessage(role: .user, content: [
            .text("Was steht da?"), .image(ImagePayload(data: TestSupport.pngBytes, mediaType: "image/png")),
        ])
        let (_, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request([message]))
        let dataURL = "data:image/png;base64,\(TestSupport.pngBytes.base64EncodedString())"
        let expected = try TestSupport.json(#"""
        {"model":"gpt-5.5","stream":true,"max_output_tokens":32000,"instructions":"Regel\n\nStil",
         "input":[{"role":"user","content":[{"type":"input_text","text":"Was steht da?"},{"type":"input_image","image_url":"\#(dataURL)"}]}]}
        """#)
        #expect(try TestSupport.body(of: stub.requests[0]) == expected)
        let raw = response.metadata.rawRequest
        #expect(!raw.contains(TestSupport.pngBytes.base64EncodedString()))
        #expect(raw.contains("<Bild, 10 Bytes>"))
        #expect(raw.contains("Authorization: ***"))
        #expect(!raw.contains(TestSupport.secretKey))
        #expect(!response.metadata.rawResponse.contains(TestSupport.secretKey))
    }

    @Test("Werkzeuge flach mit strict false; Aufrufe und Ergebnisse als function_call(_output)-Items")
    func tools() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let messages: [ChatMessage] = [
            .user("Suche"),
            ChatMessage(role: .assistant, content: [
                .text("Ich suche."), .toolCall(ToolCall(id: "call_1", name: "search", arguments: #"{"query":"Zellen"}"#)),
            ]),
            ChatMessage(role: .user, content: [.toolResult(ToolResult(callID: "call_1", content: "Treffer"))]),
        ]
        _ = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request(messages, tools: [TestSupport.searchTool]))
        let expected = try TestSupport.json(#"""
        {"model":"gpt-5.5","stream":true,"max_output_tokens":32000,"instructions":"Regel\n\nStil",
         "tools":[{"type":"function","name":"search","description":"Sucht im Lernstoff","strict":false,
                   "parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}],
         "input":[{"role":"user","content":[{"type":"input_text","text":"Suche"}]},
                  {"role":"assistant","content":"Ich suche."},
                  {"type":"function_call","call_id":"call_1","name":"search","arguments":"{\"query\":\"Zellen\"}"},
                  {"type":"function_call_output","call_id":"call_1","output":"Treffer"}]}
        """#)
        #expect(try TestSupport.body(of: stub.requests[0]) == expected)
    }

    @Test("Strukturierte Ausgabe: strict nur für Schemas, die die strict-Regeln erfüllen")
    func structuredStrict() async throws {
        let strict = ResponseSchema(name: "s", schema: [
            "type": "object", "additionalProperties": false, "required": ["a", "b"],
            "properties": [
                "a": ["type": "string"],
                "b": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false, "required": ["c"],
                    "properties": ["c": ["type": "number"]]]],
            ],
        ])
        #expect(OpenAIProvider.satisfiesStrictRules(strict.schema))
        // Nested object without additionalProperties:false, property missing from required, top level not closed.
        let nested: JSONValue = [
            "type": "object", "additionalProperties": false, "required": ["a"],
            "properties": ["a": ["type": "object", "required": ["c"], "properties": ["c": ["type": "string"]]]]]
        let missingRequired: JSONValue = [
            "type": "object", "additionalProperties": false, "required": ["a"],
            "properties": ["a": ["type": "string"], "b": ["type": "string"]]]
        for schema in [nested, missingRequired, TestSupport.answerSchema.schema] {
            #expect(!OpenAIProvider.satisfiesStrictRules(schema))
        }
        for (schema, expected) in [(strict, true), (ResponseSchema(name: "n", schema: nested), false)] {
            let stub = StubTransport([.init(lines: textStream)])
            _ = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request(schema: schema))
            guard case .object(let object) = try TestSupport.body(of: stub.requests[0]),
                  case .object(let text)? = object["text"], case .object(let format)? = text["format"]
            else { Issue.record("kein text.format"); return }
            #expect(format["strict"] == .bool(expected))
        }
    }

    @Test("Strukturierte Ausgabe: text.format json_schema mit bereinigtem Namen")
    func structured() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        _ = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request(schema: TestSupport.answerSchema))
        guard case .object(let object) = try TestSupport.body(of: stub.requests[0]) else { Issue.record("kein Objekt"); return }
        let expected = try TestSupport.json(#"""
        {"format":{"type":"json_schema","name":"answer_v1","strict":false,"description":"Antwort",
                   "schema":{"type":"object","properties":{"text":{"type":"string"}}}}}
        """#)
        #expect(object["text"] == expected)
    }

    @Test("max_output_tokens aus der Anfrage")
    func maxOutput() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        _ = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request(maxOutputTokens: 1234))
        guard case .object(let object) = try TestSupport.body(of: stub.requests[0]) else { Issue.record("kein Objekt"); return }
        #expect(object["max_output_tokens"] == 1234)
    }
}

@Suite("OpenAI: Reasoning-Zuordnung")
struct OpenAIReasoningTests {
    private func plan(_ level: ReasoningLevel?, _ caps: ProviderCapabilities) -> OpenAIProvider.ReasoningPlan {
        OpenAIProvider.reasoningPlan(for: level, capabilities: caps)
    }

    @Test("Stufen: effort und summary auto")
    func levels() {
        let result = plan(.high, gptCaps)
        #expect(result.value == ["effort": "high", "summary": "auto"])
        #expect(result.sent == .high)
    }

    @Test("Aus: none, wenn unterstützt, sonst die niedrigste unterstützte Stufe (wie bei Claude)")
    func off() {
        #expect(plan(.off, gptCaps).value == ["effort": "none"])
        var caps = gptCaps
        caps.reasoningLevels = [.low, .medium, .high]
        #expect(plan(.off, caps) == OpenAIProvider.ReasoningPlan(
            value: ["effort": "low", "summary": "auto"], sent: .low))
        caps.reasoningLevels = [.medium, .high, .xhigh]
        #expect(plan(.off, caps).sent == .medium)
        caps.reasoningLevels = []
        #expect(plan(.off, caps) == OpenAIProvider.ReasoningPlan())
    }

    @Test("nil, Modell ohne Stufen und nicht unterstützte Stufen")
    func fallbacks() {
        #expect(plan(nil, gptCaps) == OpenAIProvider.ReasoningPlan())
        #expect(plan(.high, ProviderCapabilities()) == OpenAIProvider.ReasoningPlan())
        #expect(plan(.max, gptCaps).sent == .high)
        #expect(plan(.minimal, gptCaps).sent == .low)
    }

    @Test("Body enthält reasoning nur bei gewählter Stufe")
    func inBody() async throws {
        let stub = StubTransport([.init(lines: textStream), .init(lines: textStream)])
        let provider = makeOpenAI(stub: stub)
        _ = try await TestSupport.collect(provider, TestSupport.request())
        let (_, response) = try await TestSupport.collect(provider, TestSupport.request(reasoning: .medium))
        guard case .object(let a) = try TestSupport.body(of: stub.requests[0]),
              case .object(let b) = try TestSupport.body(of: stub.requests[1]) else { Issue.record("kein Objekt"); return }
        #expect(a["reasoning"] == nil)
        #expect(b["reasoning"] == ["effort": "medium", "summary": "auto"])
        #expect(response.metadata.reasoning == .medium)
    }
}

@Suite("OpenAI: Stream")
struct OpenAIStreamTests {
    @Test("Reihenfolge, Text, Reasoning-Zusammenfassung, Usage mit Cache und Reasoning-Tokens")
    func fullStream() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let (events, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request(reasoning: .medium))
        #expect(Array(events.prefix(4)) == [
            .reasoningDelta("Ich prüfe "), .reasoningDelta("die Frage."), .textDelta("Hallo"), .textDelta(" Welt"),
        ])
        #expect(response.text == "Hallo Welt")
        let metadata = response.metadata
        #expect(metadata.providerKind == .openAI)
        #expect(metadata.reasoningText == "Ich prüfe die Frage.")
        #expect(metadata.usage == TokenUsage(inputTokens: 120, outputTokens: 80, cacheReadTokens: 64, reasoningTokens: 30))
        #expect(metadata.stopReason == .endTurn)
        #expect(metadata.duration > 0)
        #expect(metadata.timeToFirstToken != nil)
        #expect(metadata.rawResponse.contains("response.completed"))
    }

    @Test("Funktionsaufruf: Argumente aus vielen Deltas, call_id statt Item-ID")
    func toolCall() async throws {
        let item = #"{"type":"function_call","id":"fc_1","call_id":"call_77","name":"search","arguments":""}"#
        var events: [(String?, String)] = [
            (nil, #"{"type":"response.output_item.added","output_index":0,"item":\#(item)}"#),
        ]
        for piece in ["{\\\"qu", "ery\\\": \\\"Zel", "len\\\"", "}"] {
            events.append((nil, #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"\#(piece)"}"#))
        }
        events.append((nil, #"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"query\": \"Zellen\"}"}"#))
        events.append((nil, #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":6}}}"#))
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let (all, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request(tools: [TestSupport.searchTool]))
        let call = ToolCall(id: "call_77", name: "search", arguments: #"{"query": "Zellen"}"#)
        #expect(all.filter { if case .toolCall = $0 { return true } else { return false } } == [.toolCall(call)])
        #expect(response.metadata.stopReason == .toolUse)
        #expect(response.toolCalls == [call])
    }

    @Test("Funktionsaufruf ohne .done-Ereignis: Aufruf wird aus den Deltas am Ende geliefert")
    func toolCallWithoutDone() async throws {
        let events: [(String?, String)] = [
            (nil, #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"search"}}"#),
            (nil, #"{"type":"response.function_call_arguments.delta","item_id":"fc_2","delta":"{\"query\":\"x\"}"}"#),
            (nil, #"{"type":"response.completed","response":{"status":"completed"}}"#),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let (_, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request())
        #expect(response.toolCalls == [ToolCall(id: "call_2", name: "search", arguments: #"{"query":"x"}"#)])
    }

    @Test("Stream an ungünstigen Stellen zerteilt (CRLF, Kommentare, event-Zeilen)")
    func oddBoundaries() async throws {
        let lines = [
            ": keepalive", "event: response.output_text.delta\r",
            #"data: {"type":"response.output_text.delta","delta":"Grü"}"# + "\r", "\r",
            #"data:{"type":"response.output_text.delta","delta":"ße ☀️"}"#, "",
            "data: kein JSON", "",
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#,
        ]
        let stub = StubTransport([.init(lines: lines)])
        let (events, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request())
        #expect(TestSupport.textDeltas(events) == ["Grü", "ße ☀️"])
        #expect(response.text == "Grüße ☀️")
    }

    @Test("incomplete wegen max_output_tokens wird zu stopReason maxTokens")
    func incomplete() async throws {
        let events: [(String?, String)] = [
            (nil, #"{"type":"response.output_text.delta","delta":"Abge"}"#),
            (nil, #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":9,"output_tokens":100,"output_tokens_details":{"reasoning_tokens":100}}}}"#),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let (_, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request())
        #expect(response.metadata.stopReason == .maxTokens)
        #expect(response.metadata.usage.reasoningTokens == 100)
        #expect(response.text == "Abge")
    }

    @Test("response.failed und error-Ereignis werden zu ProviderError; keine Wiederholung")
    func failures() async {
        let failed: [(String?, String)] = [(nil, #"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_is_overloaded","message":"busy"}}}"#)]
        let stub1 = StubTransport([.init(lines: TestSupport.sse(failed)), .init(lines: textStream)])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub1), TestSupport.request()) == .overloaded)
        #expect(stub1.requests.count == 1)

        let errorEvent: [(String?, String)] = [
            (nil, #"{"type":"response.output_text.delta","delta":"A"}"#),
            ("error", #"{"type":"error","code":"rate_limit_exceeded","message":"slow","param":null}"#),
        ]
        let stub2 = StubTransport([.init(lines: TestSupport.sse(errorEvent)), .init(lines: textStream)])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub2), TestSupport.request()) == .rateLimited(retryAfter: nil))
        #expect(stub2.requests.count == 1)

        let quota: [(String?, String)] = [(nil, #"{"type":"response.failed","response":{"error":{"code":"insufficient_quota","message":"no credit"}}}"#)]
        let stub3 = StubTransport([.init(lines: TestSupport.sse(quota))])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub3), TestSupport.request()) == .quotaExceeded("no credit"))
    }

    @Test("Stream ohne response.completed gilt als abgebrochen")
    func truncated() async {
        let stub = StubTransport([.init(lines: Array(textStream.prefix(8)))])
        guard case .network? = await TestSupport.thrownError(makeOpenAI(stub: stub), TestSupport.request()) else {
            Issue.record("erwartet network"); return
        }
    }
}

@Suite("OpenAI: Fehler und Wiederholung")
struct OpenAIErrorTests {
    @Test("Ohne Key: missingAPIKey ohne Anfrage")
    func missingKey() async {
        let stub = StubTransport([.init(lines: textStream)])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub, key: nil), TestSupport.request()) == .missingAPIKey)
        #expect(stub.requests.isEmpty)
    }

    @Test("401 wird zu invalidAPIKey")
    func unauthorized() async {
        let stub = StubTransport([.init(status: 401, lines: [#"{"error":{"message":"bad","type":"invalid_request_error","code":"invalid_api_key"}}"#])])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub), TestSupport.request()) == .invalidAPIKey)
        #expect(stub.requests.count == 1)
    }

    @Test("429 mit Retry-After: wiederholt, dann Erfolg")
    func rateLimited() async throws {
        let stub = StubTransport([
            .init(status: 429, headers: ["Retry-After": "2"], lines: [#"{"error":{"message":"slow","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#]),
            .init(lines: textStream),
        ])
        let (_, response) = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request())
        #expect(response.text == "Hallo Welt")
        #expect(stub.requests.count == 2)
    }

    @Test("429 mit erschöpftem Guthaben wird nicht wiederholt")
    func quota() async {
        let stub = StubTransport([.init(status: 429, lines: [#"{"error":{"message":"no credit","type":"x","code":"credit_balance_exhausted"}}"#])])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub), TestSupport.request()) == .quotaExceeded("no credit"))
        #expect(stub.requests.count == 1)
    }

    @Test("503 wird zu overloaded und wiederholt")
    func overloaded() async throws {
        let stub = StubTransport([
            .init(status: 503, lines: [#"{"error":{"message":"busy","type":"server_error","code":"server_is_overloaded"}}"#]),
            .init(lines: textStream),
        ])
        _ = try await TestSupport.collect(makeOpenAI(stub: stub), TestSupport.request())
        #expect(stub.requests.count == 2)
    }

    @Test("500 bleibt nach allen Versuchen ein Serverfehler")
    func serverError() async {
        let boom = StubTransport.Canned(status: 500, lines: [#"{"error":{"message":"boom"}}"#])
        let stub = StubTransport([boom, boom, boom])
        #expect(await TestSupport.thrownError(makeOpenAI(stub: stub), TestSupport.request()) == .server(status: 500, message: "boom"))
        #expect(stub.requests.count == 3)
    }
}

@Suite("OpenAI: Modellliste und Tabelle")
struct OpenAICatalogTests {
    private let list = #"""
    {"object":"list","data":[
      {"id":"gpt-6.2-sol","created":1,"owned_by":"openai"},{"id":"text-embedding-4-large","created":1,"owned_by":"openai"},
      {"id":"whisper-2","created":1,"owned_by":"openai"},{"id":"gpt-6-luna","created":1,"owned_by":"openai"},
      {"id":"dall-e-4","created":1,"owned_by":"openai"},{"id":"gpt-6.1-sol","created":1,"owned_by":"openai"},
      {"id":"gpt-5.5-tts","created":1,"owned_by":"openai"},{"id":"mystery-chat-1","created":1,"owned_by":"openai"},
      {"id":"omni-moderation-latest","created":1,"owned_by":"openai"}]}
    """#

    @Test("Liste: Nicht-Chat-Modelle gefiltert, Fähigkeiten aus der Tabelle, sortiert, Bearer-Header")
    func modelList() async throws {
        let stub = StubTransport([.init(body: Data(list.utf8))])
        let models = try await makeOpenAI(stub: stub).availableModels()
        #expect(models.map(\.id) == ["gpt-6-luna", "gpt-6.1-sol", "gpt-6.2-sol", "mystery-chat-1"])
        #expect(stub.requests[0].url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(TestSupport.header(stub.requests[0], "Authorization") == "Bearer \(TestSupport.secretKey)")
        let luna = models[0].capabilities
        #expect(luna.defaultReasoning == .medium)
        #expect(luna.supportsImages)
        let mystery = models[3].capabilities
        #expect(mystery.reasoningLevels.isEmpty)
        #expect(!mystery.supportsImages)
    }

    @Test("Tabelle: GPT-6.x-Besonderheiten aus der Referenz")
    func tableFacts() {
        for id in ["gpt-6-astra", "gpt-6.2-astra", "gpt-6.2-sol", "gpt-6.1-sol"] {
            #expect(!OpenAIModelTable.capabilities(for: id).reasoningLevels.contains(.off), "\(id) darf kein none haben")
        }
        for id in ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-5.5"] {
            #expect(OpenAIModelTable.capabilities(for: id).defaultReasoning == .medium, "\(id) Standard medium")
        }
        #expect(!OpenAIModelTable.capabilities(for: "gpt-6.1-sol").reasoningLevels.contains(.minimal))
        // Longest prefix wins: a dated snapshot of 6.1 Sol is not treated as the generic gpt-6 family.
        #expect(OpenAIModelTable.capabilities(for: "gpt-6.1-sol-2026-11-01").defaultReasoning == .medium)
        #expect(OpenAIModelTable.capabilities(for: "gpt-6-unbekannt").reasoningLevels == [.low, .medium, .high])
    }

    @Test("Tabelle: unbekannte Modelle ohne Stufen; Nicht-Chat-Präfixe")
    func unknown() {
        #expect(OpenAIModelTable.capabilities(for: "irgendwas").reasoningLevels.isEmpty)
        for id in ["text-embedding-3-small", "tts-1", "whisper-1", "dall-e-3", "gpt-image-1", "omni-moderation-latest",
                   "gpt-4o-transcribe", "gpt-realtime-mini"] {
            #expect(!OpenAIModelTable.isChatModel(id), "\(id)")
        }
        #expect(OpenAIModelTable.isChatModel("gpt-6-luna"))
    }

    @Test("Ohne zwischengespeicherte Fähigkeiten nutzt die Fabrik die Tabelle; Bild-Einstellung gewinnt")
    func factoryCapabilities() {
        let configuration = TestSupport.configuration(.openAI, model: "mystery-chat-1", imageOverride: true)
        #expect(ProviderFactory.capabilities(of: configuration).supportsImages)
        let known = TestSupport.configuration(.openAI, model: "gpt-6-luna", imageOverride: false)
        let capabilities = ProviderFactory.capabilities(of: known)
        #expect(!capabilities.supportsImages)
        #expect(capabilities.reasoningLevels.contains(.low))
    }
}
