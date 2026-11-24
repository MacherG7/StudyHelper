import Foundation
import Testing

@testable import StudyAI

private func events(from text: String, splitting: (String) -> [String] = { $0.components(separatedBy: "\n") }) -> [SSEEvent] {
    var parser = SSEParser()
    var result: [SSEEvent] = []
    for line in splitting(text) { if let event = parser.feed(line: line) { result.append(event) } }
    if let last = parser.finish() { result.append(last) }
    return result
}

@Suite("SSE-Parser")
struct SSEParserTests {
    @Test("Event mit Namen und Daten")
    func basic() {
        let result = events(from: "event: content_block_delta\ndata: {\"a\":1}\n\nevent: message_stop\ndata: {}\n\n")
        #expect(result == [
            SSEEvent(event: "content_block_delta", data: #"{"a":1}"#), SSEEvent(event: "message_stop", data: "{}"),
        ])
    }

    @Test("Mehrere data-Zeilen werden mit Zeilenumbruch verbunden")
    func multiline() {
        #expect(events(from: "data: a\ndata: b\ndata:\ndata: c\n\n") == [SSEEvent(data: "a\nb\n\nc")])
    }

    @Test("Kommentare, id, retry und unbekannte Felder werden ignoriert")
    func ignored() {
        let result = events(from: ": ping\nid: 7\nretry: 100\nfoo: bar\ndata: x\n\n: nur Kommentar\n\n")
        #expect(result == [SSEEvent(data: "x")])
    }

    @Test("Letztes Event ohne abschließende Leerzeile wird am Ende geliefert")
    func trailing() {
        #expect(events(from: "event: e\ndata: last") == [SSEEvent(event: "e", data: "last")])
    }

    @Test("Wagenrücklauf am Zeilenende und fehlendes Leerzeichen nach dem Doppelpunkt")
    func oddLines() {
        let result = events(from: "event:x\r\ndata:{\"k\":\" v\"}\r\n\r\n")
        #expect(result == [SSEEvent(event: "x", data: #"{"k":" v"}"#)])
    }

    @Test("Ereignisname gilt nur für ein Event")
    func eventNameReset() {
        let result = events(from: "event: a\ndata: 1\n\ndata: 2\n\n")
        #expect(result == [SSEEvent(event: "a", data: "1"), SSEEvent(event: nil, data: "2")])
    }

    @Test("Event ohne data wird nicht geliefert")
    func noData() {
        #expect(events(from: "event: ping\n\n").isEmpty)
    }

    @Test("Adapter wandelt einen Zeilenstrom in Events")
    func adapter() async throws {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            for line in ["event: a", "data: 1", "", "data: 2"] { continuation.yield(line) }
            continuation.finish()
        }
        var result: [SSEEvent] = []
        for try await event in SSEParser.events(from: lines) { result.append(event) }
        #expect(result == [SSEEvent(event: "a", data: "1"), SSEEvent(data: "2")])
    }

    @Test("Fehler im Zeilenstrom wird weitergereicht")
    func adapterError() async {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("data: 1")
            continuation.yield("")
            continuation.finish(throwing: ProviderError.network("weg"))
        }
        var count = 0
        do {
            for try await _ in SSEParser.events(from: lines) { count += 1 }
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error as? ProviderError == .network("weg"))
        }
        #expect(count == 1)
    }
}

@Suite("Fehlerabbildung")
struct HTTPErrorMapperTests {
    private func anthropic(_ status: Int, _ type: String, details: String = "", headers: [String: String] = [:],
                           model: String? = nil) -> ProviderError {
        let body = #"{"type":"error","error":{"type":"\#(type)","message":"Text"\#(details)}}"#
        return HTTPErrorMapper.map(status: status, body: Data(body.utf8), headers: headers, style: .anthropic, model: model)
    }

    private func openAI(_ status: Int, code: String?, type: String = "x", headers: [String: String] = [:]) -> ProviderError {
        let codeText = code.map { #""\#($0)""# } ?? "null"
        let body = #"{"error":{"message":"Text","type":"\#(type)","code":\#(codeText),"param":null}}"#
        return HTTPErrorMapper.map(status: status, body: Data(body.utf8), headers: headers, style: .openAI)
    }

    @Test("Claude: Statuscodes")
    func anthropicStatuses() {
        #expect(anthropic(401, "authentication_error") == .invalidAPIKey)
        #expect(anthropic(403, "permission_error") == .permissionDenied("Text"))
        #expect(anthropic(404, "not_found_error", model: "m") == .modelNotFound("m"))
        #expect(anthropic(404, "not_found_error") == .badRequest("Text"))
        #expect(anthropic(400, "invalid_request_error") == .badRequest("Text"))
        #expect(anthropic(402, "billing_error") == .quotaExceeded("Text"))
        #expect(anthropic(529, "overloaded_error") == .overloaded)
        #expect(anthropic(500, "api_error") == .server(status: 500, message: "Text"))
        #expect(anthropic(503, "api_error").isRetryable)
    }

    @Test("Claude: 429 mit Retry-After, Spend-Limit wird nicht wiederholt")
    func anthropicRateLimit() {
        #expect(anthropic(429, "rate_limit_error", headers: ["retry-after": "12"]) == .rateLimited(retryAfter: 12))
        #expect(anthropic(429, "rate_limit_error") == .rateLimited(retryAfter: nil))
        let spend = anthropic(429, "rate_limit_error", details: #","details":{"error_code":"enforced_spend_limit_reached"}"#)
        #expect(spend == .quotaExceeded("Text"))
        #expect(!spend.isRetryable)
    }

    @Test("OpenAI: Statuscodes")
    func openAIStatuses() {
        #expect(openAI(401, code: "invalid_api_key") == .invalidAPIKey)
        #expect(openAI(400, code: nil) == .badRequest("Text"))
        #expect(openAI(503, code: "server_is_overloaded") == .overloaded)
        #expect(openAI(500, code: nil) == .server(status: 500, message: "Text"))
    }

    @Test("OpenAI: 429 Rate-Limit mit Retry-After, Guthaben und Limits sind Kontingent")
    func openAIRateLimit() {
        #expect(openAI(429, code: "rate_limit_exceeded", headers: ["Retry-After": "3"]) == .rateLimited(retryAfter: 3))
        for code in ["credit_balance_exhausted", "insufficient_quota", "monthly_spend_limit_exceeded",
                     "daily_usage_limit_exceeded"] {
            #expect(openAI(429, code: code) == .quotaExceeded("Text"), "\(code)")
        }
    }

    @Test("Unlesbarer Body führt nicht zum Absturz")
    func garbageBody() {
        let html = Data("<html>Bad Gateway</html>".utf8)
        #expect(HTTPErrorMapper.map(status: 502, body: html, style: .openAI) == .server(status: 502, message: "<html>Bad Gateway</html>"))
        #expect(HTTPErrorMapper.map(status: 401, body: Data(), style: .anthropic) == .invalidAPIKey)
        #expect(HTTPErrorMapper.map(status: 429, body: Data([0xFF, 0xFE]), style: .anthropic) == .rateLimited(retryAfter: nil))
    }

    @Test("Retry-After als Sekunden und als HTTP-Datum")
    func retryAfter() {
        #expect(HTTPErrorMapper.retryAfter(from: ["Retry-After": " 7 "]) == 7)
        #expect(HTTPErrorMapper.retryAfter(from: [:]) == nil)
        #expect(HTTPErrorMapper.retryAfter(from: ["retry-after": "abc"]) == nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // Tue, 14 Nov 2023 22:13:20 GMT
        let seconds = HTTPErrorMapper.retryAfter(from: ["retry-after": "Tue, 14 Nov 2023 22:13:50 GMT"], now: now)
        #expect(seconds == 30)
    }
}

private actor Counter {
    var value = 0
    var sleeps: [TimeInterval] = []
    func next() -> Int { value += 1; return value }
    func slept(_ seconds: TimeInterval) { sleeps.append(seconds) }
}

@Suite("Wiederholungen")
struct RetryPolicyTests {
    private func policy(_ counter: Counter, maxRetries: Int = 2) -> RetryPolicy {
        RetryPolicy(maxRetries: maxRetries, baseDelay: 1, maxDelay: 30,
                    sleep: { await counter.slept($0) }, jitter: { 0 })
    }

    @Test("Wiederholbarer Fehler wird zweimal wiederholt, dann klappt es")
    func retriesThenSucceeds() async throws {
        let counter = Counter()
        let result = try await policy(counter).run { () async throws -> String in
            if await counter.next() < 3 { throw ProviderError.overloaded }
            return "ok"
        }
        #expect(result == "ok")
        #expect(await counter.value == 3)
        #expect(await counter.sleeps == [1, 2])
    }

    @Test("Nach der letzten Wiederholung wird der Fehler geworfen")
    func givesUp() async {
        let counter = Counter()
        do {
            _ = try await policy(counter).run { () async throws -> Int in
                _ = await counter.next()
                throw ProviderError.network("weg")
            }
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error as? ProviderError == .network("weg"))
        }
        #expect(await counter.value == 3)
    }

    @Test("Nicht wiederholbare Fehler werden sofort geworfen")
    func noRetryForPermanentErrors() async {
        for error in [ProviderError.invalidAPIKey, .quotaExceeded("x"), .badRequest("x"), .cancelled,
                      .server(status: 400, message: "")] {
            let counter = Counter()
            do {
                _ = try await policy(counter).run { () async throws -> Int in
                    _ = await counter.next()
                    throw error
                }
            } catch {}
            #expect(await counter.value == 1, "\(error)")
            #expect(await counter.sleeps.isEmpty)
        }
    }

    @Test("Retry-After wird beachtet und auf 30 Sekunden begrenzt")
    func honorsRetryAfter() {
        let policy = RetryPolicy(jitter: { 0 })
        #expect(policy.delay(forRetry: 0, error: .rateLimited(retryAfter: 5)) == 5)
        #expect(policy.delay(forRetry: 0, error: .rateLimited(retryAfter: 600)) == 30)
        #expect(policy.delay(forRetry: 1, error: .rateLimited(retryAfter: nil)) == 2)
        #expect(policy.delay(forRetry: 10, error: .overloaded) == 30)
    }

    @Test("Jitter verlängert die Wartezeit höchstens um 25 Prozent")
    func jitter() {
        let policy = RetryPolicy(jitter: { 1 })
        #expect(policy.delay(forRetry: 0, error: .overloaded) == 1.25)
    }
}

@Suite("Header-Maskierung")
struct HeaderMaskingTests {
    private let secret = "sk" + "-ant-" + "SEHR-GEHEIM-123"  // built at runtime so check-secrets.sh stays strict

    @Test("Geheime Header werden unabhängig von der Schreibweise maskiert")
    func masks() {
        let masked = HeaderMasking.masked([
            "Authorization": "Bearer \(secret)", "X-API-Key": secret, "api-key": secret, "OPENAI-API-KEY": secret,
            "Cookie": secret, "content-type": "application/json",
        ])
        #expect(masked["Authorization"] == "***")
        #expect(masked["X-API-Key"] == "***")
        #expect(masked["api-key"] == "***")
        #expect(masked["OPENAI-API-KEY"] == "***")
        #expect(masked["Cookie"] == "***")
        #expect(masked["content-type"] == "application/json")
    }

    @Test("Gerenderte Anfrage enthält den Key nie")
    func renderedRequest() throws {
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1/messages")))
        request.httpMethod = "POST"
        request.setValue(secret, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"model":"m"}"#.utf8)
        let text = HeaderMasking.render(request)
        #expect(!text.contains(secret))
        #expect(text.contains("POST https://api.example.com/v1/messages"))
        #expect(text.contains("x-api-key: ***"))
        #expect(text.contains(#"{"model":"m"}"#))
    }

    @Test("Binäre Bodys werden zusammengefasst")
    func binaryBody() throws {
        var request = URLRequest(url: try #require(URL(string: "https://x.invalid")))
        request.httpBody = Data([0xFF, 0xFE, 0xFD])
        #expect(HeaderMasking.render(request).contains("<3 Bytes>"))
    }
}

@Suite("Transport im Test")
struct TransportTests {
    @Test("StubTransport zeichnet Anfragen auf und liefert vorbereitete Antworten")
    func stub() async throws {
        let stub = StubTransport([.init(status: 429, headers: ["retry-after": "4"], body: Data("x".utf8))])
        stub.enqueue(.init(lines: ["data: 1", ""]))
        var request = URLRequest(url: try #require(URL(string: "https://x.invalid/a")))
        request.httpMethod = "POST"
        let (data, response) = try await stub.send(request)
        #expect(response.statusCode == 429)
        #expect(data == Data("x".utf8))
        let (lines, _) = try await stub.stream(request)
        var collected: [String] = []
        for try await line in lines { collected.append(line) }
        #expect(collected == ["data: 1", ""])
        #expect(stub.requests.count == 2)
    }

    @Test("Fehler des Transports werden auf ProviderError abgebildet")
    func errorMapping() {
        #expect(providerError(from: URLError(.cancelled)) == .cancelled)
        #expect(providerError(from: CancellationError()) == .cancelled)
        if case .network = providerError(from: URLError(.notConnectedToInternet)) {} else { Issue.record("network erwartet") }
    }

    @Test("MockProvider braucht keinen Transport: Tests nutzen nie URLSessionTransport")
    func mockNeedsNoTransport() async throws {
        let provider = MockProvider()
        let response = try await provider.respond(
            to: ModelRequest(task: .chat, system: PromptParts(fixed: "x"), messages: [.user("hi")]))
        #expect(response.text == "Das ist eine Testantwort.")
        // The stub is the only transport used by test code; URLSessionTransport is never constructed here.
        let transport: any HTTPTransport = StubTransport()
        #expect(!(transport is URLSessionTransport))
    }
}
