import Foundation

/// A fixed model list (mock, Apple on-device model).
public struct StaticModelCatalog: ModelCatalog {
    public var models: [ModelInfo]
    public init(models: [ModelInfo]) { self.models = models }
    public func availableModels() async throws -> [ModelInfo] { models }
}

/// Builds the provider and catalog of a configuration.
public struct ProviderFactory: Sendable {
    private let keyStore: KeyStore
    private let transport: HTTPTransport
    private let retry: RetryPolicy
    private let mockScript: MockScript

    public init(
        keyStore: KeyStore, transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy(),
        mockScript: MockScript = MockScript()
    ) {
        self.keyStore = keyStore
        self.transport = transport
        self.retry = retry
        self.mockScript = mockScript
    }

    /// Capabilities of the configured model: the cached ones from the last model list (OpenAI: the maintained table
    /// if nothing is cached), with the user's image setting applied.
    public static func capabilities(of configuration: ProviderConfiguration) -> ProviderCapabilities {
        var capabilities = configuration.cachedCapabilities
            ?? (configuration.kind == .openAI ? OpenAIModelTable.capabilities(for: configuration.model) : ProviderCapabilities())
        if let override = configuration.imageSupportOverride { capabilities.supportsImages = override }
        return capabilities
    }

    public func makeProvider(for configuration: ProviderConfiguration) throws -> any ModelProvider {
        switch configuration.kind {
        case .mock:
            return MockProvider(
                script: mockScript, name: configuration.name, model: configuration.model,
                capabilities: Self.capabilities(of: configuration).isUnknown
                    ? ProviderCapabilities(
                        supportsImages: true, supportsTools: true, supportsStreaming: true,
                        supportsStructuredOutput: true, reasoningLevels: [.off, .low, .medium, .high])
                    : Self.capabilities(of: configuration))
        case .claude:
            return ClaudeProvider(configuration: configuration, keyStore: keyStore, transport: transport, retry: retry)
        case .openAI:
            return OpenAIProvider(configuration: configuration, keyStore: keyStore, transport: transport, retry: retry)
        case .openAICompatible:
            _ = try ProviderEndpoint.url(base: configuration.baseURL ?? "", path: "/v1/models")
            return OpenAICompatibleProvider(configuration: configuration, keyStore: keyStore, transport: transport, retry: retry)
        case .appleFoundation:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) { return AppleFoundationProvider(configuration: configuration) }
            #endif
            throw ProviderError.unavailable(AppleModelAvailability.unsupportedOS.germanDescription)
        }
    }

    public func makeCatalog(for configuration: ProviderConfiguration) throws -> any ModelCatalog {
        switch configuration.kind {
        case .mock:
            return StaticModelCatalog(models: [ModelInfo(id: configuration.model, capabilities: Self.capabilities(of: configuration))])
        case .claude:
            return ClaudeProvider(configuration: configuration, keyStore: keyStore, transport: transport, retry: retry)
        case .openAI:
            return OpenAIProvider(configuration: configuration, keyStore: keyStore, transport: transport, retry: retry)
        case .openAICompatible:
            _ = try ProviderEndpoint.url(base: configuration.baseURL ?? "", path: "/v1/models")
            return OpenAICompatibleProvider(configuration: configuration, keyStore: keyStore, transport: transport, retry: retry)
        case .appleFoundation:
            return StaticModelCatalog(models: [
                ModelInfo(
                    id: "apple-foundation", displayName: "Apple-Modell (auf dem Gerät)",
                    capabilities: ProviderCapabilities(supportsStreaming: true)),
            ])
        }
    }
}

extension ProviderCapabilities {
    /// No information at all (nothing cached, no override).
    var isUnknown: Bool { self == ProviderCapabilities() }
}
