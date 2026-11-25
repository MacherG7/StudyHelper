import Foundation
import StudyAI
import StudyCore
import StudyData
import SwiftData
import Testing
@testable import StudyHelper

/// In-memory store, in-memory keys and a mock provider behind the app's `AIService`. Never touches the network or
/// the real Keychain.
@MainActor
struct AIFixture {
    let repository: StudyRepository
    let keyStore: InMemoryKeyStore
    let provider: MockProvider
    let ai: AIService

    init(
        script: MockScript = MockScript(chunks: ["Antwort"], usage: TokenUsage(inputTokens: 1000, outputTokens: 500)),
        capabilities: ProviderCapabilities = ProviderCapabilities(
            supportsImages: true, supportsStreaming: true, reasoningLevels: [.off, .low, .medium, .high])
    ) throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        repository = StudyRepository(container: container)
        keyStore = InMemoryKeyStore()
        let provider = MockProvider(script: script, capabilities: capabilities)
        self.provider = provider
        let defaults = UserDefaults(suiteName: "StudyHelperTests-AI-\(UUID().uuidString)") ?? .standard
        ai = AIService(
            repository: repository, settingsStore: AISettingsStore(defaults: defaults), keyStore: keyStore,
            backend: AIBackend(
                makeProvider: { _ in provider },
                makeCatalog: { _ in StaticModelCatalog(models: AIBackend.mockModels) }))
    }

    static func request(_ task: AITask = .query) -> ModelRequest {
        ModelRequest(task: task, system: PromptParts(fixed: "Nur Lernstoff."), messages: [.user("Frage")])
    }

    func addConfiguration(
        name: String = "Claude", kind: ProviderKind = .claude, model: String = "claude-sonnet-5-5",
        reasoning: ReasoningLevel? = nil
    ) -> ProviderConfiguration {
        let configuration = ProviderConfiguration(name: name, kind: kind, model: model, reasoning: reasoning)
        ai.add(configuration)
        return configuration
    }

    func logs() throws -> [RequestLog] { try repository.requestLogs() }
}

@MainActor
@Suite("AIService")
struct AIServiceTests {
    @Test("run schreibt ein Log mit Kosten für ein Claude-Modell mit bekanntem Preis")
    func logsKnownPrice() async throws {
        let fixture = try AIFixture()
        _ = fixture.addConfiguration()
        let response = try await fixture.ai.run(AIFixture.request())
        #expect(response.text == "Antwort")
        let log = try #require(try fixture.logs().first)
        #expect(log.task == "query")
        #expect(log.providerKind == "claude")
        #expect(log.costKnown)
        // 1000 * 2 $ + 500 * 10 $ je 1 Mio. Tokens
        #expect(abs((log.costUSD ?? 0) - 0.007) < 1e-9)
        #expect(abs((log.costEUR ?? 0) - 0.007 * AISettings.defaultUSDToEURRate) < 1e-9)
        #expect(log.errorMessage == nil)
        #expect(log.inputTokens == 1000)
    }

    @Test("Kostenlose Anbieter kosten 0, unbekannte Modelle sind unbekannt")
    func freeAndUnknown() async throws {
        let fixture = try AIFixture()
        _ = fixture.addConfiguration(name: "Ollama", kind: .openAICompatible, model: "llama")
        _ = try await fixture.ai.run(AIFixture.request())
        let free = try #require(try fixture.logs().first)
        #expect(free.costKnown)
        #expect(free.costEUR == 0)

        let unknown = fixture.addConfiguration(name: "Neu", kind: .claude, model: "claude-gibt-es-nicht")
        _ = try await fixture.ai.run(AIFixture.request(), configuration: unknown)
        let log = try #require(try fixture.logs().first)
        #expect(!log.costKnown)
        #expect(log.costUSD == nil)
        #expect(LogFormat.cost(of: log) == "unbekannt")
    }

    @Test("Nutzer-Preise überschreiben die Preistabelle")
    func priceOverride() async throws {
        let fixture = try AIFixture()
        _ = fixture.addConfiguration(model: "mein-modell")
        fixture.ai.setPriceOverride(ModelPrice(input: 1, output: 1), for: "mein-modell")
        _ = try await fixture.ai.run(AIFixture.request())
        let log = try #require(try fixture.logs().first)
        #expect(log.costKnown)
        #expect(abs((log.costUSD ?? 0) - 0.0015) < 1e-9)
    }

    @Test("Ein Fehler wird mit Fehlermeldung ins Log geschrieben und weitergereicht")
    func failureIsLogged() async throws {
        let fixture = try AIFixture(script: MockScript(error: .invalidAPIKey))
        _ = fixture.addConfiguration()
        await #expect(throws: ProviderError.self) { try await fixture.ai.run(AIFixture.request()) }
        let log = try #require(try fixture.logs().first)
        #expect(log.errorMessage == "Der API-Key wurde abgelehnt.")
        #expect(log.inputTokens == nil)
        #expect(!log.costKnown)
    }

    @Test("Ohne eingerichteten Anbieter gibt es einen verständlichen Fehler")
    func noProvider() async throws {
        let fixture = try AIFixture()
        await #expect(throws: ProviderError.self) { try await fixture.ai.run(AIFixture.request()) }
        #expect(try fixture.logs().isEmpty)
    }

    @Test("Die Denktiefe pro Aufgabe gilt nur, wenn das Modell sie unterstützt")
    func reasoningOverride() async throws {
        let supported = try AIFixture()
        _ = supported.addConfiguration(reasoning: .low)
        supported.ai.setReasoningOverride(.high, for: .query)
        _ = try await supported.ai.run(AIFixture.request(.query))
        #expect(supported.provider.receivedRequests.last?.reasoning == .high)
        #expect(try supported.logs().first?.reasoning == "high")
        // Andere Aufgabe ohne Override: Einstellung des Anbieters.
        _ = try await supported.ai.run(AIFixture.request(.chat))
        #expect(supported.provider.receivedRequests.last?.reasoning == .low)
        // Stufe, die das Modell nicht hat: Einstellung des Anbieters.
        supported.ai.setReasoningOverride(.max, for: .tips)
        _ = try await supported.ai.run(AIFixture.request(.tips))
        #expect(supported.provider.receivedRequests.last?.reasoning == .low)

        let unsupported = try AIFixture(capabilities: ProviderCapabilities(supportsStreaming: true))
        _ = unsupported.addConfiguration()
        unsupported.ai.setReasoningOverride(.high, for: .query)
        _ = try await unsupported.ai.run(AIFixture.request(.query))
        #expect(unsupported.provider.receivedRequests.last?.reasoning == nil)
        #expect(try unsupported.logs().first?.reasoning == nil)
    }

    @Test("Löschen einer Konfiguration löscht auch ihren Key")
    func deleteRemovesKey() throws {
        let fixture = try AIFixture()
        let first = fixture.addConfiguration(name: "A")
        let second = fixture.addConfiguration(name: "B")
        try fixture.ai.saveKey("sk-test-1", for: first.id)
        #expect(fixture.ai.hasKey(for: first.id))
        #expect(fixture.ai.defaultConfigurationID == first.id)
        fixture.ai.delete(first.id)
        #expect(!fixture.ai.hasKey(for: first.id))
        #expect(try fixture.keyStore.readKey(for: first.id) == nil)
        #expect(fixture.ai.configurations.map(\.id) == [second.id])
        #expect(fixture.ai.defaultConfigurationID == second.id)
    }

    @Test("Ein anderer Standard-Anbieter ändert den Anbieter ohne Code-Änderung")
    func switchingDefault() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        let defaults = UserDefaults(suiteName: "StudyHelperTests-AI-\(UUID().uuidString)") ?? .standard
        let ai = AIService(
            repository: repository, settingsStore: AISettingsStore(defaults: defaults), keyStore: InMemoryKeyStore(),
            backend: AIBackend(
                makeProvider: { MockProvider(name: $0.name, model: $0.model) },
                makeCatalog: { _ in StaticModelCatalog(models: []) }))
        let a = ProviderConfiguration(name: "Anbieter A", kind: .claude, model: "claude-sonnet-5-5")
        let b = ProviderConfiguration(name: "Anbieter B", kind: .openAI, model: "gpt-5.4")
        ai.add(a)
        ai.add(b)
        _ = try await ai.run(AIFixture.request(.chat))
        ai.setDefault(b.id)
        _ = try await ai.run(AIFixture.request(.chat))
        let names = try repository.requestLogs().map(\.providerName)
        #expect(names == ["Anbieter B", "Anbieter A"])
        // Digitalisierung hat eine eigene Wahl.
        ai.setDigitizationProvider(a.id)
        _ = try await ai.run(AIFixture.request(.digitization))
        #expect(try repository.requestLogs().first?.providerName == "Anbieter A")
    }

    @Test("Verbindungstest meldet Erfolg und schreibt einen Log-Eintrag")
    func connectionSuccess() async throws {
        let fixture = try AIFixture()
        let configuration = fixture.addConfiguration()
        let result = await fixture.ai.testConnection(configuration: configuration)
        #expect(result == ConnectionTestResult(isSuccess: true, message: "Verbindung OK"))
        #expect(try fixture.logs().first?.task == "connectionTest")
        let request = try #require(fixture.provider.receivedRequests.last)
        #expect(request.messages == [.user("Antworte nur mit OK.")])
        #expect(request.maxOutputTokens != nil)
    }

    @Test("Verbindungstest meldet den deutschen Fehler")
    func connectionFailure() async throws {
        let fixture = try AIFixture(script: MockScript(error: .network("Zeitüberschreitung")))
        let configuration = fixture.addConfiguration()
        let result = await fixture.ai.testConnection(configuration: configuration)
        #expect(!result.isSuccess)
        #expect(result.message == "Keine Verbindung: Zeitüberschreitung")
        #expect(try fixture.logs().first?.errorMessage == result.message)
    }

    @Test("Der API-Key taucht nie im Log auf")
    func keyNeverInLog() async throws {
        let fixture = try AIFixture()
        let configuration = fixture.addConfiguration()
        try fixture.ai.saveKey("testkey-geheim-12345", for: configuration.id)
        _ = try await fixture.ai.run(AIFixture.request())
        let log = try #require(try fixture.logs().first)
        let detail = String(decoding: log.detailData, as: UTF8.self)
        #expect(!detail.contains("testkey-geheim"))
        let export = String(decoding: try fixture.repository.exportRequestLogsJSON(), as: UTF8.self)
        #expect(!export.contains("testkey-geheim"))
        #expect(fixture.ai.hasKey(for: configuration.id))
    }

    @Test("Das Detail-JSON enthält Metadaten und Prompts")
    func detailJSON() async throws {
        let fixture = try AIFixture(script: MockScript(chunks: ["Hallo"], reasoningText: "Ich denke nach."))
        _ = fixture.addConfiguration()
        _ = try await fixture.ai.run(AIFixture.request())
        let log = try #require(try fixture.logs().first)
        let detail = try JSONDecoder().decode(RequestLogDetail.self, from: log.detailData)
        #expect(detail.systemPrompt == "Nur Lernstoff.")
        #expect(detail.prompt.contains("Frage"))
        #expect(detail.metadata.reasoningText == "Ich denke nach.")
        #expect(detail.metadata.rawResponse.contains("Hallo"))
    }

    @Test("stream liefert die Ereignisse und schreibt genau ein Log")
    func streamLogs() async throws {
        let fixture = try AIFixture(script: MockScript(chunks: ["Ab", "c"]))
        _ = fixture.addConfiguration()
        var text = ""
        for try await event in fixture.ai.stream(AIFixture.request(.chat)) {
            if case .textDelta(let delta) = event { text += delta }
        }
        #expect(text == "Abc")
        #expect(try fixture.logs().count == 1)
        #expect(try fixture.logs().first?.timeToFirstToken != nil)
    }

    @Test("Ein fehlgeschlagener Stream wird mit Fehler geloggt")
    func streamFailureLogs() async throws {
        let fixture = try AIFixture(script: MockScript(error: .overloaded))
        _ = fixture.addConfiguration()
        do {
            for try await _ in fixture.ai.stream(AIFixture.request(.chat)) {}
            Issue.record("Es sollte ein Fehler kommen.")
        } catch {}
        #expect(try fixture.logs().first?.errorMessage == "Der Anbieter ist gerade überlastet.")
    }

    @Test("Modelle abrufen aktualisiert die Fähigkeiten der gespeicherten Konfiguration")
    func fetchModelsCachesCapabilities() async throws {
        let fixture = try AIFixture()
        let configuration = fixture.addConfiguration(kind: .openAI, model: "mock-denkend")
        let models = try await fixture.ai.fetchModels(for: configuration)
        #expect(models.map(\.id) == ["mock-schnell", "mock-denkend"])
        let stored = try #require(fixture.ai.configurations.first)
        #expect(stored.cachedCapabilities?.reasoningLevels == [.off, .low, .medium, .high])
    }

    @Test("Die erste Konfiguration wird Standard; Einstellungen überleben einen Neustart")
    func persistence() throws {
        let defaults = UserDefaults(suiteName: "StudyHelperTests-AI-\(UUID().uuidString)") ?? .standard
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        func service() -> AIService {
            AIService(
                repository: repository, settingsStore: AISettingsStore(defaults: defaults), keyStore: InMemoryKeyStore(),
                backend: .mock())
        }
        let first = service()
        first.add(ProviderConfiguration(name: "X", kind: .claude, model: "m"))
        first.setDeveloperMode(true)
        first.setUSDToEURRate(0.9)
        first.setUSDToEURRate(-1)
        let second = service()
        #expect(second.configurations.count == 1)
        #expect(second.defaultConfigurationID == second.configurations.first?.id)
        #expect(second.settings.developerModeEnabled)
        #expect(second.settings.usdToEurRate == 0.9)
    }
}

/// Provider that fails like a real one after the request was sent: error plus partial metadata.
private struct FailingProvider: ModelProvider {
    var kind: ProviderKind = .claude
    var capabilities = ProviderCapabilities(supportsStreaming: true, reasoningLevels: [.off, .low, .high])
    var failure: Error

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: failure) }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private struct Planet: Decodable, Equatable { var name: String; var moons: Int }

@MainActor
@Suite("AIService: Prüfungsbefunde")
struct AIServiceReviewTests {
    private func service(
        defaults: UserDefaults? = nil, keyStore: InMemoryKeyStore = InMemoryKeyStore(), backend: AIBackend
    ) throws -> (AIService, StudyRepository) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let repository = StudyRepository(container: container)
        let defaults = defaults ?? UserDefaults(suiteName: "StudyHelperTests-AI-\(UUID().uuidString)") ?? .standard
        return (AIService(
            repository: repository, settingsStore: AISettingsStore(defaults: defaults), keyStore: keyStore,
            backend: backend), repository)
    }

    @Test("Fehlgeschlagene Anfrage: Nutzung, rohe Anfrage und gesendete Stufe kommen ins Log")
    func failureMetadataIsLogged() async throws {
        let metadata = ResponseMetadata(
            task: .query, providerKind: .claude, providerName: "Claude", model: "claude-sonnet-5-5", reasoning: .low,
            usage: TokenUsage(inputTokens: 1000, outputTokens: 10), rawRequest: "POST https://api.example/v1/messages",
            rawResponse: "event")
        let failing = FailingProvider(failure: ProviderFailure(underlying: .overloaded, metadata: metadata))
        let (ai, repository) = try service(backend: AIBackend(
            makeProvider: { _ in failing }, makeCatalog: { _ in StaticModelCatalog(models: []) }))
        ai.add(ProviderConfiguration(name: "Claude", kind: .claude, model: "claude-sonnet-5-5", reasoning: .high))
        var request = AIFixture.request()
        request.reasoning = .high  // asked for high; the provider reports that it really sent low
        do {
            _ = try await ai.run(request)
            Issue.record("Fehler erwartet")
        } catch {
            #expect(error as? ProviderError == .overloaded, "Aufrufer sehen den ProviderError")
        }
        let log = try #require(try repository.requestLogs().first)
        #expect(log.errorMessage == "Der Anbieter ist gerade überlastet.")
        #expect(log.inputTokens == 1000)
        #expect(log.costKnown)
        #expect(log.reasoning == "low")
        let detail = try JSONDecoder().decode(RequestLogDetail.self, from: log.detailData)
        #expect(detail.metadata.rawRequest.contains("POST https://api.example"))
    }

    @Test("Fehler vor dem Senden: keine Denktiefe im Log")
    func failureBeforeSending() async throws {
        let failing = FailingProvider(failure: ProviderError.missingAPIKey)
        let (ai, repository) = try service(backend: AIBackend(
            makeProvider: { _ in failing }, makeCatalog: { _ in StaticModelCatalog(models: []) }))
        ai.add(ProviderConfiguration(name: "Claude", kind: .claude, model: "claude-sonnet-5-5", reasoning: .high))
        await #expect(throws: ProviderError.self) { try await ai.run(AIFixture.request()) }
        #expect(try repository.requestLogs().first?.reasoning == nil)
    }

    @Test("Zugangsdaten in URLs der Fehlermeldung kommen nicht ins Log und nicht in den Export")
    func urlCredentialsAreRedacted() async throws {
        let fixture = try AIFixture(script: MockScript(error: .network("Fehler bei http://nutzer:passwort123@host:11434/x?token=abc")))
        _ = fixture.addConfiguration()
        await #expect(throws: ProviderError.self) { try await fixture.ai.run(AIFixture.request()) }
        let log = try #require(try fixture.logs().first)
        #expect(log.errorMessage?.contains("passwort123") == false)
        #expect(log.errorMessage?.contains("token=abc") == false)
        #expect(log.errorMessage?.contains("http://host:11434/x") == true)
        let export = String(decoding: try fixture.repository.exportRequestLogsJSON(), as: UTF8.self)
        #expect(!export.contains("passwort123") && !export.contains("token=abc"))
    }

    @Test("Strukturierte Antwort wird decodiert und geloggt")
    func respondDecodes() async throws {
        let fixture = try AIFixture(script: MockScript(chunks: ["Hier: ```json\n{\"name\":\"Mars\",\"moons\":2}\n```"]))
        _ = fixture.addConfiguration()
        let result = try await fixture.ai.respond(AIFixture.request(), decoding: Planet.self)
        #expect(result.value == Planet(name: "Mars", moons: 2))
        #expect(try fixture.logs().first?.parsingError == nil)
    }

    @Test("Kaputte Antwort: Parsing-Fehler steht in den Metadaten und im Log, der Aufrufer bekommt einen klaren Fehler")
    func respondParsingError() async throws {
        for (answer, message) in [
            ("Das ist kein JSON.", "Die Antwort enthält kein JSON."),
            (#"{"name":"Mars"}"#, "Die Antwort hat nicht das erwartete Format: Feld „moons“ fehlt"),
            (#"{"name":"Mars","moons":"#, "Die Antwort wurde abgeschnitten (JSON nicht abgeschlossen)."),
        ] {
            let fixture = try AIFixture(script: MockScript(chunks: [answer]))
            _ = fixture.addConfiguration()
            do {
                _ = try await fixture.ai.respond(AIFixture.request(), decoding: Planet.self)
                Issue.record("Fehler erwartet")
            } catch let error as AIResponseError {
                #expect(error.message.hasPrefix(message))
                #expect(error.localizedDescription == error.message)
            }
            let log = try #require(try fixture.logs().first)
            #expect(try fixture.logs().count == 1)
            #expect(log.parsingError?.hasPrefix(message) == true)
            #expect(log.errorMessage == nil)
            let detail = try JSONDecoder().decode(RequestLogDetail.self, from: log.detailData)
            #expect(detail.metadata.parsingError == log.parsingError)
        }
    }

    @Test("Abbruch durch den Nutzer wird als „Abgebrochen.“ geloggt")
    func cancelIsLogged() async throws {
        let fixture = try AIFixture(script: MockScript(
            chunks: Array(repeating: "x", count: 50), chunkDelay: 0.05))
        _ = fixture.addConfiguration()
        for try await _ in fixture.ai.stream(AIFixture.request(.chat)) { break }  // consumer stops after the first event
        var logs: [RequestLog] = []
        for _ in 0..<100 where logs.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
            logs = try fixture.logs()
        }
        #expect(logs.count == 1)
        #expect(logs.first?.errorMessage == "Abgebrochen.")
    }

    @Test("Modelle abrufen und Verbindung testen nutzen den eingegebenen Key, ohne den gespeicherten zu überschreiben")
    func keyOverride() async throws {
        let recorder = Recorder()
        let keyStore = InMemoryKeyStore()
        let provider = MockProvider()
        let (ai, _) = try service(keyStore: keyStore, backend: AIBackend(
            makeProvider: { _ in recorder.add("provider ohne Override"); return provider },
            makeCatalog: { _ in recorder.add("Katalog ohne Override"); return StaticModelCatalog(models: []) },
            makeProviderWithKey: { _, key in recorder.add("provider \(key)"); return provider },
            makeCatalogWithKey: { _, key in recorder.add("Katalog \(key)"); return StaticModelCatalog(models: []) }))
        let configuration = ProviderConfiguration(name: "Claude", kind: .claude, model: "m")
        ai.add(configuration)
        try ai.saveKey("gespeicherter-key", for: configuration.id)

        _ = try await ai.fetchModels(for: configuration, keyOverride: "temp-key")
        _ = await ai.testConnection(configuration: configuration, keyOverride: "temp-key")
        #expect(recorder.all == ["Katalog temp-key", "provider temp-key"])
        #expect(try keyStore.readKey(for: configuration.id) == "gespeicherter-key")

        _ = try await ai.fetchModels(for: configuration)
        #expect(recorder.all.last == "Katalog ohne Override")
        #expect(try keyStore.readKey(for: configuration.id) == "gespeicherter-key")
    }

    @Test("Verwaiste Keychain-Einträge werden gelöscht, Keys vorhandener Konfigurationen bleiben")
    func orphanCleanup() throws {
        let defaults = UserDefaults(suiteName: "StudyHelperTests-AI-\(UUID().uuidString)") ?? .standard
        let keyStore = InMemoryKeyStore()
        let (first, _) = try service(defaults: defaults, keyStore: keyStore, backend: .mock())
        let kept = ProviderConfiguration(name: "A", kind: .claude, model: "m")
        first.add(kept)
        try first.saveKey("a", for: kept.id)
        let orphan = UUID()
        try keyStore.saveKey("verwaist", for: orphan)

        let (second, _) = try service(defaults: defaults, keyStore: keyStore, backend: .mock())
        #expect(try keyStore.readKey(for: orphan) == nil)
        #expect(try keyStore.readKey(for: kept.id) == "a")
        #expect(second.configurations.count == 1)
        #expect(!second.hasUnreadableSettings)
    }

    @Test("Bei unlesbaren Einstellungen wird nichts aufgeräumt; Hinweis, bis die Sicherung verworfen wird")
    func noCleanupWhenUnreadable() throws {
        let defaults = UserDefaults(suiteName: "StudyHelperTests-AI-\(UUID().uuidString)") ?? .standard
        let keyStore = InMemoryKeyStore()
        let known = ProviderConfiguration(name: "Alt", kind: .claude, model: "m")
        let future = ProviderConfiguration(name: "Neu", kind: .openAI, model: "x")
        try keyStore.saveKey("alt", for: known.id)
        try keyStore.saveKey("neu", for: future.id)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AISettings(configurations: [known, future]))) as? [String: Any])
        var configurations = try #require(object["configurations"] as? [[String: Any]])
        configurations[1]["kind"] = "zukunft"
        object["configurations"] = configurations
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AISettingsStore.defaultsKey)

        let (ai, _) = try service(defaults: defaults, keyStore: keyStore, backend: .mock())
        #expect(ai.configurations.map(\.name) == ["Alt"])
        #expect(ai.hasUnreadableSettings)
        #expect(try keyStore.readKey(for: future.id) == "neu", "Key des übersprungenen Eintrags bleibt erhalten")
        ai.setDeveloperMode(true)  // writes; the backup stays, so the hint and the protection stay
        #expect(ai.hasUnreadableSettings)
        #expect(ai.cleanUpOrphanedKeys() == 0)
        #expect(try keyStore.readKey(for: future.id) == "neu")

        ai.discardUnreadableSettingsBackup()
        #expect(!ai.hasUnreadableSettings)
        #expect(try keyStore.readKey(for: future.id) == nil)
        #expect(try keyStore.readKey(for: known.id) == "alt")
    }
}

@MainActor
@Suite("Summen im Anfrage-Log")
struct RequestLogTotalsTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int, month: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    @Test("Summen pro Tag und Monat, gruppiert nach Anbieter, Modell und Aufgabe")
    func grouping() {
        let usages = [
            LogUsage(date: date(1), providerName: "A", model: "m1", task: "query", inputTokens: 10, outputTokens: 5, costEUR: 0.5, costUSD: 0.6),
            LogUsage(date: date(1), providerName: "B", model: "m2", task: "chat", inputTokens: 20, outputTokens: 5, costEUR: 0.25, costUSD: 0.3),
            LogUsage(date: date(1), providerName: "A", model: "m1", task: "query", costKnown: false),
            LogUsage(date: date(2), providerName: "A", model: "m1", task: "query", inputTokens: 1, outputTokens: 1, costEUR: 1, costUSD: 1),
            LogUsage(date: date(3, month: 4), providerName: "A", model: "m1", task: "chat", costEUR: 2, costUSD: 2),
        ]
        let days = RequestLogTotals.totals(usages, by: .day, calendar: calendar)
        #expect(days.count == 3)
        #expect(days.first?.start == calendar.date(from: DateComponents(year: 2026, month: 4, day: 3)))
        let first = days.first { $0.start == calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)) }
        #expect(first?.total.requests == 3)
        #expect(first?.total.inputTokens == 30)
        #expect(first?.total.costEUR == 0.75)
        #expect(first?.total.unknownCostRequests == 1)
        #expect(first?.byProvider["A"]?.requests == 2)
        #expect(first?.byModel["m2"]?.costUSD == 0.3)
        #expect(first?.byTask["Abfragen"]?.requests == 2)
        let months = RequestLogTotals.totals(usages, by: .month, calendar: calendar)
        #expect(months.count == 2)
        #expect(months.last?.total.costEUR == 1.75)
    }
}
