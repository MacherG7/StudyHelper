import Foundation
import Observation
import StudyAI
import StudyCore
import StudyData

/// How the app builds providers and model catalogs. Production uses `ProviderFactory`; UI tests and unit tests
/// swap in the mock provider, so nothing in the app (or its tests) needs the network or the real Keychain.
struct AIBackend: Sendable {
    var makeProvider: @Sendable (ProviderConfiguration) throws -> any ModelProvider
    var makeCatalog: @Sendable (ProviderConfiguration) throws -> any ModelCatalog

    static func live(keyStore: KeyStore, transport: HTTPTransport = URLSessionTransport()) -> AIBackend {
        let factory = ProviderFactory(keyStore: keyStore, transport: transport)
        return AIBackend(
            makeProvider: { try factory.makeProvider(for: $0) },
            makeCatalog: { try factory.makeCatalog(for: $0) })
    }

    /// The two models of the UI-test mock catalog (`-uiTestMockAI`).
    nonisolated static let mockModels: [ModelInfo] = [
        ModelInfo(
            id: "mock-schnell", displayName: "Mock schnell",
            capabilities: ProviderCapabilities(
                supportsImages: false, supportsTools: true, supportsStreaming: true, supportsStructuredOutput: true)),
        ModelInfo(
            id: "mock-denkend", displayName: "Mock denkend",
            capabilities: ProviderCapabilities(
                supportsImages: true, supportsTools: true, supportsStreaming: true, supportsStructuredOutput: true,
                reasoningLevels: [.off, .low, .medium, .high], defaultReasoning: .medium)),
    ]

    /// A mock provider for every configuration kind, with the mock catalog.
    static func mock(script: MockScript = MockScript(chunks: ["OK"])) -> AIBackend {
        AIBackend(
            makeProvider: { configuration in
                let known = mockModels.first { $0.id == configuration.model }?.capabilities
                var capabilities = configuration.cachedCapabilities ?? known ?? ProviderCapabilities(
                    supportsImages: true, supportsTools: true, supportsStreaming: true, supportsStructuredOutput: true)
                if let override = configuration.imageSupportOverride { capabilities.supportsImages = override }
                return MockProvider(
                    script: script, name: configuration.name, model: configuration.model, capabilities: capabilities)
            },
            makeCatalog: { _ in StaticModelCatalog(models: mockModels) })
    }
}

/// Result of "Verbindung testen".
struct ConnectionTestResult: Equatable {
    var isSuccess: Bool
    var message: String
}

/// Everything the app does with AI providers: configurations, keys, model lists, and running requests. Every request
/// is written to the request log (also failed ones); API keys never leave the `KeyStore` (SPEC §3, §10).
@MainActor
@Observable
final class AIService {
    /// Mirror of the persisted settings; changes go through the methods below.
    private(set) var settings: AISettings

    @ObservationIgnored private let settingsStore: AISettingsStore
    @ObservationIgnored private let keyStore: KeyStore
    @ObservationIgnored private let backend: AIBackend
    @ObservationIgnored private let repository: StudyRepository
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        repository: StudyRepository, settingsStore: AISettingsStore, keyStore: KeyStore, backend: AIBackend,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.keyStore = keyStore
        self.backend = backend
        self.now = now
        self.settings = settingsStore.load()
    }

    // MARK: Configurations

    var configurations: [ProviderConfiguration] { settings.configurations }
    var defaultConfigurationID: UUID? { settings.defaultConfiguration?.id }

    private func change(_ change: (inout AISettings) -> Void) {
        settings = settingsStore.update(change)
    }

    /// Adds a configuration; the first one becomes the default. `makeDefault` makes it the default anyway.
    func add(_ configuration: ProviderConfiguration, makeDefault: Bool = false) {
        change {
            $0.configurations.append(configuration)
            if makeDefault || $0.defaultProviderID == nil || $0.configuration(id: $0.defaultProviderID) == nil {
                $0.defaultProviderID = configuration.id
            }
        }
    }

    func update(_ configuration: ProviderConfiguration) {
        change {
            guard let index = $0.configurations.firstIndex(where: { $0.id == configuration.id }) else { return }
            $0.configurations[index] = configuration
        }
    }

    func setDefault(_ id: UUID) {
        guard settings.configuration(id: id) != nil else { return }
        change { $0.defaultProviderID = id }
    }

    /// Deletes the configuration and its key.
    func delete(_ id: UUID) {
        try? keyStore.deleteKey(for: id)
        change {
            $0.configurations.removeAll { $0.id == id }
            if $0.defaultProviderID == id { $0.defaultProviderID = $0.configurations.first?.id }
            if $0.digitizationProviderID == id { $0.digitizationProviderID = nil }
        }
    }

    // MARK: Keys (the UI only ever learns "gespeichert")

    func saveKey(_ key: String, for id: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try keyStore.saveKey(trimmed, for: id)
    }

    func hasKey(for id: UUID) -> Bool {
        ((try? keyStore.readKey(for: id)) ?? nil) != nil
    }

    func deleteKey(for id: UUID) {
        try? keyStore.deleteKey(for: id)
    }

    // MARK: Other settings

    func setDeveloperMode(_ enabled: Bool) { change { $0.developerModeEnabled = enabled } }
    func setDigitizationProvider(_ id: UUID?) { change { $0.digitizationProviderID = id } }
    func setUSDToEURRate(_ rate: Double) {
        guard rate > 0, rate.isFinite else { return }
        change { $0.usdToEurRate = rate }
    }

    func setReasoningOverride(_ level: ReasoningLevel?, for task: AITask) {
        change { $0.reasoningOverrides[task] = level }
    }

    func setPriceOverride(_ price: ModelPrice?, for model: String) {
        change { $0.priceOverrides[model] = price }
    }

    func resetPriceOverrides() { change { $0.priceOverrides = [:] } }

    // MARK: Models

    /// Model list of the provider (needs the saved key for Claude/OpenAI). If the configuration is stored and its
    /// model is in the list, the model's capabilities are cached in the configuration (settings work offline).
    func fetchModels(for configuration: ProviderConfiguration) async throws -> [ModelInfo] {
        let models = try await backend.makeCatalog(configuration).availableModels()
        if var stored = settings.configuration(id: configuration.id),
           let info = models.first(where: { $0.id == stored.model }) {
            stored.cachedCapabilities = info.capabilities
            update(stored)
        }
        return models
    }

    // MARK: Running requests

    /// The configuration a task runs on: digitization has its own choice, everything else uses the default.
    func configuration(for task: AITask) -> ProviderConfiguration? {
        task == .digitization ? settings.digitizationConfiguration : settings.defaultConfiguration
    }

    /// Level that is sent: an explicit level of the request, else the per-task override (only if the model offers
    /// it), else the configuration's level.
    func effectiveReasoning(
        for request: ModelRequest, configuration: ProviderConfiguration, capabilities: ProviderCapabilities
    ) -> ReasoningLevel? {
        if let explicit = request.reasoning { return explicit }
        if let override = settings.reasoningOverrides[request.task], capabilities.reasoningLevels.contains(override) {
            return override
        }
        return configuration.reasoning
    }

    func run(_ request: ModelRequest, configuration: ProviderConfiguration? = nil) async throws -> ModelResponse {
        let (config, provider, prepared) = try prepare(request, configuration: configuration)
        let start = now()
        do {
            let response = try await provider.respond(to: prepared)
            log(request: prepared, configuration: config, response: response, error: nil, start: start)
            return response
        } catch {
            log(request: prepared, configuration: config, response: nil, error: error, start: start)
            throw error
        }
    }

    func stream(
        _ request: ModelRequest, configuration: ProviderConfiguration? = nil
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let config: ProviderConfiguration
        let provider: any ModelProvider
        let prepared: ModelRequest
        do {
            (config, provider, prepared) = try prepare(request, configuration: configuration)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [self] in
                let start = now()
                var logged = false
                do {
                    for try await event in provider.stream(prepared) {
                        if case .finished(let response) = event {
                            log(request: prepared, configuration: config, response: response, error: nil, start: start)
                            logged = true
                        }
                        continuation.yield(event)
                    }
                    if !logged {
                        log(
                            request: prepared, configuration: config, response: nil,
                            error: ProviderError.invalidResponse("Die Antwort endete ohne Abschluss."), start: start)
                    }
                    continuation.finish()
                } catch {
                    if !logged { log(request: prepared, configuration: config, response: nil, error: error, start: start) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends a tiny request ("Antworte nur mit OK.") and reports success or the German error.
    func testConnection(configuration: ProviderConfiguration) async -> ConnectionTestResult {
        let capabilities = ProviderFactory.capabilities(of: configuration)
        let request = ModelRequest(
            task: .connectionTest, system: PromptParts(fixed: "Du bist ein Verbindungstest."),
            messages: [.user("Antworte nur mit OK.")],
            reasoning: capabilities.reasoningLevels.contains(.off) ? ReasoningLevel.off : nil, maxOutputTokens: 64)
        do {
            _ = try await run(request, configuration: configuration)
            return ConnectionTestResult(isSuccess: true, message: "Verbindung OK")
        } catch {
            return ConnectionTestResult(isSuccess: false, message: Self.message(for: error))
        }
    }

    // MARK: Internals

    private func prepare(
        _ request: ModelRequest, configuration: ProviderConfiguration?
    ) throws -> (ProviderConfiguration, any ModelProvider, ModelRequest) {
        guard let config = configuration ?? self.configuration(for: request.task) else {
            throw ProviderError.unavailable("Es ist noch kein KI-Anbieter eingerichtet.")
        }
        let provider: any ModelProvider
        do {
            provider = try backend.makeProvider(config)
        } catch {
            log(request: request, configuration: config, response: nil, error: error, start: now())
            throw error
        }
        var prepared = request
        prepared.reasoning = effectiveReasoning(for: request, configuration: config, capabilities: provider.capabilities)
        return (config, provider, prepared)
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func log(
        request: ModelRequest, configuration: ProviderConfiguration, response: ModelResponse?, error: Error?,
        start: Date
    ) {
        let entry = RequestLogBuilder.entry(
            request: request, configuration: configuration, response: response, error: error, start: start,
            end: now(), settings: settings)
        _ = try? repository.addRequestLog(entry)
    }
}

/// Detail JSON of a log entry: the provider's `ResponseMetadata` plus the texts that were sent. Never contains keys
/// (the metadata holds the request body without headers).
struct RequestLogDetail: Codable, Equatable {
    var metadata: ResponseMetadata
    var systemPrompt: String
    var prompt: String
}

/// Turns a finished (or failed) request into a `RequestLogEntry` with the estimated cost.
enum RequestLogBuilder {
    static func entry(
        request: ModelRequest, configuration: ProviderConfiguration, response: ModelResponse?, error: Error?,
        start: Date, end: Date, settings: AISettings
    ) -> RequestLogEntry {
        let metadata = response?.metadata ?? ResponseMetadata(
            task: request.task, providerKind: configuration.kind, providerName: configuration.name,
            model: configuration.model, reasoning: request.reasoning, date: start,
            duration: max(0, end.timeIntervalSince(start)), sentContent: request.sentContent,
            learningUnitIDsInContext: request.learningUnitIDsInContext)
        let usage = metadata.usage
        let cost = CostEstimate.compute(
            model: configuration.model, table: settings.priceTable, isFree: configuration.kind.isFree,
            usdToEurRate: settings.usdToEurRate, input: usage.inputTokens, output: usage.outputTokens,
            cacheRead: usage.cacheReadTokens, cacheWrite: usage.cacheWriteTokens, reasoning: usage.reasoningTokens,
            reasoningIncludedInOutput: true, cacheIncludedInInput: configuration.kind == .openAI)
        let known: Bool
        if case .unknown = cost { known = false } else { known = true }
        let detail = RequestLogDetail(
            metadata: metadata, systemPrompt: request.system.combined, prompt: promptText(request))
        let detailJSON = (try? JSONEncoder().encode(detail)) ?? Data("{}".utf8)
        return RequestLogEntry(
            date: metadata.date, task: request.task.rawValue, providerKind: configuration.kind.rawValue,
            providerName: configuration.name, model: configuration.model, reasoning: metadata.reasoning?.rawValue,
            inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens, reasoningTokens: usage.reasoningTokens,
            duration: metadata.duration, timeToFirstToken: metadata.timeToFirstToken, costUSD: cost.usd,
            costEUR: cost.eur, costKnown: known, sentText: metadata.sentContent.contains(.text),
            sentImage: metadata.sentContent.contains(.image), toolCallCount: metadata.toolCalls.count,
            parsingError: metadata.parsingError, errorMessage: error.map(AIService.message(for:)),
            detailJSON: detailJSON)
    }

    /// The conversation as readable text (images as a marker).
    static func promptText(_ request: ModelRequest) -> String {
        request.messages.map { message in
            let parts = message.content.map { part -> String in
                switch part {
                case .text(let text): return text
                case .image(let image): return "[Bild, \(image.data.count) Bytes]"
                case .toolCall(let call): return "[Werkzeugaufruf \(call.name)] \(call.arguments)"
                case .toolResult(let result): return "[Werkzeugergebnis] \(result.content)"
                }
            }
            return (message.role == .user ? "Nutzer: " : "Assistent: ") + parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
