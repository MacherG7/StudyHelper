import Foundation
import Testing

@testable import StudyAI

private let ollamaCaps = ProviderCapabilities(
    supportsImages: true, supportsTools: true, reasoningLevels: [.off, .low, .medium, .high])

private func makeCompatible(
    capabilities: ProviderCapabilities? = ollamaCaps, stub: StubTransport, key: String? = nil,
    baseURL: String? = "http://192.168.1.20:11434", reasoning: ReasoningLevel? = nil
) -> OpenAICompatibleProvider {
    let configuration = TestSupport.configuration(
        .openAICompatible, model: "qwen3:8b", baseURL: baseURL, capabilities: capabilities, reasoning: reasoning)
    let clock = TestSupport.TickClock()
    return OpenAICompatibleProvider(
        configuration: configuration, keyStore: TestSupport.keyStore(for: configuration, key: key), transport: stub,
        retry: TestSupport.fastRetry, now: { clock.next() })
}

private func chunk(_ json: String) -> (String?, String) { (nil, json) }

private let textStream: [String] = TestSupport.sse([
    chunk(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#),
    chunk(#"{"choices":[{"index":0,"delta":{"reasoning_content":"Ich denke "},"finish_reason":null}]}"#),
    chunk(#"{"choices":[{"index":0,"delta":{"reasoning":"nach."},"finish_reason":null}]}"#),
    chunk(#"{"choices":[{"index":0,"delta":{"content":"Hallo"},"finish_reason":null}]}"#),
    chunk(#"{"choices":[{"index":0,"delta":{"content":" Welt"},"finish_reason":null}]}"#),
    chunk(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
    chunk(#"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":10},"completion_tokens_details":{"reasoning_tokens":4}}}"#),
    (nil, "[DONE]"),
])

@Suite("OpenAI-kompatibel: Anfrage")
struct CompatibleRequestTests {
    @Test("Textanfrage: genauer JSON-Body; ohne Key kein Authorization-Header")
    func textRequest() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        _ = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request())
        let sent = try #require(stub.requests.first)
        #expect(sent.url?.absoluteString == "http://192.168.1.20:11434/v1/chat/completions")
        #expect(TestSupport.header(sent, "Authorization") == nil)
        let expected = try TestSupport.json(#"""
        {"model":"qwen3:8b","stream":true,"stream_options":{"include_usage":true},
         "messages":[{"role":"system","content":"Regel\n\nStil"},{"role":"user","content":"Frage"}]}
        """#)
        #expect(try TestSupport.body(of: sent) == expected)
    }

    @Test("Mit Key: Bearer-Header, im Log maskiert und nie im Log")
    func withKey() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let (_, response) = try await TestSupport.collect(
            makeCompatible(stub: stub, key: TestSupport.secretKey), TestSupport.request())
        #expect(TestSupport.header(stub.requests[0], "Authorization") == "Bearer \(TestSupport.secretKey)")
        #expect(response.metadata.rawRequest.contains("Authorization: ***"))
        #expect(!response.metadata.rawRequest.contains(TestSupport.secretKey))
        #expect(!response.metadata.rawResponse.contains(TestSupport.secretKey))
    }

    @Test("Bild als image_url mit Data-URL; Log mit Platzhalter")
    func image() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let message = ChatMessage(role: .user, content: [
            .text("Was steht da?"), .image(ImagePayload(data: TestSupport.pngBytes, mediaType: "image/png")),
        ])
        let (_, response) = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request([message]))
        let dataURL = "data:image/png;base64,\(TestSupport.pngBytes.base64EncodedString())"
        let expected = try TestSupport.json(#"""
        {"model":"qwen3:8b","stream":true,"stream_options":{"include_usage":true},
         "messages":[{"role":"system","content":"Regel\n\nStil"},
                     {"role":"user","content":[{"type":"text","text":"Was steht da?"},{"type":"image_url","image_url":{"url":"\#(dataURL)"}}]}]}
        """#)
        #expect(try TestSupport.body(of: stub.requests[0]) == expected)
        #expect(!response.metadata.rawRequest.contains(TestSupport.pngBytes.base64EncodedString()))
        #expect(response.metadata.rawRequest.contains("<Bild, 10 Bytes>"))
    }

    @Test("Werkzeuge im Chat-Format ohne tool_choice; Aufrufe und Ergebnisse als assistant/tool-Nachrichten")
    func tools() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let messages: [ChatMessage] = [
            .user("Suche"),
            ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "call_1", name: "search", arguments: #"{"query":"Zellen"}"#))]),
            ChatMessage(role: .user, content: [.toolResult(ToolResult(callID: "call_1", content: "Treffer"))]),
        ]
        _ = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request(messages, tools: [TestSupport.searchTool], maxOutputTokens: 500))
        let expected = try TestSupport.json(#"""
        {"model":"qwen3:8b","stream":true,"stream_options":{"include_usage":true},"max_tokens":500,
         "tools":[{"type":"function","function":{"name":"search","description":"Sucht im Lernstoff",
                   "parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}],
         "messages":[{"role":"system","content":"Regel\n\nStil"},
                     {"role":"user","content":"Suche"},
                     {"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"Zellen\"}"}}]},
                     {"role":"tool","tool_call_id":"call_1","content":"Treffer"}]}
        """#)
        #expect(try TestSupport.body(of: stub.requests[0]) == expected)
    }

    @Test("reasoning_effort: Stufen, off als none, minimal zu low, xhigh zu high; ohne Stufen nichts")
    func reasoning() async throws {
        let plan = { (level: ReasoningLevel?, caps: ProviderCapabilities) in
            OpenAICompatibleProvider.reasoningPlan(for: level, capabilities: caps)
        }
        #expect(plan(.medium, ollamaCaps).effort == "medium")
        #expect(plan(.off, ollamaCaps).effort == "none")
        #expect(plan(.minimal, ollamaCaps).effort == "low")
        #expect(plan(.xhigh, ollamaCaps).effort == "high")
        #expect(plan(nil, ollamaCaps).effort == nil)
        #expect(plan(.high, ProviderCapabilities(supportsImages: true)).effort == nil)

        let stub = StubTransport([.init(lines: textStream)])
        let (_, response) = try await TestSupport.collect(makeCompatible(stub: stub, reasoning: .low), TestSupport.request())
        guard case .object(let object) = try TestSupport.body(of: stub.requests[0]) else { Issue.record("kein Objekt"); return }
        #expect(object["reasoning_effort"] == "low")
        #expect(response.metadata.reasoning == .low)
    }

    @Test("Serveradresse: http im LAN erlaubt, /v1-Suffix und Schrägstrich toleriert, ungültige Adressen abgelehnt")
    func baseURL() async throws {
        for base in ["http://localhost:1234/v1", "http://localhost:1234/", "http://localhost:1234"] {
            let stub = StubTransport([.init(lines: textStream)])
            _ = try await TestSupport.collect(makeCompatible(stub: stub, baseURL: base), TestSupport.request())
            #expect(stub.requests[0].url?.absoluteString == "http://localhost:1234/v1/chat/completions", "\(base)")
        }
        for bad in [nil, "", "ftp://host", "nur-ein-name", "http://"] {
            let stub = StubTransport([.init(lines: textStream)])
            #expect(await TestSupport.thrownError(makeCompatible(stub: stub, baseURL: bad), TestSupport.request()) != nil, "\(bad ?? "nil")")
            #expect(stub.requests.isEmpty)
        }
    }
}

@Suite("OpenAI-kompatibel: Stream")
struct CompatibleStreamTests {
    @Test("Text, Reasoning (reasoning_content und reasoning), Usage-Chunk und [DONE]")
    func fullStream() async throws {
        let stub = StubTransport([.init(lines: textStream)])
        let (events, response) = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request())
        #expect(Array(events.prefix(4)) == [
            .reasoningDelta("Ich denke "), .reasoningDelta("nach."), .textDelta("Hallo"), .textDelta(" Welt"),
        ])
        #expect(response.text == "Hallo Welt")
        let metadata = response.metadata
        #expect(metadata.providerKind == .openAICompatible)
        #expect(metadata.reasoningText == "Ich denke nach.")
        #expect(metadata.stopReason == .endTurn)
        #expect(metadata.usage == TokenUsage(inputTokens: 50, outputTokens: 20, cacheReadTokens: 10, reasoningTokens: 4))
        #expect(metadata.rawResponse.hasSuffix("[DONE]"))
        #expect(metadata.duration > 0)
    }

    @Test("Werkzeugaufrufe: Argumente und Namen aus vielen Deltas, mehrere Aufrufe nach Index")
    func toolCalls() async throws {
        let events: [(String?, String)] = [
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"sea","arguments":""}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"rch","arguments":"{\"que"}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"search","arguments":"{\"query\":\"B\"}"}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"A"}}]}}]}"#),
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"}"}}]},"finish_reason":"tool_calls"}]}"#),
            chunk(#"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":6}}"#),
            (nil, "[DONE]"),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let (_, response) = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request(tools: [TestSupport.searchTool]))
        #expect(response.toolCalls == [
            ToolCall(id: "call_a", name: "search", arguments: #"{"query":"A"}"#),
            ToolCall(id: "call_b", name: "search", arguments: #"{"query":"B"}"#),
        ])
        #expect(response.metadata.stopReason == .toolUse)
        #expect(response.metadata.usage.inputTokens == 5)
    }

    @Test("Werkzeugaufruf ohne id (manche Server): id wird erzeugt, leere Argumente werden {}")
    func toolCallWithoutID() async throws {
        let events: [(String?, String)] = [
            chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"search"}}]},"finish_reason":"tool_calls"}]}"#),
            (nil, "[DONE]"),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(events))])
        let (_, response) = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request())
        #expect(response.toolCalls == [ToolCall(id: "call_0", name: "search", arguments: "{}")])
    }

    @Test("Zerteilte Zeilen (CRLF, Kommentare, ungültiges JSON) und finish_reason length")
    func oddBoundaries() async throws {
        let lines = [
            ": ping", #"data: {"choices":[{"delta":{"content":"Grü"}}]}"# + "\r", "\r",
            "data: nope", "",
            #"data:{"choices":[{"delta":{"content":"ße ☀️"},"finish_reason":"length"}]}"#, "",
            "data: [DONE]",
        ]
        let stub = StubTransport([.init(lines: lines)])
        let (events, response) = try await TestSupport.collect(makeCompatible(stub: stub), TestSupport.request())
        #expect(TestSupport.textDeltas(events) == ["Grü", "ße ☀️"])
        #expect(response.metadata.stopReason == .maxTokens)
    }

    @Test("Fehlerobjekt im Stream wird zu ProviderError; Abbruch ohne [DONE] gilt als Verbindungsfehler")
    func failures() async {
        let errorStream: [(String?, String)] = [
            chunk(#"{"choices":[{"delta":{"content":"A"}}]}"#),
            chunk(#"{"error":{"message":"model crashed","type":"server_error"}}"#),
        ]
        let stub = StubTransport([.init(lines: TestSupport.sse(errorStream)), .init(lines: textStream)])
        #expect(await TestSupport.thrownError(makeCompatible(stub: stub), TestSupport.request()) == .server(status: 500, message: "model crashed"))
        #expect(stub.requests.count == 1)

        let cut = StubTransport([.init(lines: TestSupport.sse([chunk(#"{"choices":[{"delta":{"content":"A"}}]}"#)]))])
        guard case .network? = await TestSupport.thrownError(makeCompatible(stub: cut), TestSupport.request()) else {
            Issue.record("erwartet network"); return
        }
    }

    @Test("HTTP 401, 404, 503: Zuordnung; 503 wird wiederholt")
    func httpErrors() async throws {
        let unauthorized = StubTransport([.init(status: 401, lines: [#"{"error":{"message":"no"}}"#])])
        #expect(await TestSupport.thrownError(makeCompatible(stub: unauthorized), TestSupport.request()) == .invalidAPIKey)
        let missing = StubTransport([.init(status: 404, lines: [#"{"error":{"message":"model not found"}}"#])])
        #expect(await TestSupport.thrownError(makeCompatible(stub: missing), TestSupport.request()) == .modelNotFound("qwen3:8b"))
        let busy = StubTransport([.init(status: 503, lines: ["busy"]), .init(lines: textStream)])
        _ = try await TestSupport.collect(makeCompatible(stub: busy), TestSupport.request())
        #expect(busy.requests.count == 2)
    }
}

@Suite("OpenAI-kompatibel: Modellliste")
struct CompatibleCatalogTests {
    private let models = Data(#"{"object":"list","data":[{"id":"llama3.2-vision:11b"},{"id":"qwen3:8b"},{"id":"nomic-embed-text"}]}"#.utf8)
    private let tags = Data(#"{"models":[{"name":"llama3.2-vision:11b","model":"llama3.2-vision:11b","size":1,"details":{}}]}"#.utf8)

    @Test("Ollama: /api/tags erkannt, Fähigkeiten aus /api/show, Embedding-Modell entfällt")
    func ollama() async throws {
        let stub = StubTransport([
            .init(body: models), .init(body: tags),
            .init(body: Data(#"{"capabilities":["completion","vision","tools"]}"#.utf8)),
            .init(body: Data(#"{"capabilities":["completion","thinking","tools"]}"#.utf8)),
            .init(body: Data(#"{"capabilities":["embedding"]}"#.utf8)),
        ])
        let result = try await makeCompatible(stub: stub).availableModels()
        #expect(result.map(\.id) == ["llama3.2-vision:11b", "qwen3:8b"])
        #expect(result[0].capabilities.supportsImages)
        #expect(result[0].capabilities.supportsTools)
        #expect(result[0].capabilities.reasoningLevels.isEmpty)
        #expect(!result[1].capabilities.supportsImages)
        #expect(result[1].capabilities.reasoningLevels == [.off, .low, .medium, .high])

        let urls = stub.requests.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" }
        #expect(urls == [
            "GET http://192.168.1.20:11434/v1/models", "GET http://192.168.1.20:11434/api/tags",
            "POST http://192.168.1.20:11434/api/show", "POST http://192.168.1.20:11434/api/show",
            "POST http://192.168.1.20:11434/api/show",
        ])
        #expect(try TestSupport.body(of: stub.requests[2]) == ["model": "llama3.2-vision:11b"])
        #expect(try TestSupport.body(of: stub.requests[3]) == ["model": "qwen3:8b"])
    }

    @Test("Ollama: eigene thinking.values begrenzen die Stufen; fehlgeschlagenes /api/show gibt Standardwerte")
    func ollamaValuesAndFailure() async throws {
        let stub = StubTransport([
            .init(body: Data(#"{"data":[{"id":"gpt-oss:20b"},{"id":"broken:1b"}]}"#.utf8)), .init(body: tags),
            .init(body: Data(#"{"capabilities":["completion","thinking"],"thinking":{"values":["low","medium","high"]}}"#.utf8)),
            .init(status: 500, body: Data("boom".utf8)),
        ])
        let result = try await makeCompatible(stub: stub).availableModels()
        #expect(result.map(\.id) == ["gpt-oss:20b", "broken:1b"])
        #expect(result[0].capabilities.reasoningLevels == [.low, .medium, .high])
        #expect(result[1].capabilities.reasoningLevels.isEmpty)
        #expect(!result[1].capabilities.supportsImages)
    }

    @Test("Anderer Server: kein /api/tags, Fähigkeiten unbekannt (keine Bilder, keine Stufen), kein /api/show")
    func otherServer() async throws {
        let stub = StubTransport([.init(body: models), .init(status: 404, body: Data("not found".utf8))])
        let result = try await makeCompatible(stub: stub, baseURL: "http://localhost:1234").availableModels()
        #expect(result.map(\.id) == ["llama3.2-vision:11b", "qwen3:8b", "nomic-embed-text"])
        #expect(result.allSatisfy { $0.capabilities.reasoningLevels.isEmpty && !$0.capabilities.supportsImages })
        #expect(stub.requests.count == 2)
    }

    @Test("Bild-Einstellung des Nutzers wirkt auf die Fähigkeiten der Konfiguration")
    func imageOverride() {
        let configuration = TestSupport.configuration(.openAICompatible, baseURL: "http://x", imageOverride: true)
        #expect(ProviderFactory.capabilities(of: configuration).supportsImages)
    }

    @Test("Modellliste mit Fehler des Servers wird gemeldet")
    func listError() async {
        let stub = StubTransport([.init(status: 401, body: Data(#"{"error":{"message":"no"}}"#.utf8))])
        await #expect(throws: ProviderError.invalidAPIKey) { _ = try await makeCompatible(stub: stub).availableModels() }
    }
}
