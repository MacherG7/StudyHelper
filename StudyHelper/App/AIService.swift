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
    /// Same as above, but with an API key that is not saved yet (settings: test connection, fetch models). nil = the
    /// backend ignores the key (mocks).
    var makeProviderWithKey: (@Sendable (ProviderConfiguration, String) throws -> any ModelProvider)? = nil
    var makeCatalogWithKey: (@Sendable (ProviderConfiguration, String) throws -> any ModelCatalog)? = nil

    static func live(keyStore: KeyStore, transport: HTTPTransport = URLSessionTransport()) -> AIBackend {
        let factory = ProviderFactory(keyStore: keyStore, transport: transport)
        return AIBackend(
            makeProvider: { try factory.makeProvider(for: $0) },
            makeCatalog: { try factory.makeCatalog(for: $0) },
            makeProviderWithKey: { try factory.withKeyOverride($1, for: $0.id).makeProvider(for: $0) },
            makeCatalogWithKey: { try factory.withKeyOverride($1, for: $0.id).makeCatalog(for: $0) })
    }

    func provider(for configuration: ProviderConfiguration, keyOverride: String?) throws -> any ModelProvider {
        if let keyOverride, let makeProviderWithKey { return try makeProviderWithKey(configuration, keyOverride) }
        return try makeProvider(configuration)
    }

    func catalog(for configuration: ProviderConfiguration, keyOverride: String?) throws -> any ModelCatalog {
        if let keyOverride, let makeCatalogWithKey { return try makeCatalogWithKey(configuration, keyOverride) }
        return try makeCatalog(configuration)
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

/// A decoded structured answer with the raw response (metadata incl. `parsingError` = nil).
struct DecodedResponse<T> {
    var value: T
    var response: ModelResponse
}

/// The answer could not be turned into the expected type; the request log entry carries the same message.
struct AIResponseError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
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
    /// Settings data had unreadable entries (or a backup of such data exists): show a hint, keep the Keychain as is.
    private(set) var hasUnreadableSettings: Bool

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
        self.hasUnreadableSettings = settingsStore.hasUnreadableEntries
        cleanUpOrphanedKeys()
    }

    // MARK: Configurations

    var configurations: [ProviderConfiguration] { settings.configurations }
    var defaultConfigurationID: UUID? { settings.defaultConfiguration?.id }

    private func change(_ change: (inout AISettings) -> Void) {
        settings = settingsStore.update(change)
        hasUnreadableSettings = settingsStore.hasUnreadableEntries
    }

    /// The user acknowledged that unreadable settings entries are gone: drops the backup, and lets the orphaned-key
    /// cleanup run again.
    func discardUnreadableSettingsBackup() {
        settingsStore.discardBackup()
        hasUnreadableSettings = settingsStore.hasUnreadableEntries
        cleanUpOrphanedKeys()
    }

    /// Deletes Keychain keys whose configuration no longer exists. Does nothing while settings entries are
    /// unreadable (their configurations may still exist in the backup). Returns the number of deleted keys.
    @discardableResult
    func cleanUpOrphanedKeys() -> Int {
        guard !settingsStore.hasUnreadableEntries else { return 0 }
        guard let stored = try? keyStore.storedConfigurationIDs() else { return 0 }
        let known = Set(settings.configurations.map(\.id))
        var deleted = 0
        for id in stored where !known.contains(id) {
            if (try? keyStore.deleteKey(for: id)) != nil { deleted += 1 }
        }
        return deleted
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
    /// `keyOverride`: a key typed in the form that is not saved yet; it is used for this call only.
    func fetchModels(for configuration: ProviderConfiguration, keyOverride: String? = nil) async throws -> [ModelInfo] {
        let models = try await backend.catalog(for: configuration, keyOverride: keyOverride).availableModels()
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

    func run(
        _ request: ModelRequest, configuration: ProviderConfiguration? = nil, keyOverride: String? = nil
    ) async throws -> ModelResponse {
        try await execute(request, configuration: configuration, keyOverride: keyOverride, validate: nil)
    }

    /// Runs the request and decodes the answer text as `T` (code fences and prose around the JSON are tolerated).
    /// If the answer does not fit, the log entry gets a German `parsingError` and `AIResponseError` is thrown.
    func respond<T: Decodable>(
        _ request: ModelRequest, decoding type: T.Type, configuration: ProviderConfiguration? = nil
    ) async throws -> DecodedResponse<T> {
        var decoded: T?
        let response = try await execute(request, configuration: configuration, keyOverride: nil) { response in
            switch StructuredOutput.decode(T.self, from: response.text) {
            case .success(let value):
                decoded = value
                return nil
            case .failure(let error):
                return error.message
            }
        }
        guard let value = decoded else {
            throw AIResponseError(message: response.metadata.parsingError ?? "Die Antwort konnte nicht gelesen werden.")
        }
        return DecodedResponse(value: value, response: response)
    }

    private func execute(
        _ request: ModelRequest, configuration: ProviderConfiguration?, keyOverride: String?,
        validate: ((ModelResponse) -> String?)?
    ) async throws -> ModelResponse {
        let (config, provider, prepared) = try prepare(request, configuration: configuration, keyOverride: keyOverride)
        let start = now()
        do {
            var response = try await provider.respond(to: prepared)
            if let message = validate?(response) { response.metadata.parsingError = message }
            log(request: prepared, configuration: config, response: response, error: nil, start: start)
            return response
        } catch {
            let failure = Self.normalized(error)
            log(request: prepared, configuration: config, response: nil, error: failure, start: start)
            throw failure.providerError ?? failure
        }
    }

    func stream(
        _ request: ModelRequest, configuration: ProviderConfiguration? = nil
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        let config: ProviderConfiguration
        let provider: any ModelProvider
        let prepared: ModelRequest
        do {
            (config, provider, prepared) = try prepare(request, configuration: configuration, keyOverride: nil)
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
                        // The stream ended without a result: the user cancelled, or the provider stopped early.
                        let error: Error = Task.isCancelled
                            ? ProviderError.cancelled : ProviderError.invalidResponse("Die Antwort endete ohne Abschluss.")
                        log(request: prepared, configuration: config, response: nil, error: error, start: start)
                    }
                    continuation.finish()
                } catch {
                    let failure = Self.normalized(error)
                    if !logged { log(request: prepared, configuration: config, response: nil, error: failure, start: start) }
                    continuation.finish(throwing: failure.providerError ?? failure)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An error of a cancelled task is a cancellation, whatever the transport reported (partial metadata is kept).
    private static func normalized(_ error: Error) -> Error {
        guard Task.isCancelled, error.providerError != .cancelled else { return error }
        return ProviderFailure(underlying: .cancelled, metadata: error.failureMetadata)
    }

    /// Sends a tiny request ("Antworte nur mit OK.") and reports success or the German error.
    /// `keyOverride`: a key typed in the form that is not saved yet; it is used for this call only.
    func testConnection(configuration: ProviderConfiguration, keyOverride: String? = nil) async -> ConnectionTestResult {
        let capabilities = ProviderFactory.capabilities(of: configuration)
        let request = ModelRequest(
            task: .connectionTest, system: PromptParts(fixed: "Du bist ein Verbindungstest."),
            messages: [.user("Antworte nur mit OK.")],
            reasoning: capabilities.reasoningLevels.contains(.off) ? ReasoningLevel.off : nil, maxOutputTokens: 64)
        do {
            _ = try await run(request, configuration: configuration, keyOverride: keyOverride)
            return ConnectionTestResult(isSuccess: true, message: "Verbindung OK")
        } catch {
            return ConnectionTestResult(isSuccess: false, message: Self.message(for: error))
        }
    }

    // MARK: Internals

    private func prepare(
        _ request: ModelRequest, configuration: ProviderConfiguration?, keyOverride: String?
    ) throws -> (ProviderConfiguration, any ModelProvider, ModelRequest) {
        guard let config = configuration ?? self.configuration(for: request.task) else {
            throw ProviderError.unavailable("Es ist noch kein KI-Anbieter eingerichtet.")
        }
        let provider: any ModelProvider
        do {
            provider = try backend.provider(for: config, keyOverride: keyOverride)
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
        // A failed request keeps what the provider knew (usage so far, raw request, level actually sent). Without
        // that (failure before sending) nothing was sent, so no reasoning level is logged.
        let metadata = response?.metadata ?? error?.failureMetadata ?? ResponseMetadata(
            task: request.task, providerKind: configuration.kind, providerName: configuration.name,
            model: configuration.model, reasoning: nil, date: start,
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
            parsingError: metadata.parsingError, errorMessage: error.map { URLRedaction.redact(in: AIService.message(for: $0)) },
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
                case .reasoning: return "[Denkschritte des Modells]"
                }
            }
            return (message.role == .user ? "Nutzer: " : "Assistent: ") + parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
