import Foundation
import StudyCore

/// One configured provider. Holds no secrets: the API key lives in the Keychain under `keychainAccount`.
public struct ProviderConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Name shown to the user ("Claude privat").
    public var name: String
    public var kind: ProviderKind
    /// Server address for OpenAI-compatible providers; nil = the default host of Claude/OpenAI.
    public var baseURL: String?
    public var model: String
    public var reasoning: ReasoningLevel?
    /// User setting "Modell kann Bilder verarbeiten"; wins over the model list.
    public var imageSupportOverride: Bool?
    /// Capabilities from the last model list, so the settings work offline.
    public var cachedCapabilities: ProviderCapabilities?

    public init(
        id: UUID = UUID(), name: String, kind: ProviderKind, baseURL: String? = nil, model: String,
        reasoning: ReasoningLevel? = nil, imageSupportOverride: Bool? = nil,
        cachedCapabilities: ProviderCapabilities? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.reasoning = reasoning
        self.imageSupportOverride = imageSupportOverride
        self.cachedCapabilities = cachedCapabilities
    }

    /// Keychain account of this configuration's key.
    public var keychainAccount: String { id.uuidString }

    /// Capabilities with the user's image override applied (unknown model: conservative defaults).
    public var effectiveCapabilities: ProviderCapabilities {
        var capabilities = cachedCapabilities ?? ProviderCapabilities()
        if let imageSupportOverride { capabilities.supportsImages = imageSupportOverride }
        return capabilities
    }
}
