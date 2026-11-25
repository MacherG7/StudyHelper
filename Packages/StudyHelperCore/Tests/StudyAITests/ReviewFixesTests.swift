import Foundation
import Security
import StudyCore
import Testing

@testable import StudyAI

// Tests for the Phase-2 review findings: reasoning continuity, failure metadata, image guard, retry cap, URL
// redaction, lenient settings, key listing. Everything runs on stubs; no network, no real Keychain.

private let claudeCaps = ProviderCapabilities(
    supportsImages: true, supportsTools: true, supportsStructuredOutput: true,
    reasoningLevels: [.off, .low, .medium, .high], reasoningOffMode: .disabled)
private let gptCaps = ProviderCapabilities(
    supportsImages: true, supportsTools: true, supportsStructuredOutput: true,
    reasoningLevels: [.off, .low, .medium, .high])

private func makeClaude(
    capabilities: ProviderCapabilities? = claudeCaps, stub: StubTransport, key: String? = TestSupport.secretKey,
    imageOverride: Bool? = nil, retry: RetryPolicy = TestSupport.fastRetry
) -> ClaudeProvider {
    let configuration = TestSupport.configuration(
        .claude, model: "claude-sonnet-5-5", capabilities: capabilities, imageOverride: imageOverride)
    let clock = TestSupport.TickClock()
    return ClaudeProvider(
        configuration: configuration, keyStore: TestSupport.keyStore(for: configuration, key: key), transport: stub,
        retry: retry, now: { clock.next() })
}

private func makeOpenAI(capabilities: ProviderCapabilities? = gptCaps, stub: StubTransport) -> OpenAIProvider {
    let configuration = TestSupport.configuration(.openAI, model: "gpt-5.5", capabilities: capabilities)
    let clock = TestSupport.TickClock()
    return OpenAIProvider(
        configuration: configuration, keyStore: TestSupport.keyStore(for: configuration), transport: stub,
        retry: TestSupport.fastRetry, now: { clock.next() })
}

private let image = ChatMessage(role: .user, content: [
    .text("Was steht da?"), .image(ImagePayload(data: TestSupport.pngBytes, mediaType: "image/png")),
])

// MARK: - 1. Reasoning continuity

@Suite("Reasoning in Werkzeug-Schleifen")
struct ReasoningContinuityTests {
    private let claudeToolStream = TestSupport.sse([
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Ich suche."}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"xyz"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"VERSCHLUESSELT"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Moment."}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        ("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_1","name":"search","input":{}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"Zellen\"}"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":3}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])

    @Test("Claude: Thinking-Blöcke mit Signatur und redacted thinking werden gesammelt und unverändert zurückgesendet")
    func claudeRoundTrip() async throws {
        let stub = StubTransport([.init(lines: claudeToolStream), .init(lines: TestSupport.sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":5}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]))])
        let provider = makeClaude(stub: stub)
        let (_, first) = try await TestSupport.collect(
            provider, TestSupport.request(tools: [TestSupport.searchTool], reasoning: .high))
        let thinking = ReasoningBlock(
            provider: .claude, payload: ["type": "thinking", "thinking": "Ich suche.", "signature": "sig-xyz"])
        let redacted = ReasoningBlock(
            provider: .claude, payload: ["type": "redacted_thinking", "data": "VERSCHLUESSELT"])
        #expect(first.reasoningBlocks == [thinking, redacted])
        let call = ToolCall(id: "toolu_1", name: "search", arguments: #"{"query":"Zellen"}"#)
        #expect(first.assistantContent == [.reasoning(thinking), .reasoning(redacted), .text("Moment."), .toolCall(call)])

        let followUp = [
            ChatMessage.user("Suche"),
            ChatMessage(role: .assistant, content: first.assistantContent),
            ChatMessage(role: .user, content: [.toolResult(ToolResult(callID: "toolu_1", content: "Treffer"))]),
        ]
        _ = try await TestSupport.collect(provider, TestSupport.request(followUp, tools: [TestSupport.searchTool]))
        let expected = try TestSupport.json(#"""
        {"role":"assistant","content":[
          {"type":"thinking","thinking":"Ich suche.","signature":"sig-xyz"},
          {"type":"redacted_thinking","data":"VERSCHLUESSELT"},
          {"type":"text","text":"Moment."},
          {"type":"tool_use","id":"toolu_1","name":"search","input":{"query":"Zellen"}}]}
        """#)
        guard case .object(let body) = try TestSupport.body(of: stub.requests[1]),
              case .array(let messages)? = body["messages"] else { Issue.record("kein Body"); return }
        #expect(messages[1] == expected)
    }

    @Test("OpenAI: reasoning-Items werden gesammelt (ohne Doppelte) und vor den function_call-Items zurückgesendet")
    func openAIRoundTrip() async throws {
        let item = #"{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Plan"}]}"#
        let stream = TestSupport.sse([
            (nil, #"{"type":"response.output_item.added","item":{"id":"rs_1","type":"reasoning","summary":[]}}"#),
            (nil, #"{"type":"response.output_item.done","item":\#(item)}"#),
            (nil, #"{"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"search","arguments":""}}"#),
            (nil, #"{"type":"response.function_call_arguments.done","item_id":"fc_1","arguments":"{\"query\":\"Zellen\"}"}"#),
            (nil, #"{"type":"response.completed","response":{"status":"completed","output":[\#(item)],"usage":{"input_tokens":5,"output_tokens":3}}}"#),
        ])
        let stub = StubTransport([.init(lines: stream), .init(lines: stream)])
        let provider = makeOpenAI(stub: stub)
        let (_, first) = try await TestSupport.collect(provider, TestSupport.request(tools: [TestSupport.searchTool]))
        let block = ReasoningBlock(provider: .openAI, payload: try TestSupport.json(item))
        #expect(first.reasoningBlocks == [block])
        #expect(first.assistantContent.map { if case .reasoning = $0 { "r" } else { "x" } } == ["r", "x"])

        let followUp = [
            ChatMessage.user("Suche"),
            ChatMessage(role: .assistant, content: first.assistantContent),
            ChatMessage(role: .user, content: [.toolResult(ToolResult(callID: "call_1", content: "Treffer"))]),
        ]
        _ = try await TestSupport.collect(provider, TestSupport.request(followUp, tools: [TestSupport.searchTool]))
        guard case .object(let body) = try TestSupport.body(of: stub.requests[1]),
              case .array(let input)? = body["input"] else { Issue.record("kein Body"); return }
        let types = input.map { item -> String in
            guard case .object(let object) = item else { return "?" }
            if case .string(let type)? = object["type"] { return type }
            return "message"
        }
        #expect(types == ["message", "reasoning", "function_call", "function_call_output"])
        #expect(input[1] == block.payload)
    }

    @Test("Leere Textteile werden nicht als null-Block gesendet")
    func emptyTextIsDropped() {
        let messages = ClaudeProvider.messages(
            [ChatMessage(role: .assistant, content: [.text(""), .text("A")])], redactImages: false)
        #expect(messages == [["role": "assistant", "content": [["type": "text", "text": "A"]]]])
    }

    @Test("Jeder Anbieter sendet nur eigene Reasoning-Blöcke; OpenAI-kompatibel sendet keine")
    func othersIgnoreReasoning() {
        let claudeBlock = ReasoningBlock(provider: .claude, payload: ["type": "thinking", "thinking": "x", "signature": "s"])
        let openAIBlock = ReasoningBlock(provider: .openAI, payload: ["id": "rs_1", "type": "reasoning"])
        let assistant = ChatMessage(role: .assistant, content: [.reasoning(claudeBlock), .reasoning(openAIBlock), .text("A")])
        let request = TestSupport.request([.user("F"), assistant])
        let compatible = OpenAICompatibleProvider.messages(request, redactImages: false)
        #expect(!String(describing: compatible).contains("thinking"))
        #expect(!String(describing: compatible).contains("rs_1"))
        let claude = ClaudeProvider.messages([assistant], redactImages: false)
        #expect(claude == [["role": "assistant", "content": [
            ["type": "thinking", "thinking": "x", "signature": "s"], ["type": "text", "text": "A"]]]])
        #expect(!String(describing: claude).contains("rs_1"))
        let openAI = OpenAIProvider.inputItems([assistant], redactImages: false)
        #expect(!String(describing: openAI).contains("thinking"))
        #expect(openAI.first == ["id": "rs_1", "type": "reasoning"])
        #expect(request.sentContent == [.text])
    }
}

// MARK: - 2. Failure metadata

@Suite("Fehlgeschlagene Anfragen tragen Metadaten")
struct FailureMetadataTests {
    @Test("Claude: Fehler-Ereignis im Stream liefert Nutzung bis dahin, rohe Anfrage, Ereignisse und gesendete Stufe")
    func errorEvent() async throws {
        let stream = TestSupport.sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#),
        ])
        let provider = makeClaude(stub: StubTransport([.init(lines: stream)]))
        do {
            _ = try await TestSupport.collect(provider, TestSupport.request(reasoning: .high))
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error.providerError == .overloaded)
            let metadata = try #require(error.failureMetadata)
            #expect(metadata.usage.inputTokens == 25)
            #expect(metadata.reasoning == .high)
            #expect(metadata.rawRequest.contains("POST https://api.anthropic.com/v1/messages"))
            #expect(metadata.rawResponse.contains("overloaded_error"))
            #expect(metadata.rawResponse.contains("text_delta"))
            #expect(!metadata.rawRequest.contains(TestSupport.secretKey))
            #expect(!(error.localizedDescription.isEmpty))
        }
    }

    @Test("Claude: Ablehnung (refusal) und HTTP-Fehler tragen Metadaten; ohne Key bleibt der Fehler schlicht")
    func refusalAndHTTP() async throws {
        let refusal = TestSupport.sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":7}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}},"usage":{"output_tokens":2}}"#),
        ])
        do {
            _ = try await TestSupport.collect(makeClaude(stub: StubTransport([.init(lines: refusal)])), TestSupport.request())
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error.providerError == .refused(category: "cyber"))
            #expect(error.failureMetadata?.usage.inputTokens == 7)
        }
        let http = StubTransport([.init(status: 400, lines: [#"{"type":"error","error":{"type":"invalid_request_error","message":"kaputt"}}"#])])
        do {
            _ = try await TestSupport.collect(makeClaude(stub: http), TestSupport.request(reasoning: .low))
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error.providerError == .badRequest("kaputt"))
            #expect(error.failureMetadata?.reasoning == .low)
            #expect(error.failureMetadata?.rawRequest.contains("\"model\"") == true)
        }
        do {
            _ = try await TestSupport.collect(makeClaude(stub: StubTransport(), key: nil), TestSupport.request())
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error is ProviderError)
            #expect(error.providerError == .missingAPIKey)
            #expect(error.failureMetadata == nil)
        }
    }

    @Test("Getrennte Verbindung nach Teilen: OpenAI liefert Nutzung und Ereignisse")
    func disconnect() async {
        let stream = TestSupport.sse([(nil, #"{"type":"response.output_text.delta","delta":"A"}"#)])
        do {
            _ = try await TestSupport.collect(makeOpenAI(stub: StubTransport([.init(lines: stream)])), TestSupport.request())
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error.providerError == .network("Die Verbindung wurde vor dem Ende der Antwort getrennt."))
            #expect(error.failureMetadata?.rawResponse.contains("output_text.delta") == true)
        }
    }
}

// MARK: - 7. Images

@Suite("Bilder bei Modellen ohne Bildunterstützung")
struct ImageGuardTests {
    private let message = ProviderError.badRequest("Dieses Modell kann keine Bilder verarbeiten.")
    private let noImages = ProviderCapabilities(supportsImages: false, supportsTools: true, reasoningLevels: [.low])

    @Test("Claude, OpenAI und OpenAI-kompatibel lehnen vor dem Senden ab")
    func rejectedBeforeSending() async {
        let claudeStub = StubTransport()
        #expect(await TestSupport.thrownError(makeClaude(capabilities: noImages, stub: claudeStub), TestSupport.request([image])) == message)
        #expect(claudeStub.requests.isEmpty)
        let openAIStub = StubTransport()
        #expect(await TestSupport.thrownError(makeOpenAI(capabilities: noImages, stub: openAIStub), TestSupport.request([image])) == message)
        #expect(openAIStub.requests.isEmpty)
        let compatibleStub = StubTransport()
        let configuration = TestSupport.configuration(
            .openAICompatible, model: "m", baseURL: "http://192.168.1.2:11434", capabilities: noImages)
        let compatible = OpenAICompatibleProvider(
            configuration: configuration, keyStore: InMemoryKeyStore(), transport: compatibleStub, retry: TestSupport.fastRetry)
        #expect(await TestSupport.thrownError(compatible, TestSupport.request([image])) == message)
        #expect(compatibleStub.requests.isEmpty)
        // Text only is fine.
        let ok = StubTransport([.init(lines: TestSupport.sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":1}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]))])
        #expect(await TestSupport.thrownError(makeClaude(capabilities: noImages, stub: ok), TestSupport.request()) == nil)
    }

    @Test("Eigene Einstellung „kann Bilder“ gilt; unbekannte Fähigkeiten blockieren nicht")
    func overrideAndUnknown() async {
        let blocked = TestSupport.configuration(.claude, imageOverride: false)
        #expect(!ProviderFactory.imagesAllowed(by: blocked))
        #expect(ProviderFactory.imagesAllowed(by: TestSupport.configuration(.claude, imageOverride: true)))
        #expect(ProviderFactory.imagesAllowed(by: TestSupport.configuration(.claude)))
        #expect(!ProviderFactory.imagesAllowed(by: TestSupport.configuration(.claude, capabilities: noImages)))
        #expect(ProviderFactory.imagesAllowed(by: TestSupport.configuration(.claude, capabilities: claudeCaps)))
    }

    @Test("Mock-Anbieter lehnt Bilder ebenfalls ab")
    func mock() async {
        let provider = MockProvider(capabilities: noImages)
        #expect(await TestSupport.thrownError(provider, TestSupport.request([image])) == message)
    }

    #if canImport(FoundationModels)
    @Test("Apple-Anbieter lehnt Bilder ab, noch vor der Verfügbarkeitsprüfung")
    func apple() async {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let provider = AppleFoundationProvider(configuration: TestSupport.configuration(.appleFoundation, model: "apple-foundation"))
        #expect(await TestSupport.thrownError(provider, TestSupport.request([image])) == message)
    }
    #endif
}

// MARK: - 11. Retry cap

@Suite("Wiederholung mit langem Retry-After")
struct RetryCapTests {
    @Test("Retry-After über der Obergrenze: keine Wiederholung, rateLimited wird geworfen")
    func noEarlyRetry() async {
        let sleeps = LockedList()
        let policy = RetryPolicy(maxRetries: 2, baseDelay: 1, maxDelay: 30, sleep: { sleeps.add($0) }, jitter: { 0 })
        let calls = LockedList()
        do {
            _ = try await policy.run { () async throws -> Int in
                calls.add(1)
                throw ProviderError.rateLimited(retryAfter: 600)
            }
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error as? ProviderError == .rateLimited(retryAfter: 600))
        }
        #expect(calls.count == 1)
        #expect(sleeps.count == 0)
        // Within the cap it is still retried.
        let inside = LockedList()
        _ = try? await policy.run { () async throws -> Int in
            inside.add(1)
            throw ProviderError.rateLimited(retryAfter: 30)
        }
        #expect(inside.count == 3)
    }

    @Test("Claude: 429 mit Retry-After 600 wird nicht wiederholt")
    func provider() async {
        let busy = StubTransport.Canned(status: 429, headers: ["retry-after": "600"], lines: [#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#])
        let stub = StubTransport([busy, busy, busy])
        let error = await TestSupport.thrownError(makeClaude(stub: stub), TestSupport.request())
        #expect(error == .rateLimited(retryAfter: 600))
        #expect(stub.requests.count == 1)
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ value: Double) { lock.withLock { items.append(value) } }
    var count: Int { lock.withLock { items.count } }
}

// MARK: - 12. URL redaction

@Suite("Zugangsdaten in URLs")
struct URLRedactionTests {
    @Test("Benutzer, Passwort, Query und Fragment werden entfernt")
    func redactURL() {
        #expect(URLRedaction.redact(url: "https://user:pw@host:8080/v1/x?key=SECRET#frag") == "https://host:8080/v1/x")
        #expect(URLRedaction.redact(url: "http://192.168.0.5:11434") == "http://192.168.0.5:11434")
        #expect(URLRedaction.redact(url: "user:pw@host/pfad?token=1") == "host/pfad")
        #expect(URLRedaction.redact(url: "ftp://a@b@host/x") == "ftp://host/x")
        #expect(URLRedaction.redact(in: "Fehler bei https://u:p@h/x?k=1 und danach.") == "Fehler bei https://h/x und danach.")
        #expect(URLRedaction.redact(in: "Kein Link hier") == "Kein Link hier")
    }

    @Test("Gerenderte Anfrage zeigt keine Zugangsdaten der URL")
    func render() {
        var request = URLRequest(url: URL(string: "https://user:geheim@host.example/v1/x?api_key=GEHEIM2")!)
        request.httpMethod = "POST"
        request.setValue("Bearer sk-secret", forHTTPHeaderField: "Authorization")
        let text = HeaderMasking.render(request)
        #expect(text.hasPrefix("POST https://host.example/v1/x\n"))
        #expect(!text.contains("geheim") && !text.contains("GEHEIM2") && !text.contains("sk-secret"))
    }

    @Test("Ungültige Serveradresse nennt keine Zugangsdaten")
    func invalidAddress() {
        do {
            _ = try ProviderEndpoint.url(base: "ftp://nutzer:passwort123@host/pfad?token=abc", path: "/v1/models")
            Issue.record("Fehler erwartet")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("Ungültige Serveradresse"))
            #expect(!text.contains("passwort123") && !text.contains("token=abc"))
        }
    }

    @Test("OpenAI-kompatibel: Anfrage-Log einer Adresse mit Zugangsdaten bleibt sauber")
    func compatibleLog() async throws {
        let stub = StubTransport([.init(lines: TestSupport.sse([(nil, #"{"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}"#), (nil, "[DONE]")]))])
        let configuration = TestSupport.configuration(
            .openAICompatible, model: "m", baseURL: "http://nutzer:passwort123@192.168.1.2:11434",
            capabilities: ProviderCapabilities(supportsStreaming: true))
        let provider = OpenAICompatibleProvider(
            configuration: configuration, keyStore: InMemoryKeyStore(), transport: stub, retry: TestSupport.fastRetry)
        let (_, response) = try await TestSupport.collect(provider, TestSupport.request())
        let raw = response.metadata.rawRequest
        #expect(raw.hasPrefix("POST http://192.168.1.2:11434/v1/chat/completions"))
        #expect(!raw.contains("passwort123"))
    }
}

// MARK: - 6. Key override

@Suite("Temporärer Key für Test und Modellliste")
struct KeyOverrideTests {
    @Test("Modellliste mit temporärem Key; der gespeicherte Key bleibt unberührt")
    func override() async throws {
        let configuration = TestSupport.configuration(.claude, model: "claude-sonnet-5-5")
        let store = InMemoryKeyStore(keys: [configuration.id: "alter-key"])
        let stub = StubTransport([.init(body: Data(#"{"data":[],"has_more":false}"#.utf8))])
        let factory = ProviderFactory(keyStore: store, transport: stub, retry: TestSupport.fastRetry)
        _ = try await factory.withKeyOverride("neuer-key", for: configuration.id).makeCatalog(for: configuration).availableModels()
        #expect(TestSupport.header(stub.requests[0], "x-api-key") == "neuer-key")
        #expect(try store.readKey(for: configuration.id) == "alter-key")
    }
}

// MARK: - 3. Settings and keys

private func makeDefaults() -> (UserDefaults, String) {
    let suite = "StudyAIReviewTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Suite("Unlesbare Einstellungen")
struct LenientSettingsTests {
    private func rawSettings() throws -> (Data, ProviderConfiguration, ProviderConfiguration) {
        let good = ProviderConfiguration(name: "Gut", kind: .claude, model: "claude-sonnet-5-5", reasoning: .high)
        let future = ProviderConfiguration(name: "Zukunft", kind: .openAI, model: "gpt-x")
        let settings = AISettings(
            configurations: [good, future], defaultProviderID: good.id, reasoningOverrides: [.chat: .low, .query: .high],
            developerModeEnabled: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var configurations = try #require(object["configurations"] as? [[String: Any]])
        configurations[1]["kind"] = "quantencomputer"
        object["configurations"] = configurations
        // Flat array [task, level, task, level]: make one level unknown.
        var overrides = try #require(object["reasoningOverrides"] as? [Any])
        if let index = overrides.firstIndex(where: { ($0 as? String) == "high" }) { overrides[index] = "ultra" }
        object["reasoningOverrides"] = overrides
        return (try JSONSerialization.data(withJSONObject: object), good, future)
    }

    @Test("Unbekannte Werte einer neueren Version überspringen nur den betroffenen Eintrag")
    func skipsOnlyUnreadable() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (raw, good, _) = try rawSettings()
        defaults.set(raw, forKey: AISettingsStore.defaultsKey)
        let store = AISettingsStore(defaults: defaults)
        let settings = store.load()
        #expect(settings.configurations == [good])
        #expect(settings.defaultProviderID == good.id)
        #expect(settings.developerModeEnabled)
        #expect(settings.reasoningOverrides == [.chat: .low])
        #expect(!store.isStoredDataCorrupt)
        #expect(store.hasUnreadableEntries)
        #expect(store.backupData == raw)
    }

    @Test("Schreiben ersetzt die Einstellungen, die Sicherung der Originaldaten bleibt")
    func backupSurvivesWrites() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (raw, good, _) = try rawSettings()
        defaults.set(raw, forKey: AISettingsStore.defaultsKey)
        let store = AISettingsStore(defaults: defaults)
        // No load before: update must still back up first.
        store.update { $0.usdToEurRate = 0.9 }
        #expect(defaults.data(forKey: AISettingsStore.defaultsKey) != raw)
        #expect(defaults.data(forKey: AISettingsStore.backupKey) == raw)
        #expect(store.load().configurations == [good])
        #expect(store.hasUnreadableEntries, "bleibt wahr, solange die Sicherung existiert")
        store.update { $0.developerModeEnabled = false }
        #expect(defaults.data(forKey: AISettingsStore.backupKey) == raw)
        store.discardBackup()
        #expect(!store.hasUnreadableEntries)
        #expect(defaults.data(forKey: AISettingsStore.backupKey) == nil)
    }

    @Test("Komplett beschädigte Daten werden ebenfalls gesichert")
    func corruptIsBackedUp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let garbage = Data("{\"configurations\": [kaputt".utf8)
        defaults.set(garbage, forKey: AISettingsStore.defaultsKey)
        let store = AISettingsStore(defaults: defaults)
        store.save(AISettings(developerModeEnabled: true))
        #expect(store.backupData == garbage)
        #expect(store.hasUnreadableEntries)
        #expect(!store.isStoredDataCorrupt)
    }

    @Test("Saubere Einstellungen erzeugen keine Sicherung")
    func cleanHasNoBackup() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        store.update { $0.developerModeEnabled = true }
        _ = store.load()
        #expect(!store.hasUnreadableEntries)
        #expect(store.backupData == nil)
    }

    @Test("Schlüsselspeicher listet Konfigurationen mit Key; Keychain-Abfrage über den Dienst")
    func listing() throws {
        let a = UUID(), b = UUID()
        let store = KeyStoreFactory.make([a: "1", b: "2"])
        #expect(Set(try store.storedConfigurationIDs()) == [a, b])
        try store.deleteKey(for: a)
        #expect(try store.storedConfigurationIDs() == [b])
        let query = KeychainKeyStore.listQuery(service: "dienst")
        #expect(query[kSecMatchLimit as String] as! CFString == kSecMatchLimitAll)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == "dienst")
        #expect(query[kSecReturnData as String] == nil)
    }
}

enum KeyStoreFactory {
    static func make(_ keys: [UUID: String]) -> InMemoryKeyStore { InMemoryKeyStore(keys: keys) }
}
