import Foundation
import Testing

@testable import StudyAI

private func request(_ task: AITask = .chat, messages: [ChatMessage] = [.user("Hallo")], reasoning: ReasoningLevel? = nil) -> ModelRequest {
    ModelRequest(task: task, system: PromptParts(fixed: "Regel"), messages: messages, reasoning: reasoning,
                 learningUnitIDsInContext: ["u1"])
}

@Suite("MockProvider")
struct MockProviderTests {
    private func collect(_ provider: MockProvider, _ request: ModelRequest) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in provider.stream(request) { events.append(event) }
        return events
    }

    @Test("Ereignisse: Reasoning, Textteile, Werkzeugaufruf, am Ende finished")
    func eventOrder() async throws {
        let call = ToolCall(id: "t1", name: "suche", arguments: #"{"q":"x"}"#)
        let provider = MockProvider(script: MockScript(
            chunks: ["Hal", "lo ", "Welt"], reasoningText: "Nachdenken", toolCalls: [call],
            usage: TokenUsage(inputTokens: 100, outputTokens: 20, reasoningTokens: 5)))
        let events = try await collect(provider, request(reasoning: .high))
        #expect(events.count == 6)
        #expect(events[0] == .reasoningDelta("Nachdenken"))
        #expect(events[1] == .textDelta("Hal") && events[2] == .textDelta("lo ") && events[3] == .textDelta("Welt"))
        #expect(events[4] == .toolCall(call))
        guard case .finished(let response) = try #require(events.last) else { Issue.record("finished erwartet"); return }
        #expect(response.text == "Hallo Welt")
        #expect(response.toolCalls == [call])
        let meta = response.metadata
        #expect(meta.providerKind == .mock && meta.providerName == "Mock" && meta.model == "mock-1")
        #expect(meta.task == .chat && meta.reasoning == .high)
        #expect(meta.usage.inputTokens == 100 && meta.usage.reasoningTokens == 5)
        #expect(meta.reasoningText == "Nachdenken")
        #expect(meta.sentContent == [.text])
        #expect(meta.learningUnitIDsInContext == ["u1"])
        #expect(meta.stopReason == .endTurn)
        #expect(meta.timeToFirstToken != nil)
        #expect(meta.duration >= 0)
        #expect(meta.rawRequest.contains("Hallo"))
        #expect(meta.rawResponse.contains("Hal"))
        #expect(meta.toolCalls == [call])
    }

    @Test("Antwort in Teilen aus einem Text")
    func answerChunks() {
        let script = MockScript(answer: "abcdefghij", chunkSize: 4)
        #expect(script.chunks == ["abcd", "efgh", "ij"])
        #expect(script.answer == "abcdefghij")
    }

    @Test("respond liefert die vollständige Antwort")
    func respond() async throws {
        let provider = MockProvider(script: MockScript(answer: "Ganz kurz"))
        #expect(try await provider.respond(to: request()).text == "Ganz kurz")
    }

    @Test("Zeiten kommen aus der einstellbaren Uhr")
    func injectableClock() async throws {
        let clock = Clock()
        let provider = MockProvider(script: MockScript(chunks: ["a", "b"]), now: { clock.tick() })
        let response = try await provider.respond(to: request())
        // start 0, first token 1, end 2
        #expect(response.metadata.timeToFirstToken == 1)
        #expect(response.metadata.duration == 2)
    }

    @Test("Bilder erscheinen im rawRequest nur als Platzhalter")
    func imagesRedacted() async throws {
        let image = ImagePayload(data: Data(repeating: 1, count: 1234), mediaType: "image/png")
        let messages = [ChatMessage(role: .user, content: [.text("Was ist das?"), .image(image)])]
        let response = try await MockProvider().respond(to: request(messages: messages))
        #expect(response.metadata.rawRequest.contains("<Bild, 1234 Bytes>"))
        #expect(!response.metadata.rawRequest.contains(image.data.base64EncodedString()))
        #expect(response.metadata.sentContent == [.text, .image])
    }

    @Test("Fehler vor dem Stream")
    func errorBeforeStream() async {
        let provider = MockProvider(script: MockScript(error: .invalidAPIKey))
        do {
            _ = try await collect(provider, request())
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error as? ProviderError == .invalidAPIKey)
        }
    }

    @Test("Fehler mitten im Stream: bereits gelieferte Teile bleiben, kein finished")
    func errorMidStream() async {
        let provider = MockProvider(script: MockScript(
            chunks: ["a", "b", "c"], error: .overloaded, errorTiming: .afterChunks(2)))
        var events: [ModelEvent] = []
        do {
            for try await event in provider.stream(request()) { events.append(event) }
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error as? ProviderError == .overloaded)
        }
        #expect(events == [.textDelta("a"), .textDelta("b")])
    }

    @Test("Fehler nach allen Teilen")
    func errorAfterAll() async {
        let provider = MockProvider(script: MockScript(chunks: ["a"], error: .overloaded, errorTiming: .afterChunks(5)))
        await #expect(throws: ProviderError.overloaded) { try await provider.respond(to: request()) }
    }

    @Test("Anfragen werden für Prüfungen aufgezeichnet")
    func recordsRequests() async throws {
        let provider = MockProvider()
        _ = try await provider.respond(to: request(.tips))
        #expect(provider.receivedRequests.map(\.task) == [.tips])
    }

    @Test("Antwort ohne Teile und ohne Text bleibt gültig")
    func emptyAnswer() async throws {
        let response = try await MockProvider(script: MockScript(chunks: [])).respond(to: request())
        #expect(response.text.isEmpty)
        #expect(response.metadata.timeToFirstToken == nil)
    }

    @Test("Verzögerung pro Teil wird eingehalten")
    func delay() async throws {
        let provider = MockProvider(script: MockScript(chunks: ["a", "b"], chunkDelay: 0.01))
        let response = try await provider.respond(to: request())
        #expect(response.metadata.duration >= 0.015)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = -1.0
    func tick() -> Date {
        lock.withLock {
            seconds += 1
            return Date(timeIntervalSince1970: 1_000 + seconds)
        }
    }
}
